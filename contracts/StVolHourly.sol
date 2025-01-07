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
import "./interfaces/IVault.sol";
import { SuperVolStorage } from "./storage/SuperVolStorage.sol";
import { Round, FilledOrder, SettlementResult, WithdrawalRequest, Coupon, ProductRound, WinPosition } from "./Types.sol";


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

  modifier onlyAdmin() {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    require(msg.sender == $.adminAddress, "onlyAdmin");
    _;
  }
  modifier onlyOperator() {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    uint256 _commissionfee,
    address _vaultAddress
  ) public initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);
    __Pausable_init();
    __ReentrancyGuard_init();

    require(_commissionfee <= MAX_COMMISSION_FEE, "E04");

    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

    $.token = IERC20(0x770D5DE8dd09660F1141CF887D6B50976FBb12A0); // minato usdc
    $.oracle = IPyth(_oracleAddress);
    $.vault = IVault(_vaultAddress);
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

    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    uint256 index = $.lastSettledFilledOrderIndex[epoch];
    FilledOrder[] storage orders = $.filledOrders[epoch];
    return orders.length - index;
  }

  function deposit(uint256 amount) external nonReentrant {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.clearingHouse.deposit(msg.sender, amount);
  }

  function depositTo(address user, uint256 amount) external nonReentrant {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.clearingHouse.depositTo(msg.sender, user, amount);
  }

  function depositCouponTo(
    address user,
    uint256 amount,
    uint256 expirationEpoch
  ) external nonReentrant {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.clearingHouse.depositCouponTo(user, amount, expirationEpoch);
  }

  function reclaimAllExpiredCoupons() external nonReentrant {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    require(!$.vault.isVault(user), "Vault cannot withdraw");
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    require(!$.vault.isVault(user), "Vault cannot withdraw");
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

  function createVault(address vaultAddress, address user, uint256 sharePercentage) external nonReentrant onlyOperator {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.vault.createVault(vaultAddress, user, sharePercentage);
  }

  function depositToVault(address vaultAddress, address user, uint256 amount) external nonReentrant onlyOperator {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    require($.userBalances[user] >= amount, "Insufficient balance");
    uint256 memberShare = $.vault.depositToVault(vaultAddress, user, amount);
    $.userBalances[vaultAddress] += memberShare;
    $.userBalances[user] -= memberShare;
}

function withdrawFromVault(address vaultAddress, address user, uint256 amount) external nonReentrant onlyOperator {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    uint256 memberShare = $.vault.withdrawFromVault(vaultAddress, user, amount);
    $.userBalances[vaultAddress] -= memberShare;
    $.userBalances[user] += memberShare;
}

  function getWithdrawalRequests(uint256 from) public view returns (WithdrawalRequest[] memory) {
    // return 100 requests (from ~ from+100)
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    require(idx < $.withdrawalRequests.length, "Invalid idx");
    WithdrawalRequest storage request = $.withdrawalRequests[idx];
    require(!request.processed, "Request already processed");

    request.processed = true;
    request.message = reason;

    emit WithdrawalRejected(request.user, request.amount);
  }

  function forceWithdrawAll() external nonReentrant {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    uint256 currentTreasuryAmount = $.treasuryAmount;
    $.treasuryAmount = 0;
    $.token.safeTransfer($.operatorVaultAddress, currentTreasuryAmount);
  }

  function retrieveMisplacedETH() external onlyAdmin {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    payable($.adminAddress).transfer(address(this).balance);
  }

  function retrieveMisplacedTokens(address _token) external onlyAdmin {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    require(address($.token) != _token, "invalid token address");
    IERC20 token = IERC20(_token);
    token.safeTransfer($.adminAddress, token.balanceOf(address(this)));
  }

  function unpause() external whenPaused onlyAdmin {
    _unpause();
  }

  function setOperator(address _operatorAddress) external onlyAdmin {
    require(_operatorAddress != address(0), "E31");
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.operatorAddress = _operatorAddress;
  }

  function setOperatorVault(address _operatorVaultAddress) external onlyAdmin {
    require(_operatorVaultAddress != address(0), "E31");
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.operatorVaultAddress = _operatorVaultAddress;
  }

  function setOracle(address _oracle) external whenPaused onlyAdmin {
    require(_oracle != address(0), "E31");
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.oracle = IPyth(_oracle);
  }

  function setCommissionfee(uint256 _commissionfee) external whenPaused onlyAdmin {
    require(_commissionfee <= MAX_COMMISSION_FEE, "E04");
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.commissionfee = _commissionfee;
  }

  function setAdmin(address _adminAddress) external onlyOwner {
    require(_adminAddress != address(0), "E31");
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.adminAddress = _adminAddress;
  }

  function setToken(address _token) external onlyAdmin {
    require(_token != address(0), "E31");
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.token = IERC20(_token); 
  }

  function setVault(address _vault) external onlyAdmin {
    require(_vault != address(0), "E31");
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.vault = IVault(_vault);
  } 

  /* public views */
  function commissionfee() public view returns (uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return $.commissionfee;
  }

  function treasuryAmount() public view returns (uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return $.treasuryAmount;
  }

  function addresses() public view returns (address, address, address) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return ($.adminAddress, $.operatorAddress, $.operatorVaultAddress);
  }

  function balances(address user) public view returns (uint256, uint256, uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    uint256 depositBalance = $.userBalances[user];
    uint256 couponBalance = couponBalanceOf(user);
    uint256 totalBalance = depositBalance + couponBalance;
    return (depositBalance, couponBalance, totalBalance);
  }

  function balanceOf(address user) public view returns (uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return $.userBalances[user];
  }

  function couponBalanceOf(address user) public view returns (uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return $.couponHolders;
  }

  function userCoupons(address user) public view returns (Coupon[] memory) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return $.couponBalances[user];
  }

  function rounds(uint256 epoch, uint256 productId) public view returns (ProductRound memory) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return $.filledOrders[epoch];
  }

  function filledOrdersWithResult(
    uint256 epoch,
    uint256 chunkSize,
    uint256 offset
  ) public view returns (FilledOrder[] memory, SettlementResult[] memory) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return $.lastFilledOrderId;
  }

  function lastSettledFilledOrderId() public view returns (uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return $.lastSettledFilledOrderId;
  }

  function vault() public view returns (address) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return address($.vault);
  }

  /* internal functions */
  function _getPythPrices(
    bytes[] memory updateData,
    uint64 timestamp
  ) internal returns (PythStructs.PriceFeed[] memory) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

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

    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
      uint256 remainingAmount = _useCoupon(order.overUser, fee, order.epoch);

      $.userBalances[order.overUser] -= remainingAmount;
      if ($.vault.isVault(order.overUser)) {
        _processVaultTransaction(order.idx, order.overUser, remainingAmount, false);
      } 
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
      if ($.vault.isVault(order.overUser)) {
        _processVaultTransaction(order.idx, order.overUser, remainingAmount, false);
      } 

      uint256 fee = (amount * $.commissionfee) / BASE;
      $.treasuryAmount += fee;
      $.userBalances[order.underUser] += (amount - fee);
      collectedFee += fee;
      if ($.vault.isVault(order.underUser)) {
        _processVaultTransaction(order.idx, order.underUser, (amount - fee), true);
      } 

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
      if ($.vault.isVault(order.underUser)) {
        _processVaultTransaction(order.idx, order.underUser, remainingAmount, false);
      } 

      uint256 fee = (amount * $.commissionfee) / BASE;
      $.treasuryAmount += fee;
      $.userBalances[order.overUser] += (amount - fee);
      collectedFee += fee;
      if ($.vault.isVault(order.overUser)) {
        _processVaultTransaction(order.idx, order.overUser, (amount - fee), true);
      } 

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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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

  function _processVaultTransaction(uint256 orderIdx, address vaultAddress, uint256 amount, bool isWin) internal {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.vault.processVaultTransaction(orderIdx, vaultAddress, amount, isWin);  
  }
}
