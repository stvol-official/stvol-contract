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
import { PythLazer } from "../libraries/PythLazer.sol";
import { PythLazerLib } from "../libraries/PythLazerLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { SuperVolOneMinStorage } from "../storage/SuperVolOneMinStorage.sol";
import { Round, Coupon, WithdrawalRequest, ProductRound, SettlementResult, WinPosition, OneMinOrder, Position, ClosingOneMinOrder, PriceInfo, PriceUpdateData, PriceLazerData, PriceFeedMapping } from "../types/Types.sol";
import { ISuperVolErrors } from "../errors/SuperVolErrors.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract SuperVolOneMin is
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  ISuperVolErrors
{
  using SafeERC20 for IERC20;

  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant BASE = 10000; // 100%
  uint256 private constant MAX_COMMISSION_FEE = 5000; // 50%
  uint256 private constant ROUND_INTERVAL = 60;
  uint256 private constant ROUND_DURATION = ROUND_INTERVAL * 2;
  uint256 private constant BUFFER_SECONDS = 5;
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

  event DebugLog(string message);
  event PriceIdAdded(uint256 indexed productId, bytes32 priceId, string symbol);

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
    $.vault = _vaultAddress;
    $.clearingHouse = IClearingHouse(_clearingHouseAddress);
    $.adminAddress = _adminAddress;
    $.operatorAddresses.push(_operatorAddress);
    $.pythLazer = PythLazer(0xACeA761c27A909d4D3895128EBe6370FDE2dF481);
    $.commissionfees[0] = 1000; // btc
    $.commissionfees[1] = 1000; // eth
    $.commissionfees[2] = 1000; // astr
    $.commissionfees[3] = 1000; // sol

    _addPriceId(0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43, 0, "BTC/USD");
    _addPriceId(0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace, 1, "ETH/USD");
    _addPriceId(0x89b814de1eb2afd3d3b498d296fca3a873e644bafb587e84d181a01edd682853, 2, "ASTR/USD");
    _addPriceId(0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d, 3, "SOL/USD");
  }

  function currentEpoch() external view returns (uint256) {
    return _epochAt(block.timestamp);
  }

  function updatePrice(
    PriceLazerData calldata priceLazerData,
    uint64 timestamp
  ) external payable onlyOperator {
    // timestamp should be either XX:00
    if (timestamp % ROUND_INTERVAL != 0) revert InvalidTime();

    // update price and store
    _processPythLazerPriceUpdate(priceLazerData, timestamp);
    emit DebugLog(string.concat("Price updated for timestamp: ", Strings.toString(timestamp)));
  }

  function submitOneMinOrders(OneMinOrder[] calldata orders) external nonReentrant onlyOperator {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    for (uint i = 0; i < orders.length; i++) {
      OneMinOrder calldata order = orders[i];
      if ($.oneMinOrders[order.idx].idx != 0) {
        emit DebugLog(string.concat("Order ", Strings.toString(order.idx), " already exists"));
        continue;
      }

      try
        $.clearingHouse.lockInEscrow(
          address(this),
          order.user,
          order.amount,
          order.epoch,
          order.idx,
          true
        )
      {} catch {
        emit DebugLog(
          string.concat("Order ", Strings.toString(order.idx), " - user lockInEscrow failed")
        );
        continue;
      }

      try
        $.clearingHouse.lockInEscrow(
          address(this),
          $.vault,
          order.collateralAmount,
          order.epoch,
          order.idx,
          false
        )
      {} catch {
        emit DebugLog(
          string.concat("Order ", Strings.toString(order.idx), " - vault lockInEscrow failed")
        );
        $.clearingHouse.releaseFromEscrow(
          address(this),
          order.user,
          order.epoch,
          order.idx,
          order.amount,
          0
        );
        continue;
      }

      $.oneMinOrders[order.idx] = order;
      emit DebugLog(string.concat("Order ", Strings.toString(order.idx), " added"));
    }
  }

  function closeOneMinOrders(ClosingOneMinOrder[] calldata closingOrders) public onlyOperator {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    for (uint i = 0; i < closingOrders.length; i++) {
      ClosingOneMinOrder calldata closingOrder = closingOrders[i];

      OneMinOrder storage order = $.oneMinOrders[closingOrder.idx];
      if (order.idx == 0) {
        emit DebugLog(
          string.concat("Order ", Strings.toString(closingOrder.idx), " does not exist")
        );
        continue;
      }

      if (order.isSettled) {
        emit DebugLog(
          string.concat("Order ", Strings.toString(closingOrder.idx), " already settled")
        );
        continue;
      }

      if (order.user == address(0)) {
        emit DebugLog(string.concat("Order ", Strings.toString(closingOrder.idx), " has no user"));
        continue;
      }

      if (order.amount == 0 || order.collateralAmount == 0) {
        emit DebugLog(
          string.concat("Order ", Strings.toString(closingOrder.idx), " has no amount")
        );
        continue;
      }

      if (closingOrder.closingPrice == 0) {
        emit DebugLog(
          string.concat("Order ", Strings.toString(closingOrder.idx), " has invalid closing price")
        );
        continue;
      }

      if (closingOrder.closingTime > block.timestamp) {
        emit DebugLog(
          string.concat("Order ", Strings.toString(closingOrder.idx), " has future closing time")
        );
        continue;
      }

      int256 delta = int256(order.amount) - int256(closingOrder.settleAmount);
      if (delta > 0) {
        $.clearingHouse.releaseFromEscrow(
          address(this),
          $.vault,
          order.epoch,
          order.idx,
          order.collateralAmount,
          0
        );
        $.clearingHouse.settleEscrowWithFee(
          address(this),
          order.user,
          $.vault,
          order.epoch,
          uint256(delta),
          order.idx,
          0
        );
        $.clearingHouse.releaseFromEscrow(
          address(this),
          order.user,
          order.epoch,
          order.idx,
          closingOrder.settleAmount,
          0
        );
      } else if (delta < 0) {
        uint256 absDelta = uint256(-delta);
        $.clearingHouse.releaseFromEscrow(
          address(this),
          order.user,
          order.epoch,
          order.idx,
          order.amount,
          0
        );
        $.clearingHouse.settleEscrowWithFee(
          address(this),
          $.vault,
          order.user,
          order.epoch,
          absDelta,
          order.idx,
          0
        );
        $.clearingHouse.releaseFromEscrow(
          address(this),
          $.vault,
          order.epoch,
          order.idx,
          order.collateralAmount - absDelta,
          0
        );
      } else {
        $.clearingHouse.releaseFromEscrow(
          address(this),
          order.user,
          order.epoch,
          order.idx,
          order.amount,
          0
        );
        $.clearingHouse.releaseFromEscrow(
          address(this),
          $.vault,
          order.epoch,
          order.idx,
          order.collateralAmount,
          0
        );
      }

      order.closingPrice = closingOrder.closingPrice;
      order.closingTime = closingOrder.closingTime;
      order.settleAmount = closingOrder.settleAmount;
      order.isSettled = true;

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

  function settleOneMinOrders(
    uint256[] calldata orderIds
  ) public onlyOperator returns (uint256[] memory) {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    address vaultAddress = $.vault;
    if (vaultAddress == address(0)) revert InvalidAddress();

    // Create dynamic array to store successful order IDs
    uint256[] memory successfulOrderIds = new uint256[](orderIds.length);
    uint256 successCount = 0;

    for (uint i = 0; i < orderIds.length; i++) {
      // Validate order ID exists
      if (orderIds[i] == 0) {
        emit DebugLog(string.concat("Order ", Strings.toString(orderIds[i]), " does not exist"));
        continue;
      }

      OneMinOrder storage order = $.oneMinOrders[orderIds[i]];
      // Validate order exists and hasn't been settled
      if (order.idx == 0) {
        emit DebugLog(string.concat("Order ", Strings.toString(orderIds[i]), " does not exist"));
        continue;
      }
      if (order.isSettled) {
        emit DebugLog(string.concat("Order ", Strings.toString(orderIds[i]), " already settled"));
        continue;
      }

      // Validate user and amounts
      if (order.user == address(0)) {
        emit DebugLog(string.concat("Order ", Strings.toString(orderIds[i]), " has no user"));
        continue;
      }
      if (order.amount == 0) {
        emit DebugLog(string.concat("Order ", Strings.toString(orderIds[i]), " has no amount"));
        continue;
      }

      (, uint256 endTime) = _epochTimes(order.epoch);
      if (block.timestamp < endTime) {
        emit DebugLog(
          string.concat(
            "Order ",
            Strings.toString(order.idx),
            " - Epoch ",
            Strings.toString(order.epoch),
            " is not finished"
          )
        );
        continue;
      }

      uint256 closingPrice = $.priceHistory[endTime][order.productId];
      if (closingPrice == 0) {
        emit DebugLog(
          string.concat(
            "Order ",
            Strings.toString(order.idx),
            " - Closing price is 0 for epoch ",
            Strings.toString(order.epoch)
          )
        );
        continue;
      }

      order.closingPrice = closingPrice;
      order.closingTime = endTime;

      bool isWin = (order.closingPrice > order.entryPrice && order.position == Position.Over) ||
        (order.closingPrice < order.entryPrice && order.position == Position.Under);

      if (isWin) {
        $.clearingHouse.settleEscrowWithFee(
          address(this),
          vaultAddress,
          order.user,
          order.epoch,
          order.collateralAmount,
          order.idx,
          0
        );
        $.clearingHouse.releaseFromEscrow(
          address(this),
          order.user,
          order.epoch,
          order.idx,
          order.amount,
          0
        );
        order.settleAmount = order.amount + order.collateralAmount;
      } else {
        $.clearingHouse.settleEscrowWithFee(
          address(this),
          order.user,
          vaultAddress,
          order.epoch,
          order.amount,
          order.idx,
          0
        );
        $.clearingHouse.releaseFromEscrow(
          address(this),
          vaultAddress,
          order.epoch,
          order.idx,
          order.collateralAmount,
          0
        );
        order.settleAmount = 0;
      }
      order.isSettled = true;

      emit OrderSettled(
        order.user,
        order.idx,
        order.epoch,
        order.closingPrice,
        order.closingTime,
        order.settleAmount
      );

      successfulOrderIds[successCount] = orderIds[i];
      successCount++;
    }

    // Create final array with exact size
    uint256[] memory result = new uint256[](successCount);
    for (uint i = 0; i < successCount; i++) {
      result[i] = successfulOrderIds[i];
    }

    return result;
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

  function setPythLazer(address _pythLazer) external whenPaused onlyOperator {
    if (_pythLazer == address(0)) revert InvalidAddress();
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    $.pythLazer = PythLazer(_pythLazer);
  }

  function setCommissionfee(uint256 productId, uint256 _commissionfee) external onlyOperator {
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
    $.vault = _vault;
  }
  function addPriceId(
    bytes32 _priceId,
    uint256 _productId,
    string calldata _symbol
  ) external onlyOperator {
    _addPriceId(_priceId, _productId, _symbol);
  }

  function initializeDefaultPriceIds() external onlyOperator {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();

    if (
      $.priceIdToProductId[0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43] ==
      0 &&
      $.priceInfos[0].priceId != 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
    ) {
      _addPriceId(0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43, 0, "BTC/USD");
      _addPriceId(0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace, 1, "ETH/USD");
      _addPriceId(
        0x89b814de1eb2afd3d3b498d296fca3a873e644bafb587e84d181a01edd682853,
        2,
        "ASTR/USD"
      );
      _addPriceId(0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d, 3, "SOL/USD");
    }
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
      $.vault,
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

  function priceInfos() external view returns (PriceInfo[] memory) {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    PriceInfo[] memory priceInfoArray = new PriceInfo[]($.priceIdCount);
    for (uint256 i = 0; i < $.priceIdCount; i++) {
      priceInfoArray[i] = $.priceInfos[i];
    }
    return priceInfoArray;
  }

  /* internal functions */
  function _getPythPrices(
    PriceUpdateData[] memory updateDataWithIds,
    uint64 timestamp
  ) internal returns (PythStructs.PriceFeed[] memory) {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();

    bytes[] memory updateData = new bytes[](updateDataWithIds.length);
    bytes32[] memory priceIds = new bytes32[](updateDataWithIds.length);

    for (uint256 i = 0; i < updateDataWithIds.length; i++) {
      updateData[i] = updateDataWithIds[i].priceData;
      priceIds[i] = $.priceInfos[updateDataWithIds[i].productId].priceId;
    }

    uint fee = $.oracle.getUpdateFee(updateData);
    return
      $.oracle.parsePriceFeedUpdates{ value: fee }(
        updateData,
        priceIds,
        timestamp,
        timestamp + uint64(BUFFER_SECONDS)
      );
  }

  function _processPythLazerPriceUpdate(
    PriceLazerData memory priceLazerData,
    uint64 timestamp
  ) internal {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();

    uint256 verificationFee = $.pythLazer.verification_fee();
    if (msg.value < verificationFee) {
      revert InsufficientVerificationFee(verificationFee, msg.value);
    }

    (bytes memory payload, ) = $.pythLazer.verifyUpdate{ value: verificationFee }(
      priceLazerData.priceData
    );
    if (msg.value > verificationFee) {
      payable(msg.sender).transfer(msg.value - verificationFee);
    }

    (, PythLazerLib.Channel channel, uint8 feedsLen, uint16 pos) = PythLazerLib.parsePayloadHeader(
      payload
    );
    if (channel != PythLazerLib.Channel.RealTime) {
      revert InvalidChannel();
    }

    for (uint8 i = 0; i < feedsLen; i++) {
      uint32 feedId;
      uint8 numProperties;
      (feedId, numProperties, pos) = PythLazerLib.parseFeedHeader(payload, pos);

      uint64 price = 0;
      bool priceFound = false;

      for (uint8 j = 0; j < numProperties; j++) {
        PythLazerLib.PriceFeedProperty property;
        (property, pos) = PythLazerLib.parseFeedProperty(payload, pos);
        if (property == PythLazerLib.PriceFeedProperty.Price) {
          (price, pos) = PythLazerLib.parseFeedValueUint64(payload, pos);
          priceFound = true;
        }
      }

      if (priceFound && price > 0) {
        uint256 productId = type(uint256).max;
        for (uint256 k = 0; k < priceLazerData.mappings.length; k++) {
          if (priceLazerData.mappings[k].priceFeedId == uint256(feedId)) {
            productId = priceLazerData.mappings[k].productId;
            break;
          }
        }

        // Check if productId is valid and price is reasonable
        if (productId != type(uint256).max) {
          $.priceHistory[timestamp][productId] = price;
        }
      }
    }
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

  function _addPriceId(bytes32 _priceId, uint256 _productId, string memory _symbol) internal {
    SuperVolOneMinStorage.Layout storage $ = SuperVolOneMinStorage.layout();
    if (_priceId == bytes32(0)) revert InvalidPriceId();
    if ($.priceIdToProductId[_priceId] != 0 || $.priceInfos[0].priceId == _priceId) {
      revert PriceIdAlreadyExists();
    }
    if ($.priceInfos[_productId].priceId != bytes32(0)) {
      revert ProductIdAlreadyExists();
    }
    if (bytes(_symbol).length == 0) {
      revert InvalidSymbol();
    }

    $.priceInfos[_productId] = PriceInfo({
      priceId: _priceId,
      productId: _productId,
      symbol: _symbol
    });

    $.priceIdToProductId[_priceId] = _productId;
    $.priceIdCount++;

    emit PriceIdAdded(_productId, _priceId, _symbol);
  }
}
