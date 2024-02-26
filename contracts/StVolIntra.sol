// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
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

  uint256[] public availableOptionStrikes; // available option markets. handled by Admin

  uint256 public commissionfee; // commission rate (e.g. 200 = 2%, 150 = 1.50%)
  uint256 public treasuryAmount; // treasury amount that was not claimed
  uint256 public participantRate; // participant distribute rate (e.g. 200 = 2%, 150 = 1.50%)
  uint256 public currentEpoch; // current epoch for round
  uint256 private constant BASE = 10000; // 100%
  uint256 private constant MAX_COMMISSION_FEE = 200; // 2%
  // uint256 public constant DEFAULT_MIN_PARTICIPATE_AMOUNT = 1000000; // 1 USDC (decimal: 6)
  uint256 internal ONE_TOKEN = 10 ** 6; // 6 for usdc, 18 for usdb
  uint256 internal HUNDRED_TOKEN = 100 * ONE_TOKEN;
  uint256 private constant DEFAULT_INTERVAL_SECONDS = 3600; // 60 * 60 (1 hour)
  uint256 private constant DEFAULT_BUFFER_SECONDS = 600; // 10 * 60 (10min)

  mapping(uint256 => Round) public rounds; // (key: epoch)
  mapping(uint256 => AutoIncrementing.Counter) private counters; // (key: epoch)

  mapping(address => uint256[]) private userRounds;

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
    uint256 strike; // 10000 = 100%, 10050 = 100.5%
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
    uint256[] availableOptions;
    mapping(uint256 => Option) options; // Binary Option Market (key: strike)
    // filled orders
    AutoIncrementing.Counter filledOrderCounter;
    mapping(uint256 => FilledOrder) filledOrders;
    mapping(address => uint256[]) userFilledOrder;
  }

  struct Option {
    uint256 strike; // 9800, 9900, 10000, 10100, 10200
    IntraOrderSet.Data overOrders;
    IntraOrderSet.Data underOrders;
  }

  struct UnfilledOrder {
    address user;
    uint256 idx;
    uint256 epoch;
    uint256 strike;
    Position position;
    uint256 price;
    uint256 unit;
  }

  struct FilledOrder {
    uint256 idx;
    uint256 epoch;
    uint256 strike;
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
    uint256 strike,
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
    uint256 strike,
    Position position,
    uint256 price,
    uint256 unit
  );

  event OrderFilled(
    uint256 indexed epoch,
    uint256 indexed idx,
    uint256 strike,
    uint256 placedIdx,
    Position position,
    address overUser,
    address underUser,
    uint256 overPrice,
    uint256 underPrice,
    uint256 unit,
    OrderType orderType
  );

  event ClaimRound(address indexed sender, uint256 indexed epoch, uint256 amount);
  event ClaimOrder(
    address indexed sender,
    uint256 indexed epoch,
    uint256 indexed idx,
    uint256 amount
  );

  event RefundRound(address indexed sender, uint256 indexed epoch, uint256 amount);
  event RefundFilledOrder(
    address indexed sender,
    uint256 indexed epoch,
    uint256 indexed idx,
    uint256 amount,
    bool byAdmin
  );

  event Refund(address indexed sender, uint256 indexed epoch, uint256 amount, bool byAdmin);

  event StartRound(
    uint256 indexed epoch,
    uint256 initDate,
    uint256 price,
    uint256[] availableOptionStrikes
  );

  event OptionCreated(uint256 indexed epoch, uint256 indexed strike, uint256 strikePrice);

  event EndRound(uint256 indexed epoch, uint256 price);

  event CommissionCalculated(uint256 indexed epoch, uint256 treasuryAmount);

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
    availableOptionStrikes.push(9900);
    availableOptionStrikes.push(9950);
    availableOptionStrikes.push(10000); // 100%
    availableOptionStrikes.push(10050);
    availableOptionStrikes.push(10100);
  }

  function placeLimitOrder(
    uint256 epoch,
    uint256 strike,
    Position position,
    uint256 price,
    uint256 unit,
    uint256 prevIdx
  ) external whenNotPaused nonReentrant {
    require(epoch == currentEpoch, "E07");
    require(
      rounds[epoch].startTimestamp != 0 && block.timestamp < rounds[epoch].closeTimestamp,
      "E08"
    );
    require(
      price >= ONE_TOKEN && price <= HUNDRED_TOKEN - ONE_TOKEN,
      "The price must be between 1 and 99."
    );
    require(price % ONE_TOKEN == 0, "The price must be an integer.");
    require(unit > 0, "The unit must be greater than 0.");

    uint256 transferedToken = price * unit;
    token.safeTransferFrom(msg.sender, address(this), transferedToken);

    uint256 idx = counters[epoch].nextId();

    uint256 usedToken;
    uint256 leftUnit;
    (usedToken, leftUnit) = _matchLimitOrders(Order(idx, epoch, strike, position, price, unit));

    if (leftUnit > 0) {
      Option storage option = rounds[epoch].options[strike];
      IntraOrderSet.Data storage orders = position == Position.Over
        ? option.overOrders
        : option.underOrders;
      orders.insert(
        IntraOrderSet.IntraOrder(idx, msg.sender, price, leftUnit), // unfilled order
        prevIdx
      );

      usedToken += price * leftUnit;
    }

    if (transferedToken > usedToken) {
      token.safeTransfer(msg.sender, transferedToken - usedToken);
    }

    _addUserRound(epoch);

    emit PlaceOrder(
      msg.sender,
      epoch,
      idx,
      strike,
      position,
      price,
      unit,
      unit - leftUnit,
      transferedToken - usedToken,
      OrderType.Limit
    );
  }

  function cancelLimitOrder(
    uint256 epoch,
    uint256 strike,
    Position position,
    uint256 idx
  ) external whenNotPaused nonReentrant {
    require(epoch == currentEpoch, "E07");
    require(
      rounds[epoch].startTimestamp != 0 && block.timestamp < rounds[epoch].closeTimestamp,
      "E08"
    );
    require(idx > 0, "The idx must be greater than 0.");

    Option storage option = rounds[epoch].options[strike];
    IntraOrderSet.Data storage orders = position == Position.Over
      ? option.overOrders
      : option.underOrders;
    IntraOrderSet.IntraOrder storage order = orders.orderMap[idx];
    require(order.user == msg.sender, "E03");

    uint256 refundAmount = order.price * order.unit;
    orders.remove(idx);

    token.safeTransfer(msg.sender, refundAmount);

    emit CancelLimitOrder(msg.sender, epoch, idx, strike, position, order.price, order.unit);
  }

  function placeMarketOrder(
    uint256 epoch,
    uint256 strike,
    Position position,
    uint256 price, // expected average price
    uint256 unit // max unit of the order
  ) external whenNotPaused nonReentrant {
    require(epoch == currentEpoch, "E07");
    require(
      rounds[epoch].startTimestamp != 0 && block.timestamp < rounds[epoch].closeTimestamp,
      "E08"
    );
    require(
      price >= ONE_TOKEN && price <= HUNDRED_TOKEN - ONE_TOKEN,
      "The price must be between 1 and 99."
    );
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

    _addUserRound(epoch);

    emit PlaceOrder(
      msg.sender,
      epoch,
      idx,
      strike,
      position,
      price,
      unit,
      totalUnit,
      transferedToken - totalAmount,
      OrderType.Market
    );
  }

  function collectRoundByAdmin(
    uint256 epoch,
    address _user
  ) external nonReentrant whenPaused onlyAdmin {
    _collectRound(epoch, _user);
  }

  function collectRound(uint256 epoch) external nonReentrant {
    _collectRound(epoch, msg.sender);
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
    (int64 pythPrice, uint publishTime) = _getPythPrice(priceUpdateData, initDate, isFixed);

    require(
      publishTime >= initDate - bufferSeconds && publishTime <= initDate + bufferSeconds,
      "E15"
    );

    // increase currentEpoch and start next round
    currentEpoch = currentEpoch + 1;

    _startRound(currentEpoch, initDate, uint64(pythPrice));

    if (genesisStartOnce) {
      // end prev round
      _safeEndRound(currentEpoch - 1, uint64(pythPrice));
      _calculateCommission(currentEpoch - 1);
    } else {
      genesisStartOnce = true;
    }
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

  function setCommissionfee(uint256 _commissionfee) external whenPaused onlyAdmin {
    require(_commissionfee <= MAX_COMMISSION_FEE, "E04");
    commissionfee = _commissionfee;
  }

  function setOptionStrikes(uint256[] calldata _strikes) external onlyAdmin {
    availableOptionStrikes = _strikes;
  }

  function setAdmin(address _adminAddress) external onlyOwner {
    require(_adminAddress != address(0), "E31");
    adminAddress = _adminAddress;
  }

  /* public views */
  function getAvailableOptionsInRound(uint256 epoch) public view returns (uint256[] memory) {
    return rounds[epoch].availableOptions;
  }

  function getHighestPrices(uint256 epoch, uint256 strike) public view returns (uint256, uint256) {
    Option storage option = rounds[epoch].options[strike];

    return (
      option.underOrders.orderMap[option.underOrders.first()].price,
      option.overOrders.orderMap[option.overOrders.first()].price
    );
  }

  function getRoundUserFilledOrders(
    uint256 epoch,
    address user
  ) public view returns (FilledOrder[] memory) {
    Round storage round = rounds[epoch];
    uint256[] storage orderIds = round.userFilledOrder[user];
    FilledOrder[] memory orders = new FilledOrder[](orderIds.length);
    for (uint256 i = 0; i < orderIds.length; i++) {
      orders[i] = round.filledOrders[orderIds[i]];
    }
    return orders;
  }

  function getRoundUserUnfilledOrders(
    uint256 epoch,
    address user
  ) public view returns (UnfilledOrder[] memory) {
    Round storage round = rounds[epoch];

    uint256 count = 0;

    // calculate count (length of result)
    for (uint256 i = 0; i < round.availableOptions.length; i++) {
      Option storage option = round.options[round.availableOptions[i]];
      for (uint p = 0; p < 2; p++) {
        IntraOrderSet.Data storage orders = p == 0 ? option.overOrders : option.underOrders;
        uint256 idx = orders.first();
        while (idx != IntraOrderSet.QUEUE_START && idx != IntraOrderSet.QUEUE_END) {
          IntraOrderSet.IntraOrder memory order = orders.orderMap[idx];
          if (order.user == user) {
            count++;
          }
          idx = orders.next(idx);
        }
      }
    }

    UnfilledOrder[] memory result = new UnfilledOrder[](count);
    uint256 resultIndex = 0;

    for (uint256 i = 0; i < round.availableOptions.length; i++) {
      Option storage option = round.options[round.availableOptions[i]];

      for (uint p = 0; p < 2; p++) {
        IntraOrderSet.Data storage orders = p == 0 ? option.overOrders : option.underOrders;
        uint256 idx = orders.first();
        while (idx != IntraOrderSet.QUEUE_START && idx != IntraOrderSet.QUEUE_END) {
          IntraOrderSet.IntraOrder memory order = orders.orderMap[idx];
          if (order.user == user) {
            result[resultIndex] = UnfilledOrder(
              user,
              order.idx,
              epoch,
              option.strike,
              p == 0 ? Position.Over : Position.Under,
              order.price,
              order.unit
            );
            resultIndex++;
          }

          idx = orders.next(idx);
        }
      }
    }

    return result;
  }

  function getUserPlacedRounds(
    address user,
    uint size,
    uint page
  ) public view returns (uint256[] memory) {
    uint256[] storage roundsEpoch = userRounds[user];

    uint startIndex = size * (page - 1);
    if (startIndex > roundsEpoch.length) {
      startIndex = roundsEpoch.length;
    }
    uint endIndex = startIndex + size;
    if (endIndex > roundsEpoch.length) {
      endIndex = roundsEpoch.length;
    }
    uint actualSize = endIndex - startIndex;

    uint256[] memory result = new uint256[](actualSize);
    for (uint i = 0; i < actualSize; i++) {
      result[i] = roundsEpoch[roundsEpoch.length - startIndex - i - 1];
    }

    return result;
  }

  function getTotalMarketPrice(
    uint256 epoch,
    uint256 strike,
    Position position,
    uint256 unit
  ) public view returns (uint256, uint256) {
    Option storage option = rounds[epoch].options[strike];
    IntraOrderSet.Data storage counterOrders = position == Position.Over
      ? option.underOrders
      : option.overOrders;

    uint256 totalUnit;
    uint256 totalPrice;

    uint256 counterIdx = counterOrders.first();

    while (totalUnit < unit) {
      if (counterIdx == IntraOrderSet.QUEUE_START || counterIdx == IntraOrderSet.QUEUE_END) {
        // counter order is empty
        break;
      }

      IntraOrderSet.IntraOrder storage counterOrder = counterOrders.orderMap[counterIdx];
      uint256 myPrice = HUNDRED_TOKEN - counterOrder.price;
      uint256 txUnit = (unit - totalUnit) < counterOrder.unit
        ? unit - totalUnit
        : counterOrder.unit; // min

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

  function getUnfilledAmount(uint256 epoch, address user) public view returns (uint256) {
    Round storage round = rounds[epoch];

    uint256 result;
    for (uint256 s = 0; s < round.availableOptions.length; s++) {
      Option storage option = round.options[round.availableOptions[s]];

      result += option.overOrders.getUserAmount(user);
      result += option.underOrders.getUserAmount(user);
    }
    return result;
  }

  function getOrderbook(
    uint256 epoch,
    uint256 strike,
    Position position
  ) public view returns (IntraOrderSet.IntraOrder[] memory) {
    Option storage option = rounds[epoch].options[strike];
    IntraOrderSet.Data storage orders = position == Position.Over
      ? option.overOrders
      : option.underOrders;

    return orders.toArray();
  }

  /* internal functions */
  function _collectRound(uint256 epoch, address _user) internal {
    // claim + refund
    require(rounds[epoch].closeTimestamp != 0, "E11");
    require(block.timestamp > rounds[epoch].closeTimestamp, "E11");

    uint256 reward = _claimReward(epoch, _user);

    if (reward > 0) {
      token.safeTransfer(_user, reward);
    }
    _refund(epoch, _user, false);
  }

  function _matchLimitOrders(Order memory order) internal returns (uint256, uint256) {
    Option storage option = rounds[order.epoch].options[order.strike];
    IntraOrderSet.Data storage counterOrders = order.position == Position.Over
      ? option.underOrders
      : option.overOrders;
    uint256 usedToken;
    uint256 leftUnit = order.unit;

    while (leftUnit > 0) {
      uint256 counterIdx = counterOrders.first();
      if (counterIdx == IntraOrderSet.QUEUE_START || counterIdx == IntraOrderSet.QUEUE_END) {
        // counter order is empty
        break;
      }

      IntraOrderSet.IntraOrder storage counterOrder = counterOrders.orderMap[counterIdx];
      if (counterOrder.price + order.price < HUNDRED_TOKEN) {
        // 100 usdc
        // no more matched counter orders
        break;
      }

      uint256 myPrice = HUNDRED_TOKEN - counterOrder.price;
      uint256 txUnit = leftUnit < counterOrder.unit ? leftUnit : counterOrder.unit; // min

      _createFilledOrder(
        rounds[order.epoch],
        order,
        counterOrder,
        myPrice,
        txUnit,
        OrderType.Limit
      );

      leftUnit = leftUnit - txUnit;
      usedToken += myPrice * txUnit;

      if (counterOrder.unit - txUnit == 0) {
        // remove
        counterOrders.remove(counterIdx);
      } else {
        // update
        counterOrder.unit = counterOrder.unit - txUnit;
      }
    }
    return (usedToken, leftUnit); // used token and unmatched unit
  }

  function _matchMarketOrders(Order memory order) internal returns (uint256, uint256) {
    Option storage option = rounds[order.epoch].options[order.strike];
    IntraOrderSet.Data storage counterOrders = order.position == Position.Over
      ? option.underOrders
      : option.overOrders;

    uint256 totalUnit;
    uint256 totalAmount;

    while (totalUnit < order.unit) {
      uint256 counterIdx = counterOrders.first();
      if (counterIdx == IntraOrderSet.QUEUE_START || counterIdx == IntraOrderSet.QUEUE_END) {
        // counter order is empty
        break;
      }

      IntraOrderSet.IntraOrder storage counterOrder = counterOrders.orderMap[counterIdx];
      uint256 myPrice = HUNDRED_TOKEN - counterOrder.price;
      uint256 txUnit = (order.unit - totalUnit) < counterOrder.unit
        ? order.unit - totalUnit
        : counterOrder.unit; // min

      txUnit = _findExactUnit(totalAmount, totalUnit, myPrice, txUnit, order.price);

      if (txUnit == 0) {
        // no more matching
        break;
      }

      _createFilledOrder(
        rounds[order.epoch],
        order,
        counterOrder,
        myPrice,
        txUnit,
        OrderType.Market
      );

      totalAmount += myPrice * txUnit;
      totalUnit += txUnit;

      if (counterOrder.unit - txUnit == 0) {
        // remove
        counterOrders.remove(counterIdx);
      } else {
        // update
        counterOrder.unit = counterOrder.unit - txUnit;
        break; // no more matching
      }
    }
    return (totalUnit, totalAmount);
  }

  function _createFilledOrder(
    Round storage round,
    Order memory order,
    IntraOrderSet.IntraOrder storage counterOrder,
    uint256 myPrice,
    uint256 txUnit,
    OrderType orderType
  ) internal {
    uint256 txId = round.filledOrderCounter.nextId();
    round.filledOrders[txId] = FilledOrder(
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
    round.userFilledOrder[msg.sender].push(txId);
    if (msg.sender != counterOrder.user) {
      round.userFilledOrder[counterOrder.user].push(txId);
    }

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

  function _findExactUnit(
    uint256 totalPrice,
    uint256 totalUnit,
    uint256 myPrice,
    uint256 txUnit,
    uint256 price
  ) internal pure returns (uint256) {
    uint256 newTotalPrice = totalPrice + (myPrice * txUnit);
    uint256 newTotalUnits = totalUnit + txUnit;

    if (newTotalPrice / newTotalUnits <= price) {
      // all txUnit matched!
    } else {
      // check one by one
      uint256 newTxUnit;
      for (uint i = 1; i < txUnit; i++) {
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
      PythStructs.PriceFeed memory pythPrice = oracle.parsePriceFeedUpdates{ value: fee }(
        priceUpdateData,
        pythPair,
        fixedTimestamp,
        fixedTimestamp + uint64(bufferSeconds)
      )[0];
      return (pythPrice.price.price, fixedTimestamp);
    } else {
      oracle.updatePriceFeeds{ value: fee }(priceUpdateData);
      return (oracle.getPrice(priceId).price, oracle.getPrice(priceId).publishTime);
    }
  }

  function _refund(uint256 epoch, address user, bool byAdmin) internal {
    Round storage round = rounds[epoch];
    require(block.timestamp > round.closeTimestamp, "E11");

    uint256 totalAmount;
    for (uint256 s = 0; s < round.availableOptions.length; s++) {
      Option storage option = round.options[round.availableOptions[s]];

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
    }

    if (totalAmount > 0) {
      token.safeTransfer(user, totalAmount);
      emit Refund(user, epoch, totalAmount, byAdmin);
    }
  }

  function _calculateOrderReward(
    address user,
    FilledOrder storage order
  ) internal returns (uint256) {
    Round storage round = rounds[order.epoch];
    Option storage option = round.options[order.strike];

    uint256 strikePrice = (round.startPrice * option.strike) / 10000;

    bool isTie = strikePrice == round.closePrice;
    bool isOverWin = strikePrice < round.closePrice;
    bool isUnderWin = strikePrice > round.closePrice;

    uint256 reward = 0;
    if (order.overUser == user && !order.isOverClaimed) {
      if (isTie) {
        reward += order.overPrice * order.unit;
        order.isOverClaimed = true;
      } else if (isOverWin) {
        uint256 totalAmount = (order.overPrice + order.underPrice) * order.unit;
        uint256 fee = (order.underPrice * order.unit * commissionfee) / BASE;
        reward += totalAmount - fee;
        order.isOverClaimed = true;
      }
    }

    if (order.underUser == user && !order.isUnderClaimed) {
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
    return reward;
  }

  function _calculateOrderRefund(
    address user,
    FilledOrder storage order
  ) internal returns (uint256) {
    uint256 reward = 0;
    if (order.overUser == user && !order.isOverClaimed) {
      reward += order.overPrice * order.unit;
      order.isOverClaimed = true;
    }
    if (order.underUser == user && !order.isUnderClaimed) {
      reward += order.underPrice * order.unit;
      order.isUnderClaimed = true;
    }
    return reward;
  }

  function _claimReward(uint256 epoch, address user) internal returns (uint256) {
    uint256 reward = 0; // Initializes reward

    if (rounds[epoch].closeTimestamp == 0) return 0;
    if (block.timestamp < rounds[epoch].closeTimestamp) return 0;

    Round storage round = rounds[epoch];

    if (round.oracleCalled) {
      // Round valid, claim rewards
      uint256[] memory userFilledOrderIdx = round.userFilledOrder[user];
      for (uint i = 0; i < userFilledOrderIdx.length; i++) {
        FilledOrder storage order = round.filledOrders[userFilledOrderIdx[i]];
        reward += _calculateOrderReward(user, order);
      }
      if (reward > 0) {
        emit ClaimRound(user, epoch, reward);
      }
    } else {
      // Round invalid, refund Participate amount (after bufferSeconds)
      require(block.timestamp > round.closeTimestamp + bufferSeconds, "E13");
      uint256[] memory userFilledOrderIdx = round.userFilledOrder[user];
      for (uint i = 0; i < userFilledOrderIdx.length; i++) {
        FilledOrder storage filledOrder = round.filledOrders[userFilledOrderIdx[i]];
        reward += _calculateOrderRefund(msg.sender, filledOrder);
      }
      if (reward > 0) {
        emit RefundRound(user, epoch, reward);
      }
    }

    return reward;
  }

  function _trasferReward(address _user) internal {
    uint256 reward = 0; // Initializes reward

    for (uint256 epoch = 1; epoch <= currentEpoch; epoch++) {
      if (
        rounds[epoch].startTimestamp == 0 ||
        (block.timestamp < rounds[epoch].closeTimestamp + bufferSeconds)
      ) continue;

      reward += _claimReward(epoch, _user);
    }
    if (reward > 0) {
      token.safeTransfer(_user, reward);
    }
  }

  function _calculateCommission(uint256 epoch) internal {
    uint256 treasuryAmt;

    Round storage round = rounds[epoch];

    uint256 last = round.filledOrderCounter.nextId();

    for (uint i = 1; i < last; i++) {
      FilledOrder storage order = round.filledOrders[i];

      uint256 strikePrice = (round.startPrice * order.strike) / 10000;
      bool isTie = strikePrice == round.closePrice;
      if (isTie) continue;

      bool isOverWin = strikePrice < round.closePrice;

      uint256 fee = ((isOverWin ? order.underPrice : order.overPrice) *
        order.unit *
        commissionfee) / BASE;
      treasuryAmt += fee;
    }

    // Add to treasury
    treasuryAmount += treasuryAmt;

    emit CommissionCalculated(epoch, treasuryAmt);
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

    for (uint i = 0; i < availableOptionStrikes.length; i++) {
      _initOption(epoch, availableOptionStrikes[i], price);
    }

    emit StartRound(epoch, initDate, rounds[epoch].startPrice, rounds[epoch].availableOptions);
  }

  function _addUserRound(uint256 epoch) internal {
    uint256[] storage epochArray = userRounds[msg.sender];
    if (epochArray.length == 0 || epochArray[epochArray.length - 1] != epoch) {
      epochArray.push(epoch);
    }
  }

  function _initOption(uint256 epoch, uint256 strike, uint256 startPrice) internal {
    rounds[epoch].availableOptions.push(strike);
    rounds[epoch].options[strike].strike = strike;
    rounds[epoch].options[strike].overOrders.initializeEmptyList();
    rounds[epoch].options[strike].underOrders.initializeEmptyList();

    uint256 strikePrice = (startPrice * strike) / 10000;

    emit OptionCreated(epoch, strike, strikePrice);
  }
}
