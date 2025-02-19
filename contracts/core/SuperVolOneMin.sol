// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IVault } from "../interfaces/IVault.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { SuperVolOneMinStorage } from "../storage/SuperVolOneMinStorage.sol";
import { Round, Coupon, WithdrawalRequest, ProductRound, SettlementResult, WinPosition, OneMinOrder, Position } from "../types/Types.sol";
import { ISuperVolErrors } from "../errors/SuperVolErrors.sol";

contract SuperVolOneMin is
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  ISuperVolErrors
{
  using SafeERC20 for IERC20;

  function _priceIds() internal pure returns (bytes32[] memory) {
    // https://pyth.network/developers/price-feed-ids#pyth-evm-stable
    // to add products, upgrade the contract
    bytes32[] memory priceIds = new bytes32[](4);
    // priceIds[productId] = pyth price id
    priceIds[0] = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43; // btc
    priceIds[1] = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace; // eth
    priceIds[2] = 0x89b814de1eb2afd3d3b498d296fca3a873e644bafb587e84d181a01edd682853; // astr
    priceIds[3] = 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d; // sol
    return priceIds;
  }

  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant BASE = 10000; // 100%
  uint256 private constant MAX_COMMISSION_FEE = 2000; // 20%
  uint256 private constant ROUND_INTERVAL = 30; // 30초마다 새로운 라운드
  uint256 private constant ROUND_DURATION = 60; // 라운드 지속시간 1분
  uint256 private constant BUFFER_SECONDS = 5; // 버퍼 시간
  uint256 private constant START_TIMESTAMP = 1736294400; // for epoch

  event StartRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);
  event EndRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);
  event OrderSettled(
    address indexed user,
    uint256 indexed idx,
    uint256 epoch,
    uint256 closingPrice,
    uint256 closingTime,
    uint256 settleAmount
  );
  event RoundSettled(uint256 indexed epoch, uint256 orderCount, uint256 collectedFee);
  event DepositCoupon(
    address indexed to,
    address from,
    uint256 amount,
    uint256 expirationEpoch,
    uint256 result
  );

  modifier onlyAdmin() {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    if (msg.sender != $.adminAddress) revert InvalidAddress();
    _;
  }
  modifier onlyOperator() {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    bool isOperator = false;
    for (uint i = 0; i < $.operatorAddresses.length; i++) {
      if (msg.sender == $.operatorAddresses[i]) {
        isOperator = true;
        break;
      }
    }
    if (!isOperator) revert InvalidAddress();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(
    address _usdcAddress,
    address _oracleAddress,
    address _adminAddress,
    address _operatorAddress,
    address _clearingHouseAddress,
    address _vaultAddress
  ) public initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);
    __Pausable_init();
    __ReentrancyGuard_init();

    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();

    $.token = IERC20(_usdcAddress);
    $.oracle = IPyth(_oracleAddress);
    $.vault = IVault(_vaultAddress);
    $.clearingHouse = IClearingHouse(_clearingHouseAddress);
    $.adminAddress = _adminAddress;
    $.operatorAddresses.push(_operatorAddress);
    $.commissionfees[0] = 1000; // btc
    $.commissionfees[1] = 1000; // eth
    $.commissionfees[2] = 1000; // astr
    $.commissionfees[3] = 1000; // sol
  }

  function currentEpoch() external view returns (uint256) {
    return _epochAt(block.timestamp);
  }

  function updatePrice(
    bytes[] calldata priceUpdateData,
    uint64 timestamp
  ) external payable whenNotPaused onlyOperator {
    // timestamp should be either XX:00 or XX:30
    if (timestamp % ROUND_INTERVAL != 0) revert InvalidTime();

    PythStructs.PriceFeed[] memory feeds = _getPythPrices(priceUpdateData, timestamp);

    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();

    // Store price history
    for (uint i = 0; i < feeds.length; i++) {
      uint64 pythPrice = uint64(feeds[i].price.price);
      $.priceHistory[timestamp][i] = pythPrice;
    }
  }

  function settleOneMinOrders(uint256[] calldata orderIds) public onlyOperator {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    address vaultAddress = address($.vault);

    for (uint i = 0; i < orderIds.length; i++) {
      OneMinOrder storage order = $.oneMinOrders[orderIds[i]];
      if (order.closingPrice != 0 || order.closingTime != 0 || order.settleAmount != 0) continue;

      (uint256 startTime, uint256 endTime) = _epochTimes(order.epoch);
      if (block.timestamp < startTime || block.timestamp > endTime) continue;

      uint256 closingPrice = $.priceHistory[endTime][order.productId];
      if (closingPrice == 0) continue;

      order.closingPrice = closingPrice;
      order.closingTime = endTime;

      bool isWin = (order.closingPrice > order.entryPrice && order.position == Position.Over) ||
        (order.closingPrice < order.entryPrice && order.position == Position.Under);

      if (isWin) {
        // Winner gets back collateral + profit
        // _processVaultTransaction(order.idx, vaultAddress, order.collateralAmount, false);
        $.clearingHouse.subtractUserBalance(vaultAddress, order.collateralAmount);
        $.clearingHouse.addUserBalance(order.user, order.collateralAmount);
        order.settleAmount = order.collateralAmount + order.amount;
      } else {
        // Loser loses collateral
        $.clearingHouse.subtractUserBalance(order.user, order.amount);
        $.clearingHouse.addUserBalance(vaultAddress, order.amount);
        // _processVaultTransaction(order.idx, vaultAddress, order.amount, true);
        order.settleAmount = 0;
      }

      emit OrderSettled(
        order.user,
        order.idx,
        order.epoch,
        order.closingPrice,
        order.closingTime,
        order.settleAmount
      );
    }
  }

  function submitOneMinOrders(OneMinOrder[] calldata orders) external nonReentrant onlyOperator {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();

    for (uint i = 0; i < orders.length; i++) {
      OneMinOrder calldata order = orders[i];
      if ($.oneMinOrders[order.idx].idx != 0) continue;
      $.oneMinOrders[order.idx] = order;
    }
  }

  function closeOneMinOrder(uint256 idx, uint256 price) public onlyOperator {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    OneMinOrder storage order = $.oneMinOrders[idx];
    order.closingPrice = price;
    order.closingTime = block.timestamp;
    // TODO: settle order
  }

  function pause() external whenNotPaused onlyAdmin {
    _pause();
  }

  function retrieveMisplacedETH() external onlyAdmin {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    payable($.adminAddress).transfer(address(this).balance);
  }

  function retrieveMisplacedTokens(address _token) external onlyAdmin {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    if (address($.token) == _token) revert InvalidTokenAddress();
    IERC20 token = IERC20(_token);
    token.safeTransfer($.adminAddress, token.balanceOf(address(this)));
  }

  function unpause() external whenPaused onlyAdmin {
    _unpause();
  }

  function addOperator(address _operatorAddress) external onlyAdmin {
    if (_operatorAddress == address(0)) revert InvalidAddress();
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    $.operatorAddresses.push(_operatorAddress);
  }

  function removeOperator(address _operatorAddress) external onlyAdmin {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    for (uint i = 0; i < $.operatorAddresses.length; i++) {
      if ($.operatorAddresses[i] == _operatorAddress) {
        $.operatorAddresses[i] = $.operatorAddresses[$.operatorAddresses.length - 1];
        $.operatorAddresses.pop();
        break;
      }
    }
  }

  function setOracle(address _oracle) external whenPaused onlyAdmin {
    if (_oracle == address(0)) revert InvalidAddress();
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    $.oracle = IPyth(_oracle);
  }

  function setCommissionfee(
    uint256 productId,
    uint256 _commissionfee
  ) external whenPaused onlyAdmin {
    if (_commissionfee > MAX_COMMISSION_FEE) revert InvalidCommissionFee();
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    $.commissionfees[productId] = _commissionfee;
  }

  function setAdmin(address _adminAddress) external onlyOwner {
    if (_adminAddress == address(0)) revert InvalidAddress();
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    $.adminAddress = _adminAddress;
  }

  function setToken(address _token) external onlyAdmin {
    if (_token == address(0)) revert InvalidAddress();
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    $.token = IERC20(_token);
  }

  function setVault(address _vault) external onlyAdmin {
    if (_vault == address(0)) revert InvalidAddress();
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    $.vault = IVault(_vault);
  }

  /* public views */
  function commissionfee(uint256 productId) public view returns (uint256) {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    return $.commissionfees[productId];
  }

  function treasuryAmount() public view returns (uint256) {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    return $.clearingHouse.treasuryAmount();
  }

  function addresses() public view returns (address, address[] memory, address, address, address) {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    return (
      $.adminAddress,
      $.operatorAddresses,
      address($.vault),
      address($.clearingHouse),
      address($.token)
    );
  }

  function balances(address user) public view returns (uint256, uint256, uint256) {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    uint256 depositBalance = $.clearingHouse.userBalances(user);
    uint256 couponBalance = $.clearingHouse.couponBalanceOf(user);
    uint256 totalBalance = depositBalance + couponBalance;
    return (depositBalance, couponBalance, totalBalance);
  }

  function balanceOf(address user) public view returns (uint256) {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    return $.clearingHouse.userBalances(user);
  }

  function oneMinOrders(uint256[] calldata idx) public view returns (OneMinOrder[] memory) {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    OneMinOrder[] memory orders = new OneMinOrder[](idx.length);
    for (uint i = 0; i < idx.length; i++) {
      orders[i] = $.oneMinOrders[idx[i]];
    }
    return orders;
  }

  function getPythPrice(uint256 timestamp, uint256 productId) external view returns (uint64) {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    return $.priceHistory[timestamp][productId];
  }

  /* internal functions */
  function _getPythPrices(
    bytes[] calldata updateData,
    uint64 timestamp
  ) internal returns (PythStructs.PriceFeed[] memory) {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    uint fee = $.oracle.getUpdateFee(updateData);
    PythStructs.PriceFeed[] memory pythPrice = $.oracle.parsePriceFeedUpdates{ value: fee }(
      updateData,
      _priceIds(),
      timestamp,
      timestamp + uint64(BUFFER_SECONDS)
    );
    return pythPrice;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  function _epochAt(uint256 timestamp) internal pure returns (uint256) {
    if (timestamp < START_TIMESTAMP) revert EpochHasNotStartedYet();
    uint256 elapsedSeconds = timestamp - START_TIMESTAMP;
    return elapsedSeconds / ROUND_INTERVAL;
  }

  function _epochTimes(uint256 epoch) internal pure returns (uint256 startTime, uint256 endTime) {
    if (epoch < 0) revert InvalidEpoch();
    startTime = START_TIMESTAMP + (epoch * ROUND_INTERVAL);
    endTime = startTime + ROUND_DURATION;
    return (startTime, endTime);
  }

  function _processVaultTransaction(
    uint256 orderIdx,
    address vaultAddress,
    uint256 amount,
    bool isWin
  ) internal {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    $.vault.processVaultTransaction(orderIdx, vaultAddress, amount, isWin);
  }
}
