// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "./utils/AutoIncrementing.sol";
import "./libraries/IntraOrderSet.sol";

/**
 * E01: Not admin
 * E02: Not operator
 * E03: Contract not allowed
 * E04: Commission fee too high
 * E07: Participate is too early/late
 * E08: Round not participable
 * E09: Participate amount must be greater than minParticipateAmount
 * E10: Round has not started
 * E11: Round has not ended
 * E12: Not eligible for claim
 * E13: Not eligible for refund
 * E14: Can only run after genesisOpenRound and genesisStartRound is triggered
 * E15: Pyth Oracle non increasing publishTimes
 * E16: Can only run after genesisOpenRound is triggered
 * E17: Can only open round after round n-2 has ended
 * E18: Can only open new round after round n-2 closeTimestamp
 * E19: Can only open new round after init date
 * E20: Participate payout must be greater than zero
 * E21: Can only cancel order after round has started
 * E22: Can only cancel order before startTimestamp
 * E23: Can only lock round after round has started
 * E24: Can only start round after startTimestamp
 * E25: Can only start round within bufferSeconds
 * E26: Can only end round after round has locked
 * E27: Can only end round after closeTimestamp
 * E28: Can only end round within bufferSeconds
 * E29: Rewards calculated
 * E30: bufferSeconds must be inferior to intervalSeconds
 * E31: Cannot be zero address
 * E32: Can only run genesisStartRound once
 * E33: Pyth Oracle non increasing publishTimes
 * E35: Exceed limit order size
 */
contract StVolIntra is Ownable, Pausable, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using AutoIncrementing for AutoIncrementing.Counter;
  using IntraOrderSet for IntraOrderSet.Data;

  IERC20 public immutable token; // Prediction token

  IPyth public oracle;

  bool public genesisStartOnce = false;

  bytes32 public priceId; // address of the pyth price
  address public adminAddress; // address of the admin
  address public operatorAddress; // address of the operator
  address public operatorVaultAddress; // address of the operator vault

  uint256 public bufferSeconds; // number of seconds for valid execution of a participate round
  uint256 public intervalSeconds; // interval in seconds between two participate rounds

  uint8[] public availableOptionStrikes; // available option markets. handled by Admin

  uint256 public commissionfee; // commission rate (e.g. 200 = 2%, 150 = 1.50%)
  uint256 public treasuryAmount; // treasury amount that was not claimed
  uint256 public participantRate; // participant distribute rate (e.g. 200 = 2%, 150 = 1.50%)
  uint256 public currentEpoch; // current epoch for round
  uint256 public constant BASE = 10000; // 100%
  uint256 public constant MAX_COMMISSION_FEE = 200; // 2%
  // uint256 public constant DEFAULT_MIN_PARTICIPATE_AMOUNT = 1000000; // 1 USDC (decimal: 6)
  uint256 public constant DEFAULT_INTERVAL_SECONDS = 3600; // 60 * 60 (1 hour)
  uint256 public constant DEFAULT_BUFFER_SECONDS = 600; // 10 * 60 (10min)

  mapping(uint256 => Round) public rounds; // (key: epoch)
  mapping(uint256 => AutoIncrementing.Counter) private counters; // (key: epoch)

  enum Position {
    Over,
    Under
  }

  enum OrderType {
    Market,
    Limit
  }

  struct Order {
    uint256 placedIdx;
    uint256 epoch;
    uint8 strike;
    Position position;
    uint256 price;
    uint256 unit;
  }

  struct Round {
    uint256 epoch;
    uint256 startTimestamp;
    uint256 closeTimestamp;
    uint256 startPrice;
    uint256 closePrice;
    uint256 startOracleId;
    uint256 closeOracleId;
    bool oracleCalled;
    uint8[] availableOptions;
    mapping(uint8 => Option) options; // Binary Option Market (key: strike)
  }

  struct Option {
    uint8 strike; // 97, 99, 100, 101, 103
    uint256 overPrice;
    uint256 underPrice;

    IntraOrderSet.Data overOrders;
    IntraOrderSet.Data underOrders;

    AutoIncrementing.Counter filledOrderCounter;
    mapping(uint256 => FilledOrder) filledOrders;
    mapping(address => uint256[]) userFilledOrder;
  }

  struct FilledOrder {
    uint256 idx;
    uint256 epoch; 
    uint8 strike;
    address overUser;
    address underUser;
    uint256 overPrice;
    uint256 underPrice; // over_price + under_price = 100 * decimal
    uint256 unit;
    bool isOverClaimed; // default: false
    bool isUnderClaimed; // default: false
  }

  event PlaceOrder(
    address indexed sender,
    uint256 indexed epoch,
    uint256 indexed idx,
    uint8 strike,
    Position position,
    uint256 price,
    uint256 unit,
    uint256 filledUnit,
    uint256 refundAmount,
    OrderType orderType
  );

  event CancelLimitOrder(
    address indexed sender,
    uint256 indexed epoch,
    uint256 indexed idx,
    uint8 strike,
    Position position,
    uint256 price,
    uint256 unit
  );

  event OrderFilled(
    uint256 indexed epoch,
    uint256 indexed idx,
    uint8 strike,
    uint256 placedIdx,
    Position position,
    address overUser,
    address underUser,
    uint256 overPrice,
    uint256 underPrice,
    uint256 unit,
    OrderType orderType
  );
  
  event Claim(
    address indexed sender,
    uint256 indexed epoch,
    uint8 indexed strike,
    uint256 amount
  );

  event Refund(
    address indexed sender,
    uint256 indexed epoch,
    uint8 indexed strike,
    uint256 amount,
    bool byAdmin
  );

  event StartRound(
    uint256 indexed epoch, 
    uint256 initDate,
    uint256 price,
    uint8[] availableOptionStrikes
  );

  event OptionCreated(
    uint256 indexed epoch, 
    uint8 indexed strike,
    uint256 strikePrice
  );

  event EndRound(
    uint256 indexed epoch,
    uint256 price
  );

  event CommissionCalculated(
    uint256 indexed epoch,
    uint8 indexed strike,
    uint256 treasuryAmount
  );

  modifier onlyAdmin() {
    require(msg.sender == adminAddress, "E01");
    _;
  }
  modifier onlyOperator() {
    require(msg.sender == operatorAddress, "E02");
    _;
  }

  constructor(
    address _token,
    address _oracleAddress,
    address _adminAddress,
    address _operatorAddress,
    address _operatorVaultAddress,
    uint256 _commissionfee,
    bytes32 _priceId
  ) {
    require(_commissionfee <= MAX_COMMISSION_FEE, "E04");

    token = IERC20(_token);
    oracle = IPyth(_oracleAddress);
    adminAddress = _adminAddress;
    operatorAddress = _operatorAddress;
    operatorVaultAddress = _operatorVaultAddress;
    commissionfee = _commissionfee;
    priceId = _priceId;

    intervalSeconds = DEFAULT_INTERVAL_SECONDS;
    bufferSeconds = DEFAULT_BUFFER_SECONDS;

    // init available option makets
    availableOptionStrikes.push(98);
    availableOptionStrikes.push(99);
    availableOptionStrikes.push(100);
    availableOptionStrikes.push(101);
    availableOptionStrikes.push(102);
  }

  function placeLimitOrder(
    uint256 epoch,
    uint8 strike,
    Position position,
    uint256 price,
    uint256 unit,
    uint256 prevIdx
  ) external whenNotPaused nonReentrant {
    require(epoch == currentEpoch, "E07");
    require(rounds[epoch].startTimestamp != 0 && block.timestamp < rounds[epoch].closeTimestamp, "E08");
    require(price >= 1000000 && price <= 99000000, "The price must be between 1 and 99.");
    require(price % 1000000 == 0, "The price must be an integer.");
    require(unit > 0, "The unit must be greater than 0.");

    uint256 transferedToken = price * unit;
    token.safeTransferFrom(msg.sender, address(this), transferedToken);
    
    uint256 idx = counters[epoch].nextId();

    uint256 usedToken;
    uint256 leftUnit;
    (usedToken, leftUnit) = _matchLimitOrders(Order(idx, epoch, strike, position, price, unit));
    
    if (leftUnit > 0) {
      Option storage option = rounds[epoch].options[strike];
      IntraOrderSet.Data storage orders = position == Position.Over ? option.overOrders : option.underOrders;
      orders.insert(
        IntraOrderSet.IntraOrder( // unfilled order
          idx,
          msg.sender,
          price,
          leftUnit
        ),
        prevIdx
      );

      usedToken += price * leftUnit;
    }

    if (transferedToken > usedToken) {
      token.safeTransfer(msg.sender, transferedToken - usedToken);
    }
    
    emit PlaceOrder(msg.sender, epoch, idx, strike, position, price, unit, unit - leftUnit, transferedToken - usedToken, OrderType.Limit);
  }

  function cancelLimitOrder(
    uint256 epoch,
    uint8 strike,
    Position position,
    uint256 idx
  ) external whenNotPaused nonReentrant {
    require(epoch == currentEpoch, "E07");
    require(rounds[epoch].startTimestamp != 0 && block.timestamp < rounds[epoch].closeTimestamp, "E08");
    require(idx > 0, "The idx must be greater than 0.");

    Option storage option = rounds[epoch].options[strike];
    IntraOrderSet.Data storage orders = position == Position.Over ? option.overOrders : option.underOrders;
    IntraOrderSet.IntraOrder storage order = orders.orderMap[idx];
    require(order.user == msg.sender, "E03");

    uint256 refundAmount = order.price * order.unit;
    orders.remove(idx);

    token.safeTransfer(msg.sender, refundAmount);

    emit CancelLimitOrder(msg.sender, epoch, idx, strike, position, order.price, order.unit);
  }

  function placeMarketOrder(
    uint256 epoch,
    uint8 strike,
    Position position,
    uint256 price, // expected average price
    uint256 unit // max unit of the order
  ) external whenNotPaused nonReentrant {
    require(epoch == currentEpoch, "E07");
    require(rounds[epoch].startTimestamp != 0 && block.timestamp < rounds[epoch].closeTimestamp, "E08");
    require(price >= 1000000 && price <= 99000000, "The price must be between 1 and 99.");
    require(unit > 0, "The unit must be greater than 0.");

    uint256 transferedToken = price * unit;
    token.safeTransferFrom(msg.sender, address(this), transferedToken);

    uint256 idx = counters[epoch].nextId();

    uint256 totalUnit;
    uint256 totalAmount;
    (totalUnit, totalAmount) = _matchMarketOrders(Order(idx, epoch, strike, position, price, unit));

    if (transferedToken > totalAmount) {
      token.safeTransfer(msg.sender, transferedToken - totalAmount);
    }

    emit PlaceOrder(msg.sender, epoch, idx, strike, position, price, unit, totalUnit, transferedToken - totalAmount, OrderType.Market);
  }

  function getTotalMarketPrice(
    uint256 epoch,
    uint8 strike,
    Position position,
    uint256 unit
  ) public view returns (uint256, uint256) {
    require(epoch == currentEpoch, "E07");
    require(rounds[epoch].startTimestamp != 0 && block.timestamp < rounds[epoch].closeTimestamp, "E08");

    Option storage option = rounds[epoch].options[strike];
    IntraOrderSet.Data storage counterOrders = position == Position.Over ? option.underOrders : option.overOrders;

    uint256 totalUnit;
    uint256 totalPrice;

    uint256 counterIdx = counterOrders.first();

    while (totalUnit < unit) {
      if (counterIdx == IntraOrderSet.QUEUE_START || counterIdx == IntraOrderSet.QUEUE_END) {
        // counter order is empty
        break;
      }

      IntraOrderSet.IntraOrder storage counterOrder = counterOrders.orderMap[counterIdx];
      uint256 myPrice = 100000000 - counterOrder.price;
      uint256 txUnit = (unit - totalUnit) < counterOrder.unit ? unit - totalUnit : counterOrder.unit; // min

      totalPrice += myPrice * txUnit;
      totalUnit += txUnit;

      if (counterOrder.unit - txUnit == 0) {
        // check next order
        counterIdx = counterOrders.next(counterIdx);
      } else {
        break; // finish
      }
    }

    return (totalUnit, totalPrice);
  }


  function refundable(
    uint256 epoch,
    uint8 strike,
    address user
  ) public view returns (bool) {
    Round storage round = rounds[epoch];
    if (block.timestamp <= round.closeTimestamp + bufferSeconds) return false;
    
    Option storage option = round.options[strike];

    if (_refundable(option.overOrders, user)) return true; // check over orders
    if (_refundable(option.underOrders, user)) return true; // check under orders

    return false;
  }

  function refund(
    uint256 epoch,
    uint8 strike
  ) external nonReentrant {
    _refund(epoch, strike, msg.sender, false);
  }

  function refundByAdmin(
    uint256 epoch,
    uint8 strike,
    address _user
  ) external nonReentrant whenPaused onlyAdmin { 
    _refund(epoch, strike, _user, true);
  }

  function claimable(
    uint256 epoch,
    uint8 strike,
    address user
  ) public view returns (bool) {
    Round storage round = rounds[epoch];
    if (!round.oracleCalled) return false;

    Option storage option = round.options[strike];
    uint256[] memory myFilledOrders = option.userFilledOrder[user];
    if (myFilledOrders.length == 0) return false;

    uint256 strikePrice = (round.startPrice * uint256(option.strike)) / 100;

    bool isTie = strikePrice == round.closePrice;
    bool isOverWin = strikePrice < round.closePrice;
    bool isUnderWin = strikePrice > round.closePrice;

    for (uint i = 0; i < myFilledOrders.length; i++) {
      FilledOrder memory filledOrder = option.filledOrders[myFilledOrders[i]];
      if (filledOrder.overUser == user) {
        // my position was over
        if (filledOrder.isOverClaimed) continue;
        if (isTie || isOverWin) return true;
      } else if (filledOrder.underUser == user) {
        // my position was under
        if (filledOrder.isUnderClaimed) continue;
        if (isTie || isUnderWin) return true;
      }
    }
    return false;
  }

  function claim(uint256 epoch, uint8 strike) external nonReentrant {
    require(rounds[epoch].closeTimestamp != 0, "E11");
    require(block.timestamp > rounds[epoch].closeTimestamp, "E11");

    uint256 reward = _claimReward(epoch, strike, msg.sender);

    if (reward > 0) {
      token.safeTransfer(msg.sender, reward);
    }
  }

  function claimAll() external nonReentrant {
    _trasferReward(msg.sender);
  }

  function redeemAll(address _user) external whenPaused onlyAdmin {
    _trasferReward(_user);
  }

  function executeRound(
    bytes[] calldata priceUpdateData,
    uint64 initDate,
    bool isFixed
  ) external payable whenNotPaused onlyOperator {
    require(genesisStartOnce, "E14");

    (int64 pythPrice, uint publishTime) = _getPythPrice(
      priceUpdateData,
      initDate,
      isFixed
    );

    require(
      publishTime >= initDate - bufferSeconds &&
        publishTime <= initDate + bufferSeconds,
      "E15"
    );

    // end current round
    _safeEndRound(currentEpoch, uint64(pythPrice));

    Round storage endedRound = rounds[currentEpoch];
    for (uint i=0; i < endedRound.availableOptions.length; i++) {
        _calculateCommission(currentEpoch, endedRound.availableOptions[i]);
    }

    // increase currentEpoch and start next round
    currentEpoch = currentEpoch + 1;

    _startRound(currentEpoch, initDate, uint64(pythPrice));
  }



  function genesisStartRound(
    bytes[] calldata priceUpdateData,
    uint64 initDate,
    bool isFixed
  ) external payable whenNotPaused onlyOperator {    
    require(!genesisStartOnce, "E32");

    currentEpoch = currentEpoch + 1;

    (int64 pythPrice, uint publishTime) = _getPythPrice(
      priceUpdateData,
      initDate,
      isFixed
    );

    require(
      publishTime >= initDate - bufferSeconds &&
        publishTime <= initDate + bufferSeconds,
      "E15"
    );

    _startRound(currentEpoch, initDate, uint64(pythPrice));

    genesisStartOnce = true;
  }

  function pause() external whenNotPaused onlyAdmin {
    _pause();
  }

  function claimTreasury() external nonReentrant onlyAdmin {
    uint256 currentTreasuryAmount = treasuryAmount;
    treasuryAmount = 0;
    token.safeTransfer(operatorVaultAddress, currentTreasuryAmount);
  }

  function withdraw(uint amount) external onlyAdmin {
    require(amount <= address(this).balance);
    payable(adminAddress).transfer(address(this).balance);
  }

  function unpause() external whenPaused onlyAdmin {
    genesisStartOnce = false;
    _unpause();
  }

  function setBufferAndIntervalSeconds(
    uint256 _bufferSeconds,
    uint256 _intervalSeconds
  ) external whenPaused onlyAdmin {
    require(_bufferSeconds < _intervalSeconds, "E30");
    bufferSeconds = _bufferSeconds;
    intervalSeconds = _intervalSeconds;
  }

  function setOperator(address _operatorAddress) external onlyAdmin {
    require(_operatorAddress != address(0), "E31");
    operatorAddress = _operatorAddress;
  }

  function setOperatorVault(address _operatorVaultAddress) external onlyAdmin {
    require(_operatorVaultAddress != address(0), "E31");
    operatorVaultAddress = _operatorVaultAddress;
  }

  function setOracle(address _oracle) external whenPaused onlyAdmin {
    require(_oracle != address(0), "E31");
    oracle = IPyth(_oracle);
  }

  function setCommissionfee(
    uint256 _commissionfee
  ) external whenPaused onlyAdmin {
    require(_commissionfee <= MAX_COMMISSION_FEE, "E04");
    commissionfee = _commissionfee;
  }

  function addOptionStrike(uint8 strike) external onlyAdmin {
    int idx = -1;
    for (uint i = 0; i < availableOptionStrikes.length; i++) {
        if (strike == availableOptionStrikes[i]) {
            idx = int(i);
            break;
        }
    }
    require(idx == -1, "Already Exists");
    availableOptionStrikes.push(strike);
  }

  function removeOptionStrike(uint8 strike) external onlyAdmin {
    int idx = -1;
    for (uint i = 0; i < availableOptionStrikes.length; i++) {
        if (strike == availableOptionStrikes[i]) {
            idx = int(i);
            break;
        }
    }
    require(idx != -1, "Not Exists");
    availableOptionStrikes[uint(idx)] = availableOptionStrikes[availableOptionStrikes.length - 1];
    availableOptionStrikes.pop();
  }


  function setAdmin(address _adminAddress) external onlyOwner {
    require(_adminAddress != address(0), "E31");
    adminAddress = _adminAddress;
  }


  /* internal functions */
  function _matchLimitOrders(
    Order memory order
  ) internal returns (uint256, uint256) {
    Option storage option = rounds[order.epoch].options[order.strike];
    IntraOrderSet.Data storage counterOrders = order.position == Position.Over ? option.underOrders : option.overOrders;
    uint256 usedToken;
    uint256 leftUnit = order.unit;
    

    while (leftUnit > 0) {
      uint256 counterIdx = counterOrders.first();
      if (counterIdx == IntraOrderSet.QUEUE_START || counterIdx == IntraOrderSet.QUEUE_END) {
        // counter order is empty
        break;
      }

      IntraOrderSet.IntraOrder storage counterOrder = counterOrders.orderMap[counterIdx];
      if (counterOrder.price + order.price < 100000000) { // 100 usdc
        // no more matched counter orders
        break;
      }

      uint256 myPrice = 100000000 - counterOrder.price;
      uint256 txUnit = leftUnit < counterOrder.unit ? leftUnit : counterOrder.unit; // min

      _createFilledOrder(option, order, counterOrder, myPrice, txUnit, OrderType.Limit);

      leftUnit = leftUnit - txUnit;
      usedToken += myPrice * txUnit;
      

      if (counterOrder.unit - txUnit == 0) { // remove
        counterOrders.remove(counterIdx);
      } else { // update
        counterOrder.unit = counterOrder.unit - txUnit;
      }
    }
    return (usedToken, leftUnit); // used token and unmatched unit
  }

  function _matchMarketOrders(
    Order memory order
  ) internal returns (uint256, uint256) {
    Option storage option = rounds[order.epoch].options[order.strike];
    IntraOrderSet.Data storage counterOrders = order.position == Position.Over ? option.underOrders : option.overOrders;

    uint256 totalUnit;
    uint256 totalAmount;

    while (totalUnit < order.unit) {
      uint256 counterIdx = counterOrders.first();
      if (counterIdx == IntraOrderSet.QUEUE_START || counterIdx == IntraOrderSet.QUEUE_END) {
        // counter order is empty
        break;
      }

      IntraOrderSet.IntraOrder storage counterOrder = counterOrders.orderMap[counterIdx];
      uint256 myPrice = 100000000 - counterOrder.price;
      uint256 txUnit = (order.unit - totalUnit) < counterOrder.unit ? order.unit - totalUnit : counterOrder.unit; // min

      txUnit = _findExactUnit(totalAmount, totalUnit, myPrice, txUnit, order.price);

      if (txUnit == 0) {
        // no more matching
        break;
      }

      _createFilledOrder(option, order, counterOrder, myPrice, txUnit, OrderType.Market);

      totalAmount += myPrice * txUnit;
      totalUnit += txUnit;

      if (counterOrder.unit - txUnit == 0) { // remove
        counterOrders.remove(counterIdx);
      } else { // update
        counterOrder.unit = counterOrder.unit - txUnit;
        break; // no more matching
      }
    }
    return (totalUnit, totalAmount);
  }

  function _createFilledOrder(Option storage option, Order memory order,
    IntraOrderSet.IntraOrder storage counterOrder, 
    uint256 myPrice, uint256 txUnit, OrderType orderType
    ) internal {
   
      uint256 txId = option.filledOrderCounter.nextId();
      option.filledOrders[txId] = FilledOrder(
        txId,
        order.epoch,
        order.strike,
        order.position == Position.Over ? msg.sender : counterOrder.user,
        order.position == Position.Over ? counterOrder.user : msg.sender,
        order.position == Position.Over ? myPrice : counterOrder.price,
        order.position == Position.Over ? counterOrder.price : myPrice,
        txUnit,
        false,
        false
      );
      option.userFilledOrder[msg.sender].push(txId);
      option.userFilledOrder[counterOrder.user].push(txId);

      emit OrderFilled(
        order.epoch,
        txId,
        order.strike,
        order.placedIdx,
        order.position,
        order.position == Position.Over ? msg.sender : counterOrder.user,
        order.position == Position.Over ? counterOrder.user : msg.sender,
        order.position == Position.Over ? myPrice : counterOrder.price,
        order.position == Position.Over ? counterOrder.price : myPrice,
        txUnit,
        orderType
      );
  }
  
  function _findExactUnit(uint256 totalPrice, uint256 totalUnit, uint256 myPrice, uint256 txUnit, uint256 price) internal pure returns (uint256) {
      uint256 newTotalPrice = totalPrice + (myPrice * txUnit);
      uint256 newTotalUnits = totalUnit + txUnit;

      if (newTotalPrice / newTotalUnits <= price) {
        // all txUnit matched!
      } else {
        // check one by one
        uint256 newTxUnit;
        for (uint i=1; i < txUnit; i++) {
          newTotalPrice = totalPrice + (myPrice * i);
          newTotalUnits = totalUnit + i;
          if (newTotalPrice / newTotalUnits <= price) {
            newTxUnit = i; // matched!
          } else {
            break;
          }
        }
        txUnit = newTxUnit;
      }
      return txUnit;
  }
  
  function _getPythPrice(
    bytes[] memory priceUpdateData,
    uint64 fixedTimestamp,
    bool isFixed
  ) internal returns (int64, uint) {
    bytes32[] memory pythPair = new bytes32[](1);
    pythPair[0] = priceId;

    uint fee = oracle.getUpdateFee(priceUpdateData);
    if (isFixed) {
      PythStructs.PriceFeed memory pythPrice = oracle.parsePriceFeedUpdates{
        value: fee
      }(
        priceUpdateData,
        pythPair,
        fixedTimestamp,
        fixedTimestamp + uint64(bufferSeconds)
      )[0];
      return (pythPrice.price.price, fixedTimestamp);
    } else {
      oracle.updatePriceFeeds{ value: fee }(priceUpdateData);
      return (
        oracle.getPrice(priceId).price,
        oracle.getPrice(priceId).publishTime
      );
    }
  }

  function _refundable(IntraOrderSet.Data storage orders, address user) internal view returns (bool) {
    uint256 idx = orders.first();
    while (idx > IntraOrderSet.QUEUE_START && idx < IntraOrderSet.QUEUE_END) {
      IntraOrderSet.IntraOrder storage order = orders.orderMap[idx];
      if (order.user == user && order.price > 0 && order.unit > 0) return true;
      idx = orders.nextMap[idx];
    }
    return false;
  }


  function _refund(
    uint256 epoch,
    uint8 strike,
    address user,
    bool byAdmin
  ) internal {
    Round storage round = rounds[epoch];
    require (block.timestamp > round.closeTimestamp + bufferSeconds, "E11");

    Option storage option = round.options[strike];
    uint256 totalAmount;

    for (int i = 0; i < 2; i++) {
      IntraOrderSet.Data storage orders = i == 0 ? option.overOrders : option.underOrders;
      uint256 idx = orders.first();
      while (idx > IntraOrderSet.QUEUE_START && idx < IntraOrderSet.QUEUE_END) {
        IntraOrderSet.IntraOrder storage order = orders.orderMap[idx];
        if (order.user == user && order.price > 0 && order.unit > 0) {
          // refund
          totalAmount += order.price * order.unit;

          uint256 prevIdx = idx;
          idx = orders.nextMap[prevIdx];  
          orders.remove(prevIdx);
        } else {
          idx = orders.nextMap[idx];
        }
      }
    }

    if (totalAmount > 0) {
      token.safeTransfer(user, totalAmount);
      emit Refund(user, epoch, strike, totalAmount, byAdmin);
    }
  }

  function _claimReward(uint256 epoch, uint8 strike, address user) internal returns (uint256) {
    uint256 reward = 0; // Initializes reward

    if (rounds[epoch].closeTimestamp == 0) return 0;
    if (block.timestamp < rounds[epoch].closeTimestamp) return 0;

    Round storage round = rounds[epoch];
    Option storage option = round.options[strike];

    uint256 strikePrice = (round.startPrice * uint256(option.strike)) / 100;

    bool isTie = strikePrice == round.closePrice;
    bool isOverWin = strikePrice < round.closePrice;
    bool isUnderWin = strikePrice > round.closePrice;

    if (round.oracleCalled) {
      // Round valid, claim rewards
      require(claimable(epoch, strike, user), "E12");
      uint256[] memory userFilledOrderIdx = option.userFilledOrder[user];
      for (uint i = 0; i < userFilledOrderIdx.length; i++) {
        FilledOrder storage order = option.filledOrders[userFilledOrderIdx[i]];
        if (order.overUser == user) {
          if (order.isOverClaimed) continue;
          if (isTie) {
            reward += order.overPrice * order.unit;
            order.isOverClaimed = true;
          } else if (isOverWin) {
            uint256 totalAmount = (order.overPrice + order.underPrice) * order.unit;
            uint256 fee = (order.underPrice * order.unit * commissionfee) / BASE;
            reward += totalAmount - fee;
            order.isOverClaimed = true;
          }

        } else if (order.underUser == user) {
          if (order.isUnderClaimed) continue;
          if (isTie) {
            reward += order.underPrice * order.unit;
            order.isUnderClaimed = true;
          } else if (isUnderWin) {
            uint256 totalAmount = (order.overPrice + order.underPrice) * order.unit;
            uint256 fee = (order.overPrice * order.unit * commissionfee) / BASE;
            reward += totalAmount - fee;
            order.isUnderClaimed = true;
          }
        }
      }
    } else {
      // Round invalid, refund Participate amount (after bufferSeconds)
      require(block.timestamp > round.closeTimestamp + bufferSeconds, "E13");
      uint256[] memory userFilledOrderIdx = option.userFilledOrder[user];
      for (uint i = 0; i < userFilledOrderIdx.length; i++) {
        FilledOrder storage filledOrder = option.filledOrders[userFilledOrderIdx[i]];
        if (filledOrder.overUser == user) {
          if (filledOrder.isOverClaimed) continue;
          reward += filledOrder.overPrice * filledOrder.unit;
          filledOrder.isOverClaimed = true;
        } else if (filledOrder.underUser == user) {
          if (filledOrder.isUnderClaimed) continue;
          reward += filledOrder.underPrice * filledOrder.unit;
          filledOrder.isUnderClaimed = true;
        }
      }
    }

    emit Claim(user, epoch, strike, reward);

    return reward;
  }

  function _trasferReward(address _user) internal {
    uint256 reward = 0; // Initializes reward

    for (uint256 epoch = 1; epoch <= currentEpoch; epoch++) {
      if (
        rounds[epoch].startTimestamp == 0 ||
        (block.timestamp < rounds[epoch].closeTimestamp + bufferSeconds)
      ) continue;

      Round storage round = rounds[epoch];
      for (uint i = 0; i < round.availableOptions.length; i++) {
        reward += _claimReward(epoch, round.availableOptions[i], _user);
      }
    }
    if (reward > 0) {
      token.safeTransfer(_user, reward);
    }
  }

  function _calculateCommission(uint256 epoch, uint8 strike) internal {
    uint256 treasuryAmt;

    Round storage round = rounds[epoch];
    Option storage option = round.options[strike];

    uint256 strikePrice = (round.startPrice * uint256(option.strike)) / 100;

    bool isTie = strikePrice == round.closePrice;
    bool isOverWin = strikePrice < round.closePrice;
    // bool isUnderWin = strikePrice > round.closePrice;

    if (!isTie) {
      uint256 last = option.filledOrderCounter.nextId();
      for (uint i = 1; i < last ; i++) {
        FilledOrder storage order = option.filledOrders[i];
        uint256 fee = ((isOverWin ? order.underPrice : order.overPrice) * order.unit * commissionfee) / BASE;
        treasuryAmt += fee;
      }
    }

    // Add to treasury
    treasuryAmount += treasuryAmt;

    emit CommissionCalculated(
      epoch,
      strike,
      treasuryAmt
    );
  }

  function _safeEndRound(uint256 epoch, uint256 price) internal {
    require(rounds[epoch].startTimestamp != 0, "E26");

    /* TODO: what is the side effect?
    require(block.timestamp >= rounds[epoch].closeTimestamp, "E27");
    require(
      block.timestamp <= rounds[epoch].closeTimestamp + bufferSeconds,
      "E28"
    );
    */
   
    // close round forcely
    rounds[epoch].closeTimestamp = block.timestamp;
    
    rounds[epoch].closePrice = uint256(price);
    rounds[epoch].oracleCalled = true;

    emit EndRound(epoch, rounds[epoch].closePrice);
  }

  function _startRound(uint256 epoch, uint256 initDate, uint256 price) internal {
    rounds[epoch].epoch = epoch;
    rounds[epoch].startTimestamp = initDate;
    rounds[epoch].closeTimestamp = initDate + intervalSeconds;
    rounds[epoch].startPrice = price;

    for (uint i=0; i < availableOptionStrikes.length; i++) {
        _initOption(epoch, availableOptionStrikes[i], price);
    }
  
    emit StartRound(epoch, initDate, rounds[epoch].startPrice, rounds[epoch].availableOptions);
  }

  function _initOption(uint256 epoch, uint8 strike, uint256 startPrice) internal {
    rounds[epoch].availableOptions.push(strike);
    rounds[epoch].options[strike].overOrders.initializeEmptyList();
    rounds[epoch].options[strike].underOrders.initializeEmptyList();

    uint256 strikePrice = startPrice * strike / 100;

    emit OptionCreated(epoch, strike, strikePrice);
  }

  /**
   * @notice Returns true if `account` is a contract.
   * @param account: account address
   */
  function _isContract(address account) internal view returns (bool) {
    uint256 size;
    assembly {
      size := extcodesize(account)
    }
    return size > 0;
  }
}
