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
    bytes32[] memory priceIds = new bytes32[](3);
    // priceIds[productId] = pyth price id
    priceIds[0] = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43; // btc
    priceIds[1] = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace; // eth
    priceIds[2] = 0x89b814de1eb2afd3d3b498d296fca3a873e644bafb587e84d181a01edd682853; // astr
    return priceIds;
  }

  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant BASE = 10000; // 100%
  uint256 private constant MAX_COMMISSION_FEE = 500; // 5%
  uint256 private constant INTERVAL_SECONDS = 3600; // 60 * 60 (1 hour)
  uint256 private constant BUFFER_SECONDS = 600; // 10 * 60 (10min)
  uint256 private constant START_TIMESTAMP = 1726009200; // for epoch
  uint256 private constant WITHDRAWAL_FEE = PRICE_UNIT / 10; // 0.1

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
    mapping(address => Coupon[]) couponBalances; // user to coupon list
    uint256 couponAmount; // coupon vault
    uint256 usedCouponAmount; // coupon vault
    address[] couponHolders;
    mapping(uint256 => SettlementResult) settlementResults; // key: filled order idx

    /* you can add new variables here */
  }

  // keccak256(abi.encode(uint256(keccak256("supervolhourly.main")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 private constant MAIN_STORAGE_LOCATION =
    0x7bc1e9d19685053de57f492fbaf997aa4d3b21e5386e7247f8550dca24ee0b00;

  enum Position {
    Over,
    Under
  }

  enum WinPosition {
    Over,
    Under,
    Tie,
    Invalid
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

  struct SettlementResult {
    uint256 idx; // filled order idx
    WinPosition winPosition;
    uint256 winAmount;
    uint256 feeRate;
    uint256 fee;
  }

  struct WithdrawalRequest {
    uint256 idx;
    address user;
    uint256 amount;
    bool processed;
    string message;
    uint256 created;
  }

  struct Coupon {
    address user;
    uint256 amount;
    uint256 usedAmount;
    uint256 expirationEpoch;
    uint256 created;
    address issuer;
  }

  event Deposit(address indexed to, address from, uint256 amount, uint256 result);
  event Withdraw(address indexed to, uint256 amount, uint256 result);

  event DepositCoupon(
    address indexed to,
    address from,
    uint256 amount,
    uint256 expirationEpoch,
    uint256 result
  );

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

    $.token = IERC20(0xe722424e913f48bAC7CD2C1Ae981e2cD09bd95EC); // minato usdc
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
    uint256 currentEpochNumber = _epochAt(block.timestamp);

    MainStorage storage $ = _getMainStorage();

    // start current round
    Round storage round = $.rounds[startEpoch];
    if (startEpoch == currentEpochNumber && !round.isStarted) {
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
      prevRound.isSettled = true;
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

  function depositCouponTo(
    address user,
    uint256 amount,
    uint256 expirationEpoch
  ) external nonReentrant {
    MainStorage storage $ = _getMainStorage();

    $.token.safeTransferFrom(msg.sender, address(this), amount);
    $.couponAmount += amount;

    Coupon[] storage coupons = $.couponBalances[user];

    Coupon memory newCoupon = Coupon({
      user: user,
      amount: amount,
      usedAmount: 0,
      expirationEpoch: expirationEpoch,
      created: block.timestamp,
      issuer: msg.sender
    });

    uint i = coupons.length;
    coupons.push(newCoupon);

    if (i == 0) {
      // add user to couponHolders array
      $.couponHolders.push(user);
    }

    while (i > 0 && coupons[i - 1].expirationEpoch > newCoupon.expirationEpoch) {
      coupons[i] = coupons[i - 1];
      i--;
    }
    coupons[i] = newCoupon;

    emit DepositCoupon(user, msg.sender, amount, expirationEpoch, couponBalanceOf(user)); // 전체 쿠폰 잔액 계산
  }

  function reclaimAllExpiredCoupons() external nonReentrant {
    MainStorage storage $ = _getMainStorage();

    address[] memory memoryArray = new address[]($.couponHolders.length);
    for (uint i = 0; i < $.couponHolders.length; i++) {
      memoryArray[i] = $.couponHolders[i];
    }

    for (uint i = 0; i < memoryArray.length; i++) {
      _reclaimExpiredCoupons(memoryArray[i]);
    }
  }

  function reclaimExpiredCoupons(address user) external nonReentrant {
    _reclaimExpiredCoupons(user);
  }

  function withdraw(address user, uint256 amount) external nonReentrant onlyOperator {
    MainStorage storage $ = _getMainStorage();
    require(amount > 0, "Amount must be greater than 0");
    require($.userBalances[user] >= amount + WITHDRAWAL_FEE, "Insufficient user balance");
    $.userBalances[user] -= amount + WITHDRAWAL_FEE;
    $.treasuryAmount += WITHDRAWAL_FEE;
    $.token.safeTransfer(user, amount);
    emit Withdraw(user, amount, $.userBalances[user]);
  }

  function requestWithdrawal(
    uint256 amount
  ) external nonReentrant returns (WithdrawalRequest memory) {
    address user = msg.sender;
    MainStorage storage $ = _getMainStorage();
    require(amount > 0, "Amount must be greater than 0");
    require($.userBalances[user] >= amount + WITHDRAWAL_FEE, "Insufficient user balance");

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
    require(
      $.userBalances[request.user] >= request.amount + WITHDRAWAL_FEE,
      "Insufficient user balance"
    );
    request.processed = true;
    $.userBalances[request.user] -= request.amount + WITHDRAWAL_FEE;
    $.treasuryAmount += WITHDRAWAL_FEE;
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
    require(balance >= WITHDRAWAL_FEE, "insufficient user balance");
    $.userBalances[msg.sender] = 0;
    $.treasuryAmount += WITHDRAWAL_FEE;
    $.token.safeTransfer(msg.sender, balance - WITHDRAWAL_FEE);
    emit Withdraw(msg.sender, balance, 0);
  }

  function submitFilledOrders(
    FilledOrder[] calldata transactions
  ) external nonReentrant onlyOperator {
    MainStorage storage $ = _getMainStorage();
    require($.lastFilledOrderId + 1 <= transactions[0].idx, "invalid id");

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

  function setToken(address _token) external onlyOwner {
    require(_token != address(0), "E31");
    MainStorage storage $ = _getMainStorage();
    $.token = IERC20(_token); 
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

  function balances(address user) public view returns (uint256, uint256, uint256) {
    MainStorage storage $ = _getMainStorage();
    uint256 depositBalance = $.userBalances[user];
    uint256 couponBalance = couponBalanceOf(user);
    uint256 totalBalance = depositBalance + couponBalance;
    return (depositBalance, couponBalance, totalBalance);
  }

  function balanceOf(address user) public view returns (uint256) {
    MainStorage storage $ = _getMainStorage();
    return $.userBalances[user];
  }

  function couponBalanceOf(address user) public view returns (uint256) {
    MainStorage storage $ = _getMainStorage();
    uint256 total = 0;
    uint256 epoch = _epochAt(block.timestamp);
    for (uint i = 0; i < $.couponBalances[user].length; i++) {
      if ($.couponBalances[user][i].expirationEpoch >= epoch) {
        total += $.couponBalances[user][i].amount - $.couponBalances[user][i].usedAmount;
      }
    }
    return total;
  }

  function couponHolders() public view returns (address[] memory) {
    MainStorage storage $ = _getMainStorage();
    return $.couponHolders;
  }

  function userCoupons(address user) public view returns (Coupon[] memory) {
    MainStorage storage $ = _getMainStorage();
    return $.couponBalances[user];
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

  // function filledOrdersWithResult(uint256 epoch) public view returns (FilledOrder[] memory, SettlementResult[] memory) {
  //   MainStorage storage $ = _getMainStorage();
  //   FilledOrder[] memory orders = $.filledOrders[epoch];
  //   SettlementResult[] memory results = new SettlementResult[](orders.length);
  //   for (uint i = 0; i < orders.length ; i++) {
  //     results[i] = $.settlementResults[orders[i].idx];
  //   }
  //   return (orders, results);
  // }

  function filledOrdersWithResult(
    uint256 epoch,
    uint256 chunkSize,
    uint256 offset
  ) public view returns (FilledOrder[] memory, SettlementResult[] memory) {
    MainStorage storage $ = _getMainStorage();
    FilledOrder[] memory orders = $.filledOrders[epoch];
    if (offset >= orders.length) {
      return (new FilledOrder[](0), new SettlementResult[](0));
    }
    uint256 end = offset + chunkSize;
    if (end > orders.length) {
      end = orders.length;
    }
    FilledOrder[] memory chunkedOrders = new FilledOrder[](end - offset);
    SettlementResult[] memory chunkedResults = new SettlementResult[](end - offset);
    for (uint i = offset; i < end; i++) {
      chunkedOrders[i - offset] = orders[i];
      chunkedResults[i - offset] = $.settlementResults[orders[i].idx];
    }
    return (chunkedOrders, chunkedResults);
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

    if (round.epoch == 0 || round.startTimestamp == 0 || round.endTimestamp == 0) return;

    uint256 collectedFee = 0;
    FilledOrder[] storage orders = $.filledOrders[round.epoch];
    for (uint i = 0; i < orders.length; i++) {
      FilledOrder storage order = orders[i];
      collectedFee += _settleFilledOrder(round, order);
    }
    $.lastSettledFilledOrderIndex[round.epoch] = orders.length;

    emit RoundSettled(round.epoch, orders.length, collectedFee);
  }

  function fillSettlementResult(
    uint256[] calldata epochList
  ) external {
    // temporary function to fill settlement results
    MainStorage storage $ = _getMainStorage();
    for (uint a = 0; a < epochList.length; a ++) {
      uint256 epoch = epochList[a];
      FilledOrder[] storage orders = $.filledOrders[epoch];
      Round storage round = $.rounds[epoch];
      for (uint i = 0; i < orders.length ; i++) {
        FilledOrder storage order =  orders[i];
        _fillSettlementResult(round, order);
      }
    }
  }

  function _fillSettlementResult(Round storage round,
    FilledOrder storage order) internal {
      
    MainStorage storage $ = _getMainStorage();

    if (round.startPrice[order.productId] == 0 || round.endPrice[order.productId] == 0) return;

    uint256 strikePrice = (round.startPrice[order.productId] * order.strike) / 10000;

    bool isOverWin = strikePrice < round.endPrice[order.productId];
    bool isUnderWin = strikePrice > round.endPrice[order.productId];

    if (order.overPrice + order.underPrice != 100) {
      $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx, 
        winPosition: WinPosition.Invalid, 
        winAmount: 0, 
        feeRate: $.commissionfee,
        fee: 0
      });
    } else if (order.overUser == order.underUser) {
      uint256 loosePositionAmount = (
        isOverWin ? order.underPrice : isUnderWin ? order.overPrice : 0
      ) *
        order.unit *
        PRICE_UNIT;
      uint256 fee = (loosePositionAmount * $.commissionfee) / BASE;
      
      $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx, 
        winPosition: isOverWin ? WinPosition.Over : isUnderWin ? WinPosition.Under : WinPosition.Tie, 
        winAmount: loosePositionAmount, 
        feeRate: $.commissionfee,
        fee: fee
      });

    } else if (isUnderWin) {
      uint256 amount = order.overPrice * order.unit * PRICE_UNIT;
      uint256 fee = (amount * $.commissionfee) / BASE;
      
      $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx, 
        winPosition: WinPosition.Under, 
        winAmount: amount, 
        feeRate: $.commissionfee,
        fee: fee
      });

    } else if (isOverWin) {
      uint256 amount = order.underPrice * order.unit * PRICE_UNIT;
      uint256 fee = (amount * $.commissionfee) / BASE;

      $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx, 
        winPosition: WinPosition.Over, 
        winAmount: amount, 
        feeRate: $.commissionfee,
        fee: fee
      });

    } else {
      // no one wins
      $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx, 
        winPosition: WinPosition.Tie, 
        winAmount: 0, 
        feeRate: $.commissionfee,
        fee: 0
      });
    }
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

    if (order.overPrice + order.underPrice != 100) {
      emit OrderSettled(
        order.underUser,
        order.idx,
        order.epoch,
        $.userBalances[order.underUser],
        $.userBalances[order.underUser]
      );
      emit OrderSettled(
        order.overUser,
        order.idx,
        order.epoch,
        $.userBalances[order.overUser],
        $.userBalances[order.overUser]
      );
      
      $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx, 
        winPosition: WinPosition.Invalid, 
        winAmount: 0, 
        feeRate: $.commissionfee,
        fee: 0
      });

    } else if (order.overUser == order.underUser) {
      uint256 loosePositionAmount = (
        isOverWin ? order.underPrice : isUnderWin ? order.overPrice : 0
      ) *
        order.unit *
        PRICE_UNIT;
      uint256 fee = (loosePositionAmount * $.commissionfee) / BASE;
      uint256 remainingFee = _useCoupon(order.overUser, fee, order.epoch);
      $.userBalances[order.overUser] -= remainingFee;
      $.treasuryAmount += fee;
      collectedFee += fee;
      emit OrderSettled(
        order.overUser,
        order.idx,
        order.epoch,
        $.userBalances[order.overUser] + fee,
        $.userBalances[order.overUser]
      );
      $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx, 
        winPosition: isOverWin ? WinPosition.Over : isUnderWin ? WinPosition.Under : WinPosition.Tie, 
        winAmount: loosePositionAmount, 
        feeRate: $.commissionfee,
        fee: fee
      });

    } else if (isUnderWin) {
      uint256 amount = order.overPrice * order.unit * PRICE_UNIT;
      uint256 remainingAmount = _useCoupon(order.overUser, amount, order.epoch);
      $.userBalances[order.overUser] -= remainingAmount;

      uint256 fee = (amount * $.commissionfee) / BASE;
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

      $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx, 
        winPosition: WinPosition.Under, 
        winAmount: amount, 
        feeRate: $.commissionfee,
        fee: fee
      });

    } else if (isOverWin) {
      uint256 amount = order.underPrice * order.unit * PRICE_UNIT;
      uint256 remainingAmount = _useCoupon(order.underUser, amount, order.epoch);
      $.userBalances[order.underUser] -= remainingAmount;

      uint256 fee = (amount * $.commissionfee) / BASE;
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

      $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx, 
        winPosition: WinPosition.Over, 
        winAmount: amount, 
        feeRate: $.commissionfee,
        fee: fee
      });

    } else {
      // no one wins
      emit OrderSettled(
        order.underUser,
        order.idx,
        order.epoch,
        $.userBalances[order.underUser],
        $.userBalances[order.underUser]
      );
      emit OrderSettled(
        order.overUser,
        order.idx,
        order.epoch,
        $.userBalances[order.overUser],
        $.userBalances[order.overUser]
      );

      $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx, 
        winPosition: WinPosition.Tie, 
        winAmount: 0, 
        feeRate: $.commissionfee,
        fee: 0
      });

    }

    order.isSettled = true;
    if ($.lastSettledFilledOrderId < order.idx) {
      $.lastSettledFilledOrderId = order.idx;
    }
    return collectedFee;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  function _epochAt(uint256 timestamp) internal pure returns (uint256) {
    require(timestamp >= START_TIMESTAMP, "Epoch has not started yet");
    uint256 elapsedSeconds = timestamp - START_TIMESTAMP;
    uint256 elapsedHours = elapsedSeconds / 3600;
    return elapsedHours;
  }

  function _epochTimes(uint256 epoch) internal pure returns (uint256 startTime, uint256 endTime) {
    require(epoch >= 0, "Invalid epoch");
    startTime = START_TIMESTAMP + (epoch * 3600);
    endTime = startTime + 3600;
    return (startTime, endTime);
  }

  function _useCoupon(address user, uint256 amount, uint256 epoch) internal returns (uint256) {
    MainStorage storage $ = _getMainStorage();
    uint256 remainingAmount = amount;
    for (uint i = 0; i < $.couponBalances[user].length && remainingAmount > 0; i++) {
      if ($.couponBalances[user][i].expirationEpoch >= epoch) {
        uint256 availableAmount = $.couponBalances[user][i].amount -
          $.couponBalances[user][i].usedAmount;
        if (availableAmount >= remainingAmount) {
          $.couponBalances[user][i].usedAmount += remainingAmount;
          remainingAmount = 0;
        } else {
          $.couponBalances[user][i].usedAmount += availableAmount;
          remainingAmount -= availableAmount;
        }
      }
    }
    $.usedCouponAmount += amount - remainingAmount;

    return remainingAmount;
  }

  function _reclaimExpiredCoupons(address user) internal {
    MainStorage storage $ = _getMainStorage();
    uint256 epoch = _epochAt(block.timestamp);

    Coupon[] storage coupons = $.couponBalances[user];

    uint256 validCount = 0;
    for (uint i = 0; i < coupons.length; i++) {
      Coupon storage coupon = coupons[i];
      if (coupon.expirationEpoch < epoch) {
        uint256 availableAmount = coupon.amount - coupon.usedAmount;
        if (availableAmount > 0) {
          $.token.safeTransfer(coupon.issuer, availableAmount);
          $.couponAmount -= availableAmount;
          coupon.usedAmount = coupon.amount;
        }
      } else {
        // move valid coupons to the front of the array
        coupons[validCount] = coupon;
        validCount++;
      }
    }

    // remove expired coupons from the array
    while (coupons.length > validCount) {
      coupons.pop();
    }

    if (validCount == 0) {
      // remove user from couponHolders array
      uint length = $.couponHolders.length;
      for (uint i = 0; i < length; i++) {
        if ($.couponHolders[i] == user) {
          $.couponHolders[i] = $.couponHolders[length - 1];
          $.couponHolders.pop();
          break;
        }
      }
    }
  }
}