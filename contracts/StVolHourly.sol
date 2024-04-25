// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

enum YieldMode {
  AUTOMATIC,
  VOID,
  CLAIMABLE
}

interface IERC20Rebasing {
  function configure(YieldMode) external returns (uint256);
  function claim(address recipient, uint256 amount) external returns (uint256);
  function getClaimableAmount(address account) external view returns (uint256);
}

enum GasMode {
  VOID,
  CLAIMABLE
}

interface IBlast {
  function configureClaimableGas() external;
  function claimAllGas(address contractAddress, address recipient) external returns (uint256);
  function claimMaxGas(address contractAddress, address recipientOfGas) external returns (uint256);
  function readGasParams(
    address contractAddress
  )
    external
    view
    returns (uint256 etherSeconds, uint256 etherBalance, uint256 lastUpdated, GasMode);
}

contract StVolHourly is
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;

  function _priceIds() internal pure returns (bytes32[] memory) {
    // to add products, upgrade the contract
    bytes32[] memory priceIds;
    // priceIds[productId] = pyth price id
    priceIds[0] = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43; // btc
    priceIds[1] = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace; // eth

    return priceIds;
  }

  // for blast
  IERC20 public constant USDB = IERC20(0x0B8a205c26ECFc423DE29a8EF18e1229a0Cc4F47);
  IERC20Rebasing public constant WETH = IERC20Rebasing(0x4200000000000000000000000000000000000023);
  IBlast public constant BLAST = IBlast(0x4300000000000000000000000000000000000002);

  uint256 private constant BASE = 10000; // 100%
  uint256 private constant MAX_COMMISSION_FEE = 200; // 2%
  uint256 private constant INTERVAL_SECONDS = 3600; // 60 * 60 (1 hour)
  uint256 private constant BUFFER_SECONDS = 600; // 10 * 60 (10min)
  uint256 private constant START_TIMESTAMP = 1713571200; // for epoch

  /// @custom:storage-location erc7201:stvolhourly.main
  struct MainStorage {
    IERC20 token; // Prediction token
    IPyth oracle;
    address adminAddress; // address of the admin
    address operatorAddress; // address of the operator
    address operatorVaultAddress; // address of the operator vault
    uint256 commissionfee; // commission rate (e.g. 200 = 2%, 150 = 1.50%)
    uint256 treasuryAmount; // treasury amount that was not claimed
    mapping(uint256 => Round) rounds;
    mapping(address => uint256) userBalances; // key: user address, value: balance
    mapping(uint256 => FilledOrder[]) filledOrders; // key: epoch

    /* you can add new variables here */
  }

  // keccak256(abi.encode(uint256(keccak256("stvolhourly.main")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 private constant MAIN_STORAGE_LOCATION =
    0x7540e4d744f0b58dc1a1a9299f0ac1b1135db4f19c435295e4707fb841fa8700;

  enum Position {
    Over,
    Under
  }

  enum OrderType {
    Market,
    Limit
  }

  struct Round {
    uint256 epoch;
    uint256 startTimestamp;
    uint256 endTimestamp;
    bool isSettled;
    mapping(uint256 => uint256) startPrice; // key: productId
    mapping(uint256 => uint256) endPrice; // key: productId
  }

  struct FilledOrder {
    uint256 idx;
    uint256 epoch;
    uint256 productId;
    uint256 strike;
    address overUser;
    address underUser;
    uint256 overPrice;
    uint256 underPrice; // over_price + under_price = 100 * decimal
    uint256 unit;
    bool isSettled; // default: false
  }

  event Deposit(address from, address to, uint256 amount, uint256 result);
  event Withdraw(address to, uint256 amount, uint256 result);
  event StartRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);
  event EndRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);
  event RoundSettled(uint256 indexed epoch, uint256 orderCount, uint256 collectedFee);

  function _getMainStorage() internal pure returns (MainStorage storage $) {
    assembly {
      $.slot := MAIN_STORAGE_LOCATION
    }
  }

  modifier onlyAdmin() {
    MainStorage storage $ = _getMainStorage();
    require(msg.sender == $.adminAddress, "onlyAdmin");
    _;
  }
  modifier onlyOperator() {
    MainStorage storage $ = _getMainStorage();
    require(msg.sender == $.operatorAddress, "onlyOperator");
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(
    address _oracleAddress,
    address _adminAddress,
    address _operatorAddress,
    address _operatorVaultAddress,
    uint256 _commissionfee
  ) public initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);
    __Pausable_init();
    __ReentrancyGuard_init();

    require(_commissionfee <= MAX_COMMISSION_FEE, "E04");

    MainStorage storage $ = _getMainStorage();

    $.token = USDB;
    $.oracle = IPyth(_oracleAddress);
    $.adminAddress = _adminAddress;
    $.operatorAddress = _operatorAddress;
    $.operatorVaultAddress = _operatorVaultAddress;
    $.commissionfee = _commissionfee;

    WETH.configure(YieldMode.CLAIMABLE);
    BLAST.configureClaimableGas();
  }

  function currentEpoch() external view returns (uint256) {
    return _epochAt(block.timestamp);
  }

  function executeRound(
    bytes[] calldata priceUpdateData,
    uint64 initDate
  ) external payable whenNotPaused onlyOperator {
    require(initDate % 3600 == 0, "invalid initDate"); // Ensure initDate is on the hour in seconds since Unix epoch.

    PythStructs.PriceFeed[] memory feeds = _getPythPrices(priceUpdateData, initDate);

    uint256 startEpoch = _epochAt(initDate);

    MainStorage storage $ = _getMainStorage();
    for (uint i = 0; i < feeds.length; i++) {
      _executeRound($, i, startEpoch, feeds[i], initDate);
    }
    _settleFilledOrders(startEpoch - 1);
  }

  function deposit(uint256 amount) external nonReentrant {
    MainStorage storage $ = _getMainStorage();
    $.token.safeTransferFrom(msg.sender, address(this), amount);
    $.userBalances[msg.sender] += amount;
    emit Deposit(msg.sender, msg.sender, amount, $.userBalances[msg.sender]);
  }

  function depositTo(address user, uint256 amount) external nonReentrant {
    MainStorage storage $ = _getMainStorage();
    $.token.safeTransferFrom(msg.sender, address(this), amount);
    $.userBalances[user] += amount;
    emit Deposit(msg.sender, user, amount, $.userBalances[user]);
  }

  function withdraw(address user, uint256 amount) external nonReentrant onlyOperator {
    MainStorage storage $ = _getMainStorage();
    require($.userBalances[user] >= amount, "user balance");
    $.userBalances[user] -= amount;
    $.token.safeTransfer(user, amount);
    emit Withdraw(user, amount, $.userBalances[user]);
  }

  function submitFilledOrders(bytes[] calldata transactions) external nonReentrant onlyOperator {}

  function pause() external whenNotPaused onlyAdmin {
    _pause();
  }

  function claimTreasury() external nonReentrant onlyAdmin {
    MainStorage storage $ = _getMainStorage();
    uint256 currentTreasuryAmount = $.treasuryAmount;
    $.treasuryAmount = 0;
    $.token.safeTransfer($.operatorVaultAddress, currentTreasuryAmount);
  }

  function retrieveMisplacedETH() external onlyAdmin {
    MainStorage storage $ = _getMainStorage();
    payable($.adminAddress).transfer(address(this).balance);
  }

  function retrieveMisplacedTokens(address _token) external onlyAdmin {
    MainStorage storage $ = _getMainStorage();
    require(address($.token) != _token, "invalid token address");
    IERC20 token = IERC20(_token);
    token.safeTransfer($.adminAddress, token.balanceOf(address(this)));
  }

  function unpause() external whenPaused onlyAdmin {
    _unpause();
  }

  function setOperator(address _operatorAddress) external onlyAdmin {
    require(_operatorAddress != address(0), "E31");
    MainStorage storage $ = _getMainStorage();
    $.operatorAddress = _operatorAddress;
  }

  function setOperatorVault(address _operatorVaultAddress) external onlyAdmin {
    require(_operatorVaultAddress != address(0), "E31");
    MainStorage storage $ = _getMainStorage();
    $.operatorVaultAddress = _operatorVaultAddress;
  }

  function setOracle(address _oracle) external whenPaused onlyAdmin {
    require(_oracle != address(0), "E31");
    MainStorage storage $ = _getMainStorage();
    $.oracle = IPyth(_oracle);
  }

  function setCommissionfee(uint256 _commissionfee) external whenPaused onlyAdmin {
    require(_commissionfee <= MAX_COMMISSION_FEE, "E04");
    MainStorage storage $ = _getMainStorage();
    $.commissionfee = _commissionfee;
  }

  function setAdmin(address _adminAddress) external onlyOwner {
    require(_adminAddress != address(0), "E31");
    MainStorage storage $ = _getMainStorage();
    $.adminAddress = _adminAddress;
  }

  /* public views */
  function commissionfee() public view returns (uint256) {
    MainStorage storage $ = _getMainStorage();
    return $.commissionfee;
  }
  function treasuryAmount() public view returns (uint256) {
    MainStorage storage $ = _getMainStorage();
    return $.treasuryAmount;
  }
  function addresses() public view returns (address, address, address) {
    MainStorage storage $ = _getMainStorage();
    return ($.adminAddress, $.operatorAddress, $.operatorVaultAddress);
  }
  function balanceOf(address user) public view returns (uint256) {
    MainStorage storage $ = _getMainStorage();
    return $.userBalances[user];
  }

  /* internal functions */
  function _executeRound(
    MainStorage storage $,
    uint256 productId,
    uint256 startEpoch,
    PythStructs.PriceFeed memory feed,
    uint64 initDate
  ) internal {
    uint64 pythPrice = uint64(feed.price.price);

    _startRound(startEpoch, productId, pythPrice, initDate);

    Round storage prevRound = $.rounds[startEpoch - 1];
    if (
      prevRound.epoch == startEpoch - 1 &&
      prevRound.startTimestamp > 0 &&
      prevRound.startPrice[productId] > 0
    ) {
      // end prev round
      _endRound(prevRound.epoch, productId, pythPrice, initDate);
    }
  }

  function _getPythPrices(
    bytes[] memory updateData,
    uint64 timestamp
  ) internal returns (PythStructs.PriceFeed[] memory) {
    MainStorage storage $ = _getMainStorage();

    uint fee = $.oracle.getUpdateFee(updateData);
    PythStructs.PriceFeed[] memory pythPrice = $.oracle.parsePriceFeedUpdates{ value: fee }(
      updateData,
      _priceIds(),
      timestamp,
      timestamp + uint64(BUFFER_SECONDS)
    );
    return pythPrice;
  }

  function _settleFilledOrders(uint256 epoch) internal {
    MainStorage storage $ = _getMainStorage();
    Round storage round = $.rounds[epoch];
    if (round.epoch == 0 || round.startTimestamp == 0 || round.endTimestamp == 0 || round.isSettled)
      return;

    uint256 collectedFee = 0;
    FilledOrder[] storage orders = $.filledOrders[epoch];
    for (uint i = 0; i < orders.length; i++) {
      FilledOrder storage order = orders[i];
      if (order.isSettled) continue;

      uint256 strikePrice = (round.startPrice[order.productId] * order.strike) / 10000;

      bool isOverWin = strikePrice < round.endPrice[order.productId];
      bool isUnderWin = strikePrice > round.endPrice[order.productId];

      if (isUnderWin) {
        uint256 amount = order.overPrice * order.unit;
        uint256 fee = (amount * $.commissionfee) / BASE;
        $.userBalances[order.overUser] -= amount;
        $.treasuryAmount += fee;
        $.userBalances[order.underUser] += (amount - fee);
        collectedFee += fee;
      } else if (isOverWin) {
        uint256 amount = order.underPrice * order.unit;
        uint256 fee = (amount * $.commissionfee) / BASE;
        $.userBalances[order.underUser] -= amount;
        $.treasuryAmount += fee;
        $.userBalances[order.overUser] += (amount - fee);
        collectedFee += fee;
      }

      order.isSettled = true;
    }
    round.isSettled = true;
    emit RoundSettled(epoch, orders.length, collectedFee);
  }

  function _endRound(uint256 epoch, uint256 productId, uint256 price, uint256 initDate) internal {
    MainStorage storage $ = _getMainStorage();
    Round storage round = $.rounds[epoch];
    require(round.startTimestamp != 0, "E26");

    round.endTimestamp = initDate;
    round.endPrice[productId] = price;

    emit EndRound(epoch, productId, price, initDate);
  }

  function _startRound(uint256 epoch, uint256 productId, uint256 price, uint256 initDate) internal {
    MainStorage storage $ = _getMainStorage();
    Round storage round = $.rounds[epoch];
    round.epoch = epoch;
    round.startTimestamp = initDate;
    round.endTimestamp = initDate + INTERVAL_SECONDS;
    round.startPrice[productId] = price;

    emit StartRound(epoch, productId, price, initDate);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  function _combine(uint256 a, uint256 b) internal pure returns (uint256) {
    return (a << 128) | b;
  }

  function _verify(
    bytes32 hash,
    bytes memory signature,
    string calldata message,
    address signer
  ) public pure returns (bool) {
    bytes32 ethSignedHash = keccak256(abi.encodePacked(message, hash));

    (bytes32 r, bytes32 s, uint8 v) = _splitSignature(signature);
    address recovered = ecrecover(ethSignedHash, v, r, s);

    return (recovered == signer);
  }

  function _splitSignature(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
    require(sig.length == 65, "invalid signature length");

    assembly {
      r := mload(add(sig, 32))
      s := mload(add(sig, 64))
      v := byte(0, mload(add(sig, 96)))
    }
  }

  function _epochAt(uint256 timestamp) internal pure returns (uint256) {
    require(timestamp >= START_TIMESTAMP, "Epoch has not started yet");

    uint256 elapsedSeconds = timestamp - START_TIMESTAMP;
    uint256 elapsedHours = elapsedSeconds / 3600;
    return elapsedHours;
  }

  // blast functions

  function getClaimableYield(address tokenAddress) external view onlyOwner returns (uint256) {
    return IERC20Rebasing(tokenAddress).getClaimableAmount(address(this));
  }

  function claimYield(
    address tokenAddress,
    address recipient
  ) external onlyOwner returns (uint256 claimAmount) {
    IERC20Rebasing token = IERC20Rebasing(tokenAddress);
    claimAmount = token.getClaimableAmount(address(this));
    token.claim(recipient, claimAmount);
  }

  function getClaimableGas()
    external
    view
    onlyOwner
    returns (uint256 etherSeconds, uint256 etherBalance, uint256 lastUpdated, GasMode)
  {
    return BLAST.readGasParams(address(this));
  }

  function claimAllGas(address recipient) external onlyOwner returns (uint256) {
    return BLAST.claimAllGas(address(this), recipient);
  }

  function claimMaxGas(address recipient) external onlyOwner returns (uint256) {
    return BLAST.claimMaxGas(address(this), recipient);
  }
}
