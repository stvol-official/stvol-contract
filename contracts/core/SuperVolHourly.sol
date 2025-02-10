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
import { SuperVolStorage} from "../storage/SuperVolStorage.sol";
import { Round, FilledOrder, Coupon, WithdrawalRequest, ProductRound, SettlementResult, WinPosition } from "../types/Types.sol";
import { ISuperVolErrors } from "../errors/SuperVolErrors.sol";

contract SuperVolHourly is
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
  uint256 private constant MAX_COMMISSION_FEE = 500; // 5%
  uint256 private constant INTERVAL_SECONDS = 3600; // 60 * 60 (1 hour)
  uint256 private constant BUFFER_SECONDS = 600; // 10 * 60 (10min)
  uint256 private constant START_TIMESTAMP = 1736294400; // for epoch

  event StartRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);
  event EndRound(uint256 indexed epoch, uint256 productId, uint256 price, uint256 timestamp);
  event OrderSettled(
    address indexed user,
    uint256 indexed idx,
    uint256 epoch,
    uint256 prevBalance,
    uint256 newBalance,
    uint256 usedCouponAmount
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    if (msg.sender != $.adminAddress) revert InvalidAddress();
    _;
  }
  modifier onlyOperator() {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    if (msg.sender != $.operatorAddress) revert InvalidAddress();
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
    uint256 _commissionfee,
    address _clearingHouseAddress,
    address _vaultAddress
  ) public initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);
    __Pausable_init();
    __ReentrancyGuard_init();

    if (_commissionfee > MAX_COMMISSION_FEE) revert InvalidCommissionFee();

    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

    $.token = IERC20(_usdcAddress);
    $.oracle = IPyth(_oracleAddress);
    $.vault = IVault(_vaultAddress);
    $.clearingHouse = IClearingHouse(_clearingHouseAddress);
    $.adminAddress = _adminAddress;
    $.operatorAddress = _operatorAddress;
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
    if (initDate % 3600 != 0) revert InvalidInitDate(); // Ensure initDate is on the hour in seconds since Unix epoch.

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

    if (round.epoch == 0 || round.startTimestamp == 0 || round.endTimestamp == 0) revert InvalidRound();
    if (round.startPrice[0] == 0 || round.endPrice[0] == 0) revert InvalidRoundPrice();

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

  function depositCouponTo(
    address user,
    uint256 amount,
    uint256 expirationEpoch
  ) external nonReentrant {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
  
  function reclaimExpiredCouponsByChunk(uint256 startIndex, uint256 size) external nonReentrant returns (uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    
    if (startIndex >= $.couponHolders.length) revert InvalidIndex();

    uint256 endIndex = startIndex + size;
    if (endIndex > $.couponHolders.length) {
        endIndex = $.couponHolders.length;
    }

    for (uint256 i = startIndex; i < endIndex; i++) {
        _reclaimExpiredCoupons($.couponHolders[i]);
    }
    return endIndex;  // Return the next start index for subsequent calls
  }

  // @Deprecated
  function reclaimExpiredCoupons(address user) external nonReentrant {
    _reclaimExpiredCoupons(user);
  }

  function submitFilledOrders(
    FilledOrder[] calldata transactions
  ) external nonReentrant onlyOperator {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    if ($.lastFilledOrderId + 1 > transactions[0].idx) revert InvalidId();

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

  function retrieveMisplacedETH() external onlyAdmin {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    payable($.adminAddress).transfer(address(this).balance);
  }

  function retrieveMisplacedTokens(address _token) external onlyAdmin {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    if (address($.token) == _token) revert InvalidTokenAddress();
    IERC20 token = IERC20(_token);
    token.safeTransfer($.adminAddress, token.balanceOf(address(this)));
  }

  function unpause() external whenPaused onlyAdmin {
    _unpause();
  }

  function setOperator(address _operatorAddress) external onlyAdmin {
    if (_operatorAddress == address(0)) revert InvalidAddress();
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.operatorAddress = _operatorAddress;
  }

  function setOracle(address _oracle) external whenPaused onlyAdmin {
    if (_oracle == address(0)) revert InvalidAddress();
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.oracle = IPyth(_oracle);
  }

  function setCommissionfee(uint256 _commissionfee) external whenPaused onlyAdmin {
    if (_commissionfee > MAX_COMMISSION_FEE) revert InvalidCommissionFee();
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.commissionfee = _commissionfee;
  }

  function setAdmin(address _adminAddress) external onlyOwner {
    if (_adminAddress == address(0)) revert InvalidAddress();
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.adminAddress = _adminAddress;
  }

  function setToken(address _token) external onlyAdmin {
    if (_token == address(0)) revert InvalidAddress();
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    $.token = IERC20(_token); 
  }

  function setVault(address _vault) external onlyAdmin {
    if (_vault == address(0)) revert InvalidAddress();
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
    return $.clearingHouse.treasuryAmount();
  }

  function addresses() public view returns (address, address, address, address, address) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return ($.adminAddress, $.operatorAddress, address($.vault), address($.clearingHouse), address($.token));
  }

  function balances(address user) public view returns (uint256, uint256, uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    uint256 depositBalance = $.clearingHouse.userBalances(user);
    uint256 couponBalance = $.clearingHouse.couponBalanceOf(user);
    uint256 totalBalance = depositBalance + couponBalance;
    return (depositBalance, couponBalance, totalBalance);
  }

  function balanceOf(address user) public view returns (uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return $.clearingHouse.userBalances(user);
  }

  // @Deprecated
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

  // @Deprecated
  function couponHolders() public view returns (address[] memory) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return $.couponHolders;
  }

  // @Deprecated
  function getCouponHoldersPaged(uint256 offset, uint256 size) public view returns (address[] memory) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    uint256 length = $.couponHolders.length;
    
    if (offset >= length || size == 0) return new address[](0);
    
    uint256 endIndex = offset + size;
    if (endIndex > length) endIndex = length;
    
    address[] memory pagedHolders = new address[](endIndex - offset);
    for (uint256 i = offset; i < endIndex; i++) {
        pagedHolders[i - offset] = $.couponHolders[i];
    }
    return pagedHolders;
  }

  // @Deprecated
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

  // @Deprecated
  function getCouponHoldersLength() external view returns (uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return $.couponHolders.length;
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

  function _emitSettlement(
    uint256 idx,
    uint256 epoch,
    address user,
    uint256 prevBalance,
    uint256 newBalance,
    uint256 usedCouponAmount
  ) private {
    emit OrderSettled(
        user,
        idx,
        epoch,
        prevBalance,
        newBalance,
        usedCouponAmount
    );
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
    WinPosition winPosition;
    uint256 winAmount = 0;

    if (order.overPrice + order.underPrice != 100) {
        winPosition = WinPosition.Invalid;
        _emitSettlement(
            order.idx,
            order.epoch,
            order.underUser,
            $.clearingHouse.userBalances(order.underUser),
            $.clearingHouse.userBalances(order.underUser),
            0
        );
        _emitSettlement(
            order.idx,
            order.epoch,
            order.overUser,
            $.clearingHouse.userBalances(order.overUser),
            $.clearingHouse.userBalances(order.overUser),
            0
        );
    } else if (order.overUser == order.underUser) {
        winAmount = (isOverWin ? order.underPrice : isUnderWin ? order.overPrice : 0) * order.unit * PRICE_UNIT;
        winPosition = isOverWin ? WinPosition.Over : isUnderWin ? WinPosition.Under : WinPosition.Tie;
        
        uint256 fee = (winAmount * $.commissionfee) / BASE;
        uint256 remainingAmount = $.clearingHouse.useCoupon(order.overUser, fee, order.epoch);

        if ($.vault.isVault(order.overUser)) {
            _processVaultTransaction(order.idx, order.overUser, remainingAmount, false);
        }
        $.clearingHouse.subtractUserBalance(order.overUser, remainingAmount);
        $.clearingHouse.addTreasuryAmount(fee);
        collectedFee = fee;
        
        _emitSettlement(
            order.idx,
            order.epoch,
            order.overUser,
            $.clearingHouse.userBalances(order.overUser) + fee,
            $.clearingHouse.userBalances(order.overUser),
            winAmount - remainingAmount
        );
    } else if (isOverWin || isUnderWin) {
        address winner = isUnderWin ? order.underUser : order.overUser;
        address loser = isUnderWin ? order.overUser : order.underUser;
        winAmount = (isUnderWin ? order.overPrice : order.underPrice) * order.unit * PRICE_UNIT;
        winPosition = isUnderWin ? WinPosition.Under : WinPosition.Over;

        uint256 remainingAmount = $.clearingHouse.useCoupon(loser, winAmount, order.epoch);
        if ($.vault.isVault(loser)) {
            _processVaultTransaction(order.idx, loser, remainingAmount, false);
        }
        $.clearingHouse.subtractUserBalance(loser, remainingAmount);

        uint256 fee = (winAmount * $.commissionfee) / BASE;
        $.clearingHouse.addUserBalance(winner, winAmount - fee);
        $.clearingHouse.addTreasuryAmount(fee);
        if ($.vault.isVault(winner)) {
            _processVaultTransaction(order.idx, winner, (winAmount - fee), true);
        }
        collectedFee = fee;

        _emitSettlement(
            order.idx,
            order.epoch,
            loser,
            $.clearingHouse.userBalances(loser) + winAmount,
            $.clearingHouse.userBalances(loser),
            winAmount - remainingAmount
        );
        _emitSettlement(
            order.idx,
            order.epoch,
            winner, 
            $.clearingHouse.userBalances(winner) - (winAmount - fee),
            $.clearingHouse.userBalances(winner),
            0
        );
    } else {
        winPosition = WinPosition.Tie;
        _emitSettlement(
            order.idx,
            order.epoch,
            order.underUser,
            $.clearingHouse.userBalances(order.underUser),
            $.clearingHouse.userBalances(order.underUser),
            0
        );
        _emitSettlement(
            order.idx,
            order.epoch,
            order.overUser,
            $.clearingHouse.userBalances(order.overUser),
            $.clearingHouse.userBalances(order.overUser),
            0
        );
    }

    $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx,
        winPosition: winPosition,
        winAmount: winAmount,
        feeRate: $.commissionfee,
        fee: collectedFee
    });

    order.isSettled = true;
    if ($.lastSettledFilledOrderId < order.idx) {
        $.lastSettledFilledOrderId = order.idx;
    }
    return collectedFee;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  function _epochAt(uint256 timestamp) internal pure returns (uint256) {
    if (timestamp < START_TIMESTAMP) revert EpochHasNotStartedYet();
    uint256 elapsedSeconds = timestamp - START_TIMESTAMP;
    uint256 elapsedHours = elapsedSeconds / 3600;
    return elapsedHours;
  }

  function _epochTimes(uint256 epoch) internal pure returns (uint256 startTime, uint256 endTime) {
    if (epoch < 0) revert InvalidEpoch();
    startTime = START_TIMESTAMP + (epoch * 3600);
    endTime = startTime + 3600;
    return (startTime, endTime);
  }

  // @Deprecated
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

  // @Deprecated
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

  // check if the holder is migrated
  mapping(address => bool) public migratedHolders;
  uint256 public migratedHoldersCount;

  // used for migration
  function migrateCouponsToNewContract(uint256 startIndex, uint256 size) external onlyAdmin returns (uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    
    if (startIndex >= $.couponHolders.length) revert InvalidIndex();
    
    uint256 endIndex = startIndex + size;
    if (endIndex > $.couponHolders.length) {
        endIndex = $.couponHolders.length;
    }

    for (uint256 i = startIndex; i < endIndex; i++) {
        address holder = $.couponHolders[i];
        if (migratedHolders[holder]) continue;

        Coupon[] storage coupons = $.couponBalances[holder];
        
        for (uint256 j = 0; j < coupons.length; j++) {
            Coupon storage coupon = coupons[j];
            
            if (coupon.amount == coupon.usedAmount) continue;
            uint256 remainingAmount = coupon.amount - coupon.usedAmount;
            $.clearingHouse.depositCouponTo(holder, remainingAmount, coupon.expirationEpoch);
        }
        
        // check if the holder is migrated
        if (!migratedHolders[holder]) {
            migratedHolders[holder] = true;
            migratedHoldersCount++;
        }
    }
    return migratedHoldersCount;
  }

  // used for migration
  function getMigrationStatus() external view returns (
    uint256 totalHolders,
    uint256 migratedHolders,
    uint256 totalCouponAmount,
    uint256 totalUsedAmount
  ) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return (
        $.couponHolders.length,
        migratedHoldersCount,
        $.couponAmount,
        $.usedCouponAmount
    );
  }
}
