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

contract StVolHourly is
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;

  function _priceIds() internal pure returns (bytes32[] memory) {
    // https://pyth.network/developers/price-feed-ids#pyth-evm-stable
    // to add products, upgrade the contract
    bytes32[] memory priceIds = new bytes32[](2);
    // priceIds[productId] = pyth price id
    priceIds[0] = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43; // btc
    priceIds[1] = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace; // eth
    // priceIds[2] = 0x4ca4beeca86f0d164160323817a4e42b10010a724c2217c6ee41b54cd4cc61fc; // wif

    return priceIds;
  }

  uint256 private constant PRICE_UNIT = 1e18;
  uint256 private constant BASE = 10000; // 100%
  uint256 private constant MAX_COMMISSION_FEE = 200; // 2%
  uint256 private constant INTERVAL_SECONDS = 3600; // 60 * 60 (1 hour)
  uint256 private constant BUFFER_SECONDS = 600; // 10 * 60 (10min)
  uint256 private constant START_TIMESTAMP = 1719532800; // for epoch

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
    uint256 lastFilledOrderId;
    uint256 lastSubmissionTime;
    WithdrawalRequest[] withdrawalRequests;
    uint256 lastSettledFilledOrderId; // globally
    mapping(uint256 => uint256) lastSettledFilledOrderIndex; // by round(epoch)

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
    bool isSettled; // true when endPrice is set
    mapping(uint256 => uint256) startPrice; // key: productId
    mapping(uint256 => uint256) endPrice; // key: productId
    bool isStarted;
  }

  struct ProductRound {
    uint256 epoch;
    uint256 startTimestamp;
    uint256 endTimestamp;
    bool isSettled;
    uint256 startPrice;
    uint256 endPrice;
    bool isStarted;
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

  struct WithdrawalRequest {
    uint256 idx;
    address user;
    uint256 amount;
    bool processed;
    string message;
    uint256 created;
  }

  event Deposit(address indexed to, address from, uint256 amount, uint256 result);
  event Withdraw(address indexed to, uint256 amount, uint256 result);
  event StartRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);
  event EndRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);
  event OrderSettled(
    address indexed user,
    uint256 indexed idx,
    uint256 epoch,
    uint256 prevBalance,
    uint256 newBalance
  );
  event RoundSettled(uint256 indexed epoch, uint256 orderCount, uint256 collectedFee);
  event WithdrawalRequested(address indexed user, uint256 amount);
  event WithdrawalApproved(address indexed user, uint256 amount);
  event WithdrawalRejected(address indexed user, uint256 amount);

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

    $.token = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913); // base usdc
    $.oracle = IPyth(_oracleAddress);
    $.adminAddress = _adminAddress;
    $.operatorAddress = _operatorAddress;
    $.operatorVaultAddress = _operatorVaultAddress;
    $.commissionfee = _commissionfee;
  }

  function currentEpoch() external view returns (uint256) {
    return _epochAt(block.timestamp);
  }

  function executeRound(
    bytes[] calldata priceUpdateData,
    uint64 initDate,
    bool skipSettlement
  ) external payable whenNotPaused onlyOperator {
    require(initDate % 3600 == 0, "invalid initDate"); // Ensure initDate is on the hour in seconds since Unix epoch.

    PythStructs.PriceFeed[] memory feeds = _getPythPrices(priceUpdateData, initDate);

    uint256 startEpoch = _epochAt(initDate);

    MainStorage storage $ = _getMainStorage();

    // start current round
    Round storage round = $.rounds[startEpoch];
    if (!round.isStarted) {
      round.epoch = startEpoch;
      round.startTimestamp = initDate;
      round.endTimestamp = initDate + INTERVAL_SECONDS;

      for (uint i = 0; i < feeds.length; i++) {
        uint64 pythPrice = uint64(feeds[i].price.price);
        round.startPrice[i] = pythPrice;
        emit StartRound(startEpoch, i, pythPrice, initDate);
      }
      round.isStarted = true;
    }

    // end prev round (if started)
    uint256 prevEpoch = startEpoch - 1;
    Round storage prevRound = $.rounds[prevEpoch];
    if (
      prevRound.epoch == prevEpoch &&
      prevRound.startTimestamp > 0 &&
      prevRound.isStarted &&
      !prevRound.isSettled
    ) {
      prevRound.endTimestamp = initDate;

      for (uint i = 0; i < feeds.length; i++) {
        uint64 pythPrice = uint64(feeds[i].price.price);
        prevRound.endPrice[i] = pythPrice;
        emit EndRound(prevEpoch, i, pythPrice, initDate);
      }
    }

    if (!skipSettlement) {
      _settleFilledOrders(prevRound);
    }
  }

  function settleFilledOrders(uint256 epoch, uint256 size) public onlyOperator returns (uint256) {
    MainStorage storage $ = _getMainStorage();
    Round storage round = $.rounds[epoch];

    require(round.epoch > 0 && round.startTimestamp > 0 && round.endTimestamp > 0, "invalid round");
    require(round.startPrice[0] > 0 && round.endPrice[0] > 0, "invalid round price");

    FilledOrder[] storage orders = $.filledOrders[epoch];
    uint256 startIndex = $.lastSettledFilledOrderIndex[epoch];
    uint256 endIndex = startIndex + size < orders.length ? startIndex + size : orders.length;

    uint256 collectedFee = 0;

    for (uint i = startIndex; i < endIndex; i++) {
      FilledOrder storage order = orders[i];
      collectedFee += _settleFilledOrder(round, order);
    }
    $.lastSettledFilledOrderIndex[epoch] = endIndex;

    return orders.length - endIndex;
  }

  function countUnsettledFilledOrders(uint256 epoch) external view returns (uint256) {
    MainStorage storage $ = _getMainStorage();
    uint256 index = $.lastSettledFilledOrderIndex[epoch];
    FilledOrder[] storage orders = $.filledOrders[epoch];
    return orders.length - index;
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
    emit Deposit(user, msg.sender, amount, $.userBalances[user]);
  }

  function withdraw(address user, uint256 amount) external nonReentrant onlyOperator {
    MainStorage storage $ = _getMainStorage();
    require($.userBalances[user] >= amount, "Insufficient user balance");
    $.userBalances[user] -= amount;
    $.token.safeTransfer(user, amount);
    emit Withdraw(user, amount, $.userBalances[user]);
  }

  function requestWithdrawal(
    uint256 amount
  ) external nonReentrant returns (WithdrawalRequest memory) {
    address user = msg.sender;
    MainStorage storage $ = _getMainStorage();
    require(amount > 0, "Amount must be greater than zero");
    require($.userBalances[user] >= amount, "Insufficient user balance");

    WithdrawalRequest memory request = WithdrawalRequest({
      idx: $.withdrawalRequests.length,
      user: msg.sender,
      amount: amount,
      processed: false,
      message: "",
      created: block.timestamp
    });

    $.withdrawalRequests.push(request);

    emit WithdrawalRequested(msg.sender, amount);
    return request;
  }

  function getWithdrawalRequests(uint256 from) public view returns (WithdrawalRequest[] memory) {
    // return 100 requests (from ~ from+100)
    MainStorage storage $ = _getMainStorage();
    uint256 totalRequests = $.withdrawalRequests.length;

    if (totalRequests < 100) {
      return $.withdrawalRequests;
    } else {
      uint256 startFrom = from < totalRequests - 100 ? from : totalRequests - 100;

      WithdrawalRequest[] memory recentRequests = new WithdrawalRequest[](100);
      for (uint256 i = 0; i < 100; i++) {
        recentRequests[i] = $.withdrawalRequests[startFrom + i];
      }

      return recentRequests;
    }
  }

  function approveWithdrawal(uint256 idx) public nonReentrant onlyOperator {
    MainStorage storage $ = _getMainStorage();
    require(idx < $.withdrawalRequests.length, "Invalid idx");
    WithdrawalRequest storage request = $.withdrawalRequests[idx];
    require(!request.processed, "Request already processed");
    require($.userBalances[request.user] >= request.amount, "Insufficient user balance");

    request.processed = true;

    $.userBalances[request.user] -= request.amount;
    $.token.safeTransfer(request.user, request.amount);

    emit WithdrawalApproved(request.user, request.amount);
  }

  function rejectWithdrawal(uint256 idx, string calldata reason) public nonReentrant onlyOperator {
    MainStorage storage $ = _getMainStorage();
    require(idx < $.withdrawalRequests.length, "Invalid idx");
    WithdrawalRequest storage request = $.withdrawalRequests[idx];
    require(!request.processed, "Request already processed");

    request.processed = true;
    request.message = reason;

    emit WithdrawalRejected(request.user, request.amount);
  }

  function forceWithdrawAll() external nonReentrant {
    MainStorage storage $ = _getMainStorage();
    require(block.timestamp >= $.lastSubmissionTime + 1 hours, "invalid time");
    uint256 balance = $.userBalances[msg.sender];
    $.userBalances[msg.sender] = 0;
    $.token.safeTransfer(msg.sender, balance);
    emit Withdraw(msg.sender, balance, 0);
  }

  function submitFilledOrders(
    FilledOrder[] calldata transactions
  ) external nonReentrant onlyOperator {
    MainStorage storage $ = _getMainStorage();
    require($.lastFilledOrderId + 1 == transactions[0].idx, "invalid id");
    for (uint i = 0; i < transactions.length; i++) {
      FilledOrder calldata order = transactions[i];
      FilledOrder[] storage orders = $.filledOrders[order.epoch];
      orders.push(order);

      Round storage round = $.rounds[order.epoch];
      if (round.isSettled) {
        _settleFilledOrder(round, orders[orders.length - 1]);
      }
    }
    $.lastFilledOrderId = transactions[transactions.length - 1].idx;
    $.lastSubmissionTime = block.timestamp;
  }

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

  function rounds(uint256 epoch, uint256 productId) public view returns (ProductRound memory) {
    MainStorage storage $ = _getMainStorage();
    Round storage round = $.rounds[epoch];
    if (round.epoch == 0) {
      (uint256 startTime, uint256 endTime) = _epochTimes(epoch);
      return
        // return virtual value
        ProductRound({
          epoch: epoch,
          startTimestamp: startTime,
          endTimestamp: endTime,
          isStarted: false,
          isSettled: false,
          startPrice: 0,
          endPrice: 0
        });
    }
    return
      // return storage value
      ProductRound({
        epoch: round.epoch,
        startTimestamp: round.startTimestamp,
        endTimestamp: round.endTimestamp,
        isStarted: round.isStarted,
        isSettled: round.isSettled,
        startPrice: round.startPrice[productId],
        endPrice: round.endPrice[productId]
      });
  }

  function filledOrders(uint256 epoch) public view returns (FilledOrder[] memory) {
    MainStorage storage $ = _getMainStorage();
    return $.filledOrders[epoch];
  }

  function userFilledOrders(
    uint256 epoch,
    address user
  ) public view returns (FilledOrder[] memory) {
    MainStorage storage $ = _getMainStorage();
    FilledOrder[] storage orders = $.filledOrders[epoch];
    uint cnt = 0;
    for (uint i = 0; i < orders.length; i++) {
      FilledOrder storage order = orders[i];
      if (order.overUser == user || order.underUser == user) {
        cnt++;
      }
    }
    FilledOrder[] memory userOrders = new FilledOrder[](cnt);
    uint idx = 0;
    for (uint i = 0; i < orders.length; i++) {
      FilledOrder storage order = orders[i];
      if (order.overUser == user || order.underUser == user) {
        userOrders[idx] = order;
        idx++;
      }
    }

    return userOrders;
  }

  function lastFilledOrderId() public view returns (uint256) {
    MainStorage storage $ = _getMainStorage();
    return $.lastFilledOrderId;
  }

  function lastSettledFilledOrderId() public view returns (uint256) {
    MainStorage storage $ = _getMainStorage();
    return $.lastSettledFilledOrderId;
  }

  /* internal functions */
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

  function _settleFilledOrders(Round storage round) internal {
    MainStorage storage $ = _getMainStorage();

    if (round.epoch == 0 || round.startTimestamp == 0 || round.endTimestamp == 0 || round.isSettled)
      return;

    uint256 collectedFee = 0;
    FilledOrder[] storage orders = $.filledOrders[round.epoch];
    for (uint i = 0; i < orders.length; i++) {
      FilledOrder storage order = orders[i];
      collectedFee += _settleFilledOrder(round, order);
    }
    $.lastSettledFilledOrderIndex[round.epoch] = orders.length;
    round.isSettled = true;
    emit RoundSettled(round.epoch, orders.length, collectedFee);
  }

  function _settleFilledOrder(
    Round storage round,
    FilledOrder storage order
  ) internal returns (uint256) {
    if (order.isSettled) return 0;

    MainStorage storage $ = _getMainStorage();

    uint256 strikePrice = (round.startPrice[order.productId] * order.strike) / 10000;

    bool isOverWin = strikePrice < round.endPrice[order.productId];
    bool isUnderWin = strikePrice > round.endPrice[order.productId];

    uint256 collectedFee = 0;

    if (order.overUser == order.underUser) {
      uint256 amount = 100 * order.unit * PRICE_UNIT;
      uint256 fee = (amount * $.commissionfee) / BASE;
      $.userBalances[order.overUser] -= fee;
      $.treasuryAmount += fee;
      collectedFee += fee;
      emit OrderSettled(
        order.overUser,
        order.idx,
        order.epoch,
        $.userBalances[order.overUser] + fee,
        $.userBalances[order.overUser]
      );
    } else if (isUnderWin) {
      uint256 amount = order.overPrice * order.unit * PRICE_UNIT;
      uint256 fee = (amount * $.commissionfee) / BASE;
      $.userBalances[order.overUser] -= amount;
      $.treasuryAmount += fee;
      $.userBalances[order.underUser] += (amount - fee);
      collectedFee += fee;

      emit OrderSettled(
        order.overUser,
        order.idx,
        order.epoch,
        $.userBalances[order.overUser] + amount,
        $.userBalances[order.overUser]
      );
      emit OrderSettled(
        order.underUser,
        order.idx,
        order.epoch,
        $.userBalances[order.underUser] - (amount - fee),
        $.userBalances[order.underUser]
      );
    } else if (isOverWin) {
      uint256 amount = order.underPrice * order.unit * PRICE_UNIT;
      uint256 fee = (amount * $.commissionfee) / BASE;
      $.userBalances[order.underUser] -= amount;
      $.treasuryAmount += fee;
      $.userBalances[order.overUser] += (amount - fee);
      collectedFee += fee;

      emit OrderSettled(
        order.underUser,
        order.idx,
        order.epoch,
        $.userBalances[order.underUser] + amount,
        $.userBalances[order.underUser]
      );
      emit OrderSettled(
        order.overUser,
        order.idx,
        order.epoch,
        $.userBalances[order.overUser] - (amount - fee),
        $.userBalances[order.overUser]
      );
    }

    order.isSettled = true;
    if ($.lastSettledFilledOrderId < order.idx) {
      $.lastSettledFilledOrderId = order.idx;
    }
    return collectedFee;
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

  function _epochTimes(uint256 epoch) public pure returns (uint256 startTime, uint256 endTime) {
    require(epoch >= 0, "Invalid epoch");
    startTime = START_TIMESTAMP + (epoch * 3600);
    endTime = startTime + 3600;
    return (startTime, endTime);
  }
}
