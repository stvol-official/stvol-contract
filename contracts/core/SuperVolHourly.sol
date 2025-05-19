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
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { SuperVolStorage } from "../storage/SuperVolStorage.sol";
import { Round, FilledOrder, Coupon, WithdrawalRequest, ProductRound, SettlementResult, WinPosition, PriceInfo, PriceUpdateData, ManualPriceData } from "../types/Types.sol";
import { ISuperVolErrors } from "../errors/SuperVolErrors.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract SuperVolHourly is
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
  event DebugLog(string message);
  event PriceIdAdded(uint256 indexed productId, bytes32 priceId, string symbol);

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
    address _clearingHouseAddress
  ) public initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);
    __Pausable_init();
    __ReentrancyGuard_init();

    if (_commissionfee > MAX_COMMISSION_FEE) revert InvalidCommissionFee();

    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

    $.token = IERC20(_usdcAddress);
    $.oracle = IPyth(_oracleAddress);
    $.clearingHouse = IClearingHouse(_clearingHouseAddress);
    $.adminAddress = _adminAddress;
    $.operatorAddress = _operatorAddress;
    $.commissionfee = _commissionfee;

    // _addPriceId(0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43, 0, "BTC/USD");
    // _addPriceId(0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace, 1, "ETH/USD");
    // _addPriceId(0x89b814de1eb2afd3d3b498d296fca3a873e644bafb587e84d181a01edd682853, 2, "ASTR/USD");
    // _addPriceId(0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d, 3, "SOL/USD");
  }

  function currentEpoch() external view returns (uint256) {
    return _epochAt(block.timestamp);
  }

  function executeRound(
    PriceUpdateData[] calldata updateDataWithIds,
    uint64 initDate,
    bool skipSettlement
  ) external payable whenNotPaused onlyOperator {
    if (initDate % 3600 != 0) revert InvalidInitDate(); // Ensure initDate is on the hour in seconds since Unix epoch.

    PythStructs.PriceFeed[] memory feeds = _getPythPrices(updateDataWithIds, initDate);

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
        uint256 productId = updateDataWithIds[i].productId;
        uint64 pythPrice = uint64(feeds[i].price.price);
        round.startPrice[productId] = pythPrice;
        emit StartRound(startEpoch, productId, pythPrice, initDate);
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
        uint256 productId = updateDataWithIds[i].productId;
        uint64 pythPrice = uint64(feeds[i].price.price);
        prevRound.endPrice[productId] = pythPrice;
        emit EndRound(prevEpoch, productId, pythPrice, initDate);
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

    if (round.epoch == 0 || round.startTimestamp == 0 || round.endTimestamp == 0)
      revert InvalidRound();
    if (round.startPrice[0] == 0 || round.endPrice[0] == 0) revert InvalidRoundPrice();

    FilledOrder[] storage orders = $.filledOrders[epoch];

    uint256 endIndex = orders.length;

    uint256 collectedFee = 0;

    uint256 settledCount = 0;

    for (uint i = 0; i < endIndex; i++) {
      FilledOrder storage order = orders[i];
      uint256 fee = _settleFilledOrder(round, order);
      if (fee > 0) {
        settledCount++;
      }
      if (settledCount >= size) {
        break;
      }

      collectedFee += fee;
    }

    return orders.length - endIndex;
  }

  function countUnsettledFilledOrders(uint256 epoch) external view returns (uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    FilledOrder[] storage orders = $.filledOrders[epoch];
    uint256 unsettledCount = 0;
    for (uint i = 0; i < orders.length; i++) {
      if (!orders[i].isSettled) {
        unsettledCount++;
      }
    }
    return unsettledCount;
  }

  function submitFilledOrders(
    FilledOrder[] calldata transactions
  ) external nonReentrant onlyOperator {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    if ($.lastFilledOrderId + 1 > transactions[0].idx) revert InvalidId();

    for (uint i = 0; i < transactions.length; i++) {
      FilledOrder calldata order = transactions[i];

      // Calculate required amounts
      uint256 overAmount = order.overPrice * order.unit * PRICE_UNIT;
      uint256 underAmount = order.underPrice * order.unit * PRICE_UNIT;

      // Lock in escrow for both parties
      $.clearingHouse.lockInEscrow(
        address(this),
        order.overUser,
        overAmount,
        order.epoch,
        order.idx,
        true
      );
      $.clearingHouse.lockInEscrow(
        address(this),
        order.underUser,
        underAmount,
        order.epoch,
        order.idx,
        true
      );

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
      if (order.overUser != order.underUser) {
        $.clearingHouse.releaseFromEscrow(
          address(this),
          order.overUser,
          order.epoch,
          order.idx,
          order.overPrice * order.unit * PRICE_UNIT,
          0
        );
        $.clearingHouse.releaseFromEscrow(
          address(this),
          order.underUser,
          order.epoch,
          order.idx,
          order.underPrice * order.unit * PRICE_UNIT,
          0
        );
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
      } else {
        $.clearingHouse.releaseFromEscrow(
          address(this),
          order.overUser,
          order.epoch,
          order.idx,
          100 * order.unit * PRICE_UNIT,
          0
        );
      }
    } else if (order.overUser == order.underUser) {
      winAmount =
        (
          isOverWin
            ? order.underPrice
            : isUnderWin
              ? order.overPrice
              : 0
        ) *
        order.unit *
        PRICE_UNIT;
      winPosition = isOverWin
        ? WinPosition.Over
        : isUnderWin
          ? WinPosition.Under
          : WinPosition.Tie;

      uint256 fee = (winAmount * $.commissionfee) / BASE;
      uint256 usedCoupon = $.clearingHouse.escrowCoupons(
        address(this),
        order.epoch,
        order.overUser,
        order.idx
      );

      // Return winner's original escrow (no fee)
      $.clearingHouse.releaseFromEscrow(
        address(this),
        order.overUser,
        order.epoch,
        order.idx,
        100 * order.unit * PRICE_UNIT,
        fee
      );

      // Emit settlement event
      _emitSettlement(
        order.idx,
        order.epoch,
        order.overUser,
        $.clearingHouse.userBalances(order.overUser) + fee,
        $.clearingHouse.userBalances(order.overUser),
        usedCoupon
      );
      $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx,
        winPosition: winPosition,
        winAmount: winAmount,
        feeRate: $.commissionfee,
        fee: fee
      });
    } else if (isOverWin) {
      winPosition = WinPosition.Over;
      collectedFee += _processWin(order.overUser, order.underUser, order, winPosition);
    } else if (isUnderWin) {
      winPosition = WinPosition.Under;
      collectedFee += _processWin(order.underUser, order.overUser, order, winPosition);
    } else {
      if (order.overUser != order.underUser) {
        // Tie
        $.clearingHouse.releaseFromEscrow(
          address(this),
          order.overUser,
          order.epoch,
          order.idx,
          order.overPrice * order.unit * PRICE_UNIT,
          0
        );
        $.clearingHouse.releaseFromEscrow(
          address(this),
          order.underUser,
          order.epoch,
          order.idx,
          order.underPrice * order.unit * PRICE_UNIT,
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
        _emitSettlement(
          order.idx,
          order.epoch,
          order.underUser,
          $.clearingHouse.userBalances(order.underUser),
          $.clearingHouse.userBalances(order.underUser),
          0
        );
      } else {
        $.clearingHouse.releaseFromEscrow(
          address(this),
          order.overUser,
          order.epoch,
          order.idx,
          100 * order.unit * PRICE_UNIT,
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
        winPosition: WinPosition.Tie,
        winAmount: 0,
        feeRate: $.commissionfee,
        fee: 0
      });
    }

    order.isSettled = true;
    return collectedFee;
  }

  function _processWin(
    address winner,
    address loser,
    FilledOrder storage order,
    WinPosition winPosition
  ) internal returns (uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

    uint256 winnerAmount = order.overUser == winner
      ? order.overPrice * order.unit * PRICE_UNIT
      : order.underPrice * order.unit * PRICE_UNIT;

    uint256 loserAmount = order.overUser == loser
      ? order.overPrice * order.unit * PRICE_UNIT
      : order.underPrice * order.unit * PRICE_UNIT;
    uint256 fee = (loserAmount * $.commissionfee) / BASE;
    uint256 usedCoupon = $.clearingHouse.escrowCoupons(
      address(this),
      order.epoch,
      loser,
      order.idx
    );

    // Transfer loser's escrow to winner (with fee handling)
    $.clearingHouse.settleEscrowWithFee(
      address(this),
      loser,
      winner,
      order.epoch,
      loserAmount,
      order.idx,
      fee
    );
    // Return winner's original escrow (no fee)
    $.clearingHouse.releaseFromEscrow(
      address(this),
      winner,
      order.epoch,
      order.idx,
      winnerAmount,
      0
    );

    _emitSettlement(
      order.idx,
      order.epoch,
      loser,
      $.clearingHouse.userBalances(loser) + loserAmount,
      $.clearingHouse.userBalances(loser),
      usedCoupon
    );
    _emitSettlement(
      order.idx,
      order.epoch,
      winner,
      $.clearingHouse.userBalances(winner) - (loserAmount - fee),
      $.clearingHouse.userBalances(winner),
      0
    );
    $.settlementResults[order.idx] = SettlementResult({
      idx: order.idx,
      winPosition: winPosition,
      winAmount: loserAmount,
      feeRate: $.commissionfee,
      fee: fee
    });
    return fee;
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

  function addPriceId(
    bytes32 _priceId,
    uint256 _productId,
    string calldata _symbol
  ) external onlyOperator {
    _addPriceId(_priceId, _productId, _symbol);
  }

  // function initializeDefaultPriceIds() external onlyOperator {
  //   SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

  //   if (
  //     $.priceIdToProductId[0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43] ==
  //     0 &&
  //     $.priceInfos[0].priceId != 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
  //   ) {
  //     _addPriceId(0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43, 0, "BTC/USD");
  //     _addPriceId(0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace, 1, "ETH/USD");
  //     _addPriceId(0x89b814de1eb2afd3d3b498d296fca3a873e644bafb587e84d181a01edd682853, 2, "ASTR/USD");
  //     _addPriceId(0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d, 3, "SOL/USD");
  //   }
  // }

  function setPriceInfo(PriceInfo calldata priceInfo) external onlyOperator {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

    if (priceInfo.priceId == bytes32(0)) revert InvalidPriceId();
    if (bytes(priceInfo.symbol).length == 0) revert InvalidSymbol();

    uint256 existingProductId = $.priceIdToProductId[priceInfo.priceId];
    bytes32 oldPriceId = $.priceInfos[priceInfo.productId].priceId;

    if (existingProductId != priceInfo.productId) {
      if (existingProductId != 0 || $.priceInfos[0].priceId == priceInfo.priceId) {
        revert PriceIdAlreadyExists();
      }
    }

    if (oldPriceId != bytes32(0)) {
      delete $.priceIdToProductId[oldPriceId];
    }

    $.priceInfos[priceInfo.productId] = priceInfo;
    $.priceIdToProductId[priceInfo.priceId] = priceInfo.productId;

    emit PriceIdAdded(priceInfo.productId, priceInfo.priceId, priceInfo.symbol);
  }

  /* public views */
  function commissionfee() public view returns (uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return $.commissionfee;
  }

  function addresses() public view returns (address, address, address, address) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    return ($.adminAddress, $.operatorAddress, address($.clearingHouse), address($.token));
  }

  function balances(address user) public view returns (uint256, uint256, uint256) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    uint256 depositBalance = $.clearingHouse.userBalances(user);
    uint256 couponBalance = $.clearingHouse.couponBalanceOf(user);
    uint256 totalBalance = depositBalance + couponBalance;
    return (depositBalance, couponBalance, totalBalance);
  }

  // function balanceOf(address user) public view returns (uint256) {
  //   SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
  //   return $.clearingHouse.userBalances(user);
  // }

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

  function priceInfos() external view returns (PriceInfo[] memory) {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

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

  function _settleFilledOrders(Round storage round) internal {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

    if (round.epoch == 0 || round.startTimestamp == 0 || round.endTimestamp == 0) return;

    uint256 collectedFee = 0;
    FilledOrder[] storage orders = $.filledOrders[round.epoch];
    for (uint i = 0; i < orders.length; i++) {
      FilledOrder storage order = orders[i];
      collectedFee += _settleFilledOrder(round, order);
    }

    emit RoundSettled(round.epoch, orders.length, collectedFee);
  }

  function fillSettlementResult(uint256[] calldata epochList) external {
    // temporary function to fill settlement results
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    for (uint a = 0; a < epochList.length; a++) {
      uint256 epoch = epochList[a];
      FilledOrder[] storage orders = $.filledOrders[epoch];
      Round storage round = $.rounds[epoch];
      for (uint i = 0; i < orders.length; i++) {
        FilledOrder storage order = orders[i];
        _fillSettlementResult(round, order);
      }
    }
  }

  function _fillSettlementResult(Round storage round, FilledOrder storage order) internal {
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
        isOverWin
          ? order.underPrice
          : isUnderWin
            ? order.overPrice
            : 0
      ) *
        order.unit *
        PRICE_UNIT;
      uint256 fee = (loosePositionAmount * $.commissionfee) / BASE;

      $.settlementResults[order.idx] = SettlementResult({
        idx: order.idx,
        winPosition: isOverWin
          ? WinPosition.Over
          : isUnderWin
            ? WinPosition.Under
            : WinPosition.Tie,
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
    emit OrderSettled(user, idx, epoch, prevBalance, newBalance, usedCouponAmount);
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

  // function transferRemainingTokens(address to) external onlyAdmin {
  //   if (to == address(0)) revert InvalidAddress();

  //   SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
  //   uint256 balance = $.token.balanceOf(address(this));
  //   $.token.safeTransfer(to, balance);
  // }

  function setManualRoundEndPrices(
    ManualPriceData[] calldata manualPrices,
    uint64 initDate,
    bool skipSettlement
  ) external onlyOperator {
    if (initDate % 3600 != 0) revert InvalidInitDate();

    uint256 problemEpoch = _epochAt(initDate);
    uint256 currentEpochNumber = _epochAt(block.timestamp);

    if (problemEpoch >= currentEpochNumber) revert InvalidEpoch();

    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();

    // end problem round
    Round storage problemRound = $.rounds[problemEpoch];
    Round storage nextRound = $.rounds[problemEpoch + 1];
    if (!nextRound.isStarted) {
      nextRound.epoch = problemEpoch + 1;
      nextRound.startTimestamp = initDate + INTERVAL_SECONDS;
      nextRound.endTimestamp = nextRound.startTimestamp + INTERVAL_SECONDS;
      nextRound.isStarted = true;
      nextRound.isSettled = false;
    }

    if (
      problemRound.epoch == problemEpoch &&
      problemRound.startTimestamp > 0 &&
      problemRound.isStarted
    ) {
      problemRound.endTimestamp = initDate + INTERVAL_SECONDS;

      for (uint i = 0; i < manualPrices.length; i++) {
        ManualPriceData calldata priceData = manualPrices[i];
        problemRound.endPrice[priceData.productId] = priceData.price;
        emit DebugLog(
          string.concat(
            "nextRound | ",
            "Epoch: ",
            Strings.toString(nextRound.epoch),
            " | ",
            "startPrice[",
            Strings.toString(nextRound.startPrice[priceData.productId]),
            "]: ",
            "endPrice[",
            Strings.toString(nextRound.endPrice[priceData.productId]),
            "]"
          )
        );
        if (
          nextRound.epoch <= currentEpochNumber && nextRound.startPrice[priceData.productId] == 0
        ) {
          nextRound.startPrice[priceData.productId] = priceData.price;
        }

        emit EndRound(problemEpoch, priceData.productId, priceData.price, initDate);
        emit DebugLog(
          string.concat(
            "Manual Price Update | ",
            "Epoch: ",
            Strings.toString(problemEpoch),
            " | ",
            "Product[",
            Strings.toString(priceData.productId),
            "]: ",
            Strings.toString(priceData.price)
          )
        );
      }
      problemRound.isSettled = true;
    }

    if (!skipSettlement) {
      _settleFilledOrders(problemRound);
    }
  }

  function releaseEpochEscrow(uint256 epoch) external onlyOperator {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
    Round storage round = $.rounds[epoch];
    FilledOrder[] storage orders = $.filledOrders[epoch];

    for (uint i = 0; i < orders.length; i++) {
      FilledOrder memory order = orders[i];
      if (!order.isSettled) {
        if (order.overUser == order.underUser) {
          $.clearingHouse.releaseFromEscrow(
            address(this),
            order.overUser,
            order.epoch,
            order.idx,
            100 * order.unit * PRICE_UNIT,
            0
          );
        } else {
          $.clearingHouse.releaseFromEscrow(
            address(this),
            order.overUser,
            order.epoch,
            order.idx,
            order.overPrice * order.unit * PRICE_UNIT,
            0
          );
          $.clearingHouse.releaseFromEscrow(
            address(this),
            order.underUser,
            order.epoch,
            order.idx,
            order.underPrice * order.unit * PRICE_UNIT,
            0
          );
          order.isSettled = true;

          $.settlementResults[order.idx] = SettlementResult({
            idx: order.idx,
            winPosition: WinPosition.Invalid,
            winAmount: 0,
            feeRate: 0,
            fee: 0
          });
        }
      }
    }
    round.isSettled = true;
  }

  function _addPriceId(bytes32 _priceId, uint256 _productId, string memory _symbol) internal {
    SuperVolStorage.Layout storage $ = SuperVolStorage.layout();
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
