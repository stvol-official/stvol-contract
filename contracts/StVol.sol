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
import "./libraries/LimitOrderSet.sol";

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
contract StVol is Ownable, Pausable, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using AutoIncrementing for AutoIncrementing.Counter;
  using LimitOrderSet for LimitOrderSet.Data;

  IERC20 public immutable token; // Prediction token

  IPyth public oracle;

  bool public genesisOpenOnce = false;
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
  uint256 public constant DEFAULT_MIN_PARTICIPATE_AMOUNT = 1000000; // 1 USDC
  uint256 public constant DEFAULT_INTERVAL_SECONDS = 86400; // 24 * 60 * 60 * 1(1day)
  uint256 public constant DEFAULT_BUFFER_SECONDS = 1800; // 30 * 60 (30min)

  mapping(uint256 => Round) public rounds; // (key: epoch)
  mapping(uint256 => AutoIncrementing.Counter) private counters; // (key: epoch)

  enum Position {
    Over,
    Under
  }
  struct Round {
    uint256 epoch;
    uint256 openTimestamp;
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
    uint256 totalAmount;
    uint256 overAmount;
    uint256 underAmount;
    uint256 rewardBaseCalAmount;
    uint256 rewardAmount;
    LimitOrderSet.Data overLimitOrders;
    LimitOrderSet.Data underLimitOrders;
    mapping(uint256 => MarketOrder) marketOrders;
    mapping(Position => mapping(address => ParticipateInfo)) ledger;
  }

  struct ParticipateInfo {
    Position position;
    uint256 amount;
    bool claimed; // default false
  }
  struct RoundAmount {
    uint256 totalAmount;
    uint256 overAmount;
    uint256 underAmount;
  }
  struct MarketOrder {
    uint256 idx;
    address user;
    Position position;
    uint256 amount;
    uint256 blockTimestamp;
    bool isCancelled;
  }

  event ParticipateUnder(
    uint256 indexed idx,
    address indexed sender,
    uint256 indexed epoch,
    uint8 strike,
    uint256 amount
  );
  event ParticipateOver(
    uint256 indexed idx,
    address indexed sender,
    uint256 indexed epoch,
    uint8 strike,
    uint256 amount
  );
  event CancelMarketOrder(
    uint256 indexed idx,
    address indexed sender,
    uint256 indexed epoch,
    uint8 strike,
    Position position,
    uint256 amount,
    uint256 cancelTimestamp
  );
  event ParticipateLimitOrder(
    uint256 indexed idx,
    address indexed sender,
    uint256 indexed epoch,
    uint8 strike,
    uint256 amount,
    uint256 payout,
    uint256 placeTimestamp,
    Position position,
    LimitOrderSet.LimitOrderStatus status
  );
  event Claim(
    address indexed sender,
    uint256 indexed epoch,
    uint8 indexed strike,
    Position position,
    uint256 amount
  );
  event EndRound(uint256 indexed epoch, uint256 price);
  event StartRound(uint256 indexed epoch, uint256 price);
  event RewardsCalculated(
    uint256 indexed epoch,
    uint8 indexed strike,
    uint256 rewardBaseCalAmount,
    uint256 rewardAmount,
    uint256 treasuryAmount
  );
  event OpenRound(
    uint256 indexed epoch,
    uint256 initDate
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
    availableOptionStrikes.push(97);
    availableOptionStrikes.push(99);
    availableOptionStrikes.push(100);
    availableOptionStrikes.push(101);
    availableOptionStrikes.push(103);
  }

  function participateUnder(
    uint256 epoch,
    uint8 strike,
    uint256 _amount
  ) external whenNotPaused nonReentrant {
    require(epoch == currentEpoch, "E07");
    require(_participable(epoch), "E08");
    require(_amount >= DEFAULT_MIN_PARTICIPATE_AMOUNT, "E09");

    token.safeTransferFrom(msg.sender, address(this), _amount);
    _participate(epoch, strike, Position.Under, msg.sender, _amount);
  }

  function participateOver(
    uint256 epoch,
    uint8 strike,
    uint256 _amount
  ) external whenNotPaused nonReentrant {
    require(epoch == currentEpoch, "E07");
    require(_participable(epoch), "E08");
    require(_amount >= DEFAULT_MIN_PARTICIPATE_AMOUNT, "E09");

    token.safeTransferFrom(msg.sender, address(this), _amount);
    _participate(epoch, strike, Position.Over, msg.sender, _amount);
  }

  function cancelMarketOrder(
    uint256 idx,
    uint256 epoch,
    uint8 strike
  ) external nonReentrant {
    require(rounds[epoch].openTimestamp != 0, "E21");
    require(block.timestamp < rounds[epoch].startTimestamp, "E22");

    Option storage option = rounds[epoch].options[strike];

    MarketOrder storage order = option.marketOrders[idx];
    require(order.user == msg.sender && !order.isCancelled, "E03");

    // update order
    order.isCancelled = true;

    // Update user data
    ParticipateInfo storage participateInfo = option.ledger[order.position][
      order.user
    ];
    participateInfo.amount = participateInfo.amount - order.amount;

    // Update user option data    
    option.totalAmount = option.totalAmount - order.amount;
    if (order.position == Position.Over) {
      option.overAmount = option.overAmount - order.amount;
    } else {
      option.underAmount = option.underAmount - order.amount;
    }

    // refund
    token.safeTransfer(order.user, order.amount);

    emit CancelMarketOrder(
      idx,
      msg.sender,
      epoch,
      strike,
      order.position,
      order.amount,
      block.timestamp
    );
  }

  function claim(uint256 epoch, uint8 strike, Position position) external nonReentrant {
    uint256 reward; // Initializes reward

    require(rounds[epoch].openTimestamp != 0, "E10");
    require(block.timestamp > rounds[epoch].closeTimestamp, "E11");

    uint256 addedReward = 0;

    Round storage round = rounds[epoch];
    Option storage option = round.options[strike];

    // Round valid, claim rewards
    if (round.oracleCalled) {
      require(claimable(epoch, strike, position, msg.sender), "E12");
      if (
        (option.overAmount > 0 && option.underAmount > 0) &&
        (round.startPrice != round.closePrice)
      ) {
        addedReward +=
          (option.ledger[position][msg.sender].amount *
            option.rewardAmount) /
          option.rewardBaseCalAmount;
      }
    } else {
      // Round invalid, refund Participate amount
      require(refundable(epoch, strike, position, msg.sender), "E13");
    }
    option.ledger[position][msg.sender].claimed = true;
    reward = option.ledger[position][msg.sender].amount + addedReward;

    emit Claim(msg.sender, epoch, strike, position, reward);

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
    require(genesisOpenOnce && genesisStartOnce, "E14");

    (int64 pythPrice, uint publishTime) = _getPythPrice(
      priceUpdateData,
      initDate,
      isFixed
    );

    Round storage currentRound = rounds[currentEpoch];
    require(
      publishTime >= currentRound.startTimestamp - bufferSeconds &&
        publishTime <= currentRound.startTimestamp + bufferSeconds,
      "E15"
    );

    
    // CurrentEpoch refers to previous round (n-1)
    _safeStartRound(currentEpoch, uint64(pythPrice));
    for (uint i=0; i < currentRound.availableOptions.length; i++) {
        _placeLimitOrders(currentEpoch, currentRound.availableOptions[i]);
    }
    _safeEndRound(currentEpoch - 1, uint64(pythPrice));

    Round storage prevRound = rounds[currentEpoch - 1];
    for (uint i=0; i < prevRound.availableOptions.length; i++) {
        _calculateRewards(currentEpoch - 1, prevRound.availableOptions[i]);
    }

    // Increment currentEpoch to current round (n)
    currentEpoch = currentEpoch + 1;
    _safeOpenRound(currentEpoch, initDate);
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

  function genesisStartRound(
    bytes[] calldata priceUpdateData,
    uint64 initDate,
    bool isFixed
  ) external payable whenNotPaused onlyOperator {
    require(genesisOpenOnce, "E16");
    require(!genesisStartOnce, "E32");

    (int64 pythPrice, uint publishTime) = _getPythPrice(
      priceUpdateData,
      initDate,
      isFixed
    );
    Round storage currentRound = rounds[currentEpoch];
    require(
      publishTime >= currentRound.startTimestamp - bufferSeconds &&
        publishTime <= currentRound.startTimestamp + bufferSeconds,
      "E15"
    );

    _safeStartRound(currentEpoch, uint64(pythPrice));
    for (uint i=0; i < currentRound.availableOptions.length; i++) {
        _placeLimitOrders(currentEpoch, currentRound.availableOptions[i]);
    }

    currentEpoch = currentEpoch + 1;
    _openRound(currentEpoch, initDate);
    genesisStartOnce = true;
  }

  function genesisOpenRound(
    uint256 initDate
  ) external whenNotPaused onlyOperator {
    require(!genesisOpenOnce, "E33");

    currentEpoch = currentEpoch + 1;
    _openRound(currentEpoch, initDate);
    genesisOpenOnce = true;
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
    genesisOpenOnce = false;
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

  function _trasferReward(address _user) internal {
    uint256 reward = 0; // Initializes reward

    for (uint256 epoch = 1; epoch <= currentEpoch; epoch++) {
      if (
        rounds[epoch].startTimestamp == 0 ||
        (block.timestamp < rounds[epoch].closeTimestamp + bufferSeconds)
      ) continue;

      Round storage round = rounds[epoch];
      for (uint i = 0; i < round.availableOptions.length; i++) {
        Option storage option = rounds[epoch].options[round.availableOptions[i]];
        
         // 0: Over, 1: Under
        uint pst = 0;
        while (pst <= uint(Position.Under)) {
            Position position = pst == 0 ? Position.Over : Position.Under;
            uint256 addedReward = 0;

            ParticipateInfo storage ledger = option.ledger[position][_user];

            
            if (claimable(epoch, option.strike, position, _user)) {
                // Round vaild, claim rewards
                if (
                    (option.overAmount > 0 && option.underAmount > 0) &&
                    (round.startPrice != round.closePrice)
                ) {
                    addedReward +=
                    (ledger.amount * option.rewardAmount) /
                    option.rewardBaseCalAmount;
                }
                addedReward += ledger.amount;
            } else {
                // Round invaild, refund bet amount
                if (refundable(epoch, option.strike, position, _user)) {
                    addedReward += ledger.amount;
                    addedReward += _getUndeclaredAmt(epoch, option.strike, position, _user);
                }
            }

            if (addedReward != 0) {
                ledger.claimed = true;
                reward += addedReward;
                emit Claim(_user, epoch, option.strike, position, addedReward);
            }
            pst++;
        }
      }
    }
    if (reward > 0) {
      token.safeTransfer(_user, reward);
    }
  }

  function claimable(
    uint256 epoch,
    uint8 strike,
    Position position,
    address user
  ) public view returns (bool) {
    Round storage round = rounds[epoch];
    Option storage option = round.options[strike];
    ParticipateInfo memory participateInfo = option.ledger[position][user];
    

    bool isPossible = false;
    if (option.overAmount > 0 && option.underAmount > 0) {
      isPossible = ((round.closePrice >
        _getStrikePrice(round.startPrice, strike) &&
        participateInfo.position == Position.Over) ||
        (round.closePrice < _getStrikePrice(round.startPrice, strike) &&
          participateInfo.position == Position.Under) ||
        (round.closePrice == _getStrikePrice(round.startPrice, strike)));
    } else {
      // refund user's fund if there is no paticipation on the other side
      isPossible = true;
    }
    return
      round.oracleCalled &&
      participateInfo.amount != 0 &&
      !participateInfo.claimed &&
      isPossible;
  }

  function refundable(
    uint256 epoch,
    uint8 strike,
    Position position,
    address user
  ) public view returns (bool) {
    Round storage round = rounds[epoch];
    Option storage option = round.options[strike];
    ParticipateInfo memory participateInfo = option.ledger[position][user];
    uint256 refundAmt = _getUndeclaredAmt(epoch, strike, position, user);
    refundAmt += participateInfo.amount;
    return
      !round.oracleCalled &&
      !participateInfo.claimed &&
      block.timestamp > round.closeTimestamp + bufferSeconds &&
      refundAmt != 0;
  }

  function _getUndeclaredAmt(
    uint256 epoch,
    uint8 strike,
    Position position,
    address user
  ) internal view returns (uint256) {
    uint256 amt = 0;
    Option storage option = rounds[epoch].options[strike];

    if (position == Position.Over) {
      amt += option.overLimitOrders.getUndeclaredAmt(user);
    } else {
      amt += option.underLimitOrders.getUndeclaredAmt(user);
    }
    return amt;
  }

  function _calculateRewards(uint256 epoch, uint8 strike) internal {
    Round storage round = rounds[epoch];
    Option storage option = round.options[strike];
    require(
      option.rewardBaseCalAmount == 0 &&
      option.rewardAmount == 0,
      "E29"
    );
    
    uint256 rewardBaseCalAmount;
    uint256 treasuryAmt;
    uint256 rewardAmount;

    // No participation on the other side refund participant amount to users
    if (option.overAmount == 0 || option.underAmount == 0) {
      rewardBaseCalAmount = 0;
      rewardAmount = 0;
      treasuryAmt = 0;
    } else {
      // Over wins
      if (round.closePrice > _getStrikePrice(round.startPrice, strike)) {
        rewardBaseCalAmount = option.overAmount;
        treasuryAmt = (option.underAmount * commissionfee) / BASE;
        rewardAmount = option.underAmount - treasuryAmt;
      }
      // Under wins
      else if (round.closePrice < _getStrikePrice(round.startPrice, strike)) {
        rewardBaseCalAmount = option.underAmount;
        treasuryAmt = (option.overAmount * commissionfee) / BASE;
        rewardAmount = option.overAmount - treasuryAmt;
      }
      // No one wins refund participant amount to users
      else {
        rewardBaseCalAmount = 0;
        rewardAmount = 0;
        treasuryAmt = 0;
      }
    }
    option.rewardBaseCalAmount = rewardBaseCalAmount;
    option.rewardAmount = rewardAmount;

    // Add to treasury
    treasuryAmount += treasuryAmt;

    emit RewardsCalculated(
      epoch,
      strike,
      rewardBaseCalAmount,
      rewardAmount,
      treasuryAmt
    );
  }

  function _getStrikePrice(
    uint256 price, uint8 strike
  ) internal pure returns (uint256) {
    return (price * uint256(strike)) / 100;
  }

  function _safeEndRound(uint256 epoch, uint256 price) internal {
    require(rounds[epoch].startTimestamp != 0, "E26");
    require(block.timestamp >= rounds[epoch].closeTimestamp, "E27");
    require(
      block.timestamp <= rounds[epoch].closeTimestamp + bufferSeconds,
      "E28"
    );
    rounds[epoch].closePrice = uint256(price);
    rounds[epoch].oracleCalled = true;

    emit EndRound(epoch, rounds[epoch].closePrice);
  }

  function _safeStartRound(uint256 epoch, uint256 price) internal {
    require(rounds[epoch].openTimestamp != 0, "E23");
    require(block.timestamp >= rounds[epoch].startTimestamp, "E24");
    require(
      block.timestamp <= rounds[epoch].startTimestamp + bufferSeconds,
      "E25"
    );
    rounds[epoch].startPrice = price;
    emit StartRound(epoch, rounds[epoch].startPrice);
  }

  function _safeOpenRound(uint256 epoch, uint256 initDate) internal {
    require(genesisOpenOnce, "E16");
    require(rounds[epoch - 2].closeTimestamp != 0, "E17");
    require(block.timestamp >= rounds[epoch - 2].closeTimestamp, "E18");
    require(block.timestamp >= initDate, "E19");
    _openRound(epoch, initDate);
  }

  function _openRound(uint256 epoch, uint256 initDate) internal {
    rounds[epoch].openTimestamp = initDate;
    rounds[epoch].startTimestamp = initDate + intervalSeconds;
    rounds[epoch].closeTimestamp = initDate + (2 * intervalSeconds);
    rounds[epoch].epoch = epoch;

    for (uint i=0; i < availableOptionStrikes.length; i++) {
        _initOption(epoch, availableOptionStrikes[i]);
    }
    emit OpenRound(epoch, initDate);
  }

  function _initOption(uint256 epoch, uint8 strike) internal {
    rounds[epoch].availableOptions.push(strike);
    rounds[epoch].options[strike].totalAmount = 0;
    rounds[epoch].options[strike].overLimitOrders.initializeEmptyList();
    rounds[epoch].options[strike].underLimitOrders.initializeEmptyList();
  }

  function _participable(uint256 epoch) internal view returns (bool) {
    return
      rounds[epoch].openTimestamp != 0 &&
      rounds[epoch].startTimestamp != 0 &&
      block.timestamp > rounds[epoch].openTimestamp &&
      block.timestamp < rounds[epoch].startTimestamp;
  }

  function _participate(
    uint256 epoch,
    uint8 strike,
    Position _position,
    address _user,
    uint256 _amount
  ) internal {
    Option storage option = rounds[epoch].options[strike];
    // Store market order
    uint256 idx = counters[epoch].nextId();
    option.marketOrders[idx] = MarketOrder(idx, _user, _position, _amount, block.timestamp, false);

    // Update user data
    ParticipateInfo storage participateInfo = option.ledger[_position][_user];

    participateInfo.position = _position;
    participateInfo.amount = participateInfo.amount + _amount;

    // Update option amount data
    option.totalAmount = option.totalAmount + _amount;
    if (_position == Position.Over) {
      option.overAmount = option.overAmount + _amount;
      emit ParticipateOver(idx, _user, epoch, strike, _amount);
    } else {
      option.underAmount = option.underAmount + _amount;
      emit ParticipateUnder(idx, _user, epoch, strike, _amount);
    }
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

  function participateLimitOver(
    uint256 epoch,
    uint8 strike,
    uint256 _amount,
    uint256 _payout,
    uint256 prevIdx
  ) external whenNotPaused nonReentrant {
    require(epoch == currentEpoch, "E07");
    require(_participable(epoch), "E08");
    require(_amount >= DEFAULT_MIN_PARTICIPATE_AMOUNT, "E09");
    require(_payout > BASE, "E20");
    // require(overLimitOrders[epoch].length <= MAX_LIMIT_ORDERS, "E35");

    token.safeTransferFrom(msg.sender, address(this), _amount);

    Option storage option = rounds[epoch].options[strike];
    LimitOrderSet.Data storage limitOrders = option.overLimitOrders;
    uint256 idx = counters[epoch].nextId();
    limitOrders.insert(
      LimitOrderSet.LimitOrder(
        idx,
        msg.sender,
        _payout,
        _amount,
        block.timestamp,
        LimitOrderSet.LimitOrderStatus.Undeclared
      ),
      prevIdx
    );

    emit ParticipateLimitOrder(
      idx,
      msg.sender,
      epoch,
      strike,
      _amount,
      _payout,
      block.timestamp,
      Position.Over,
      LimitOrderSet.LimitOrderStatus.Undeclared
    );
  }

  /**
   * @notice Participate under limit position
   */
  function participateLimitUnder(
    uint256 epoch,
    uint8 strike,
    uint256 _amount,
    uint256 _payout,
    uint256 prevIdx
  ) external whenNotPaused nonReentrant {
    require(epoch == currentEpoch, "E07");
    require(_participable(epoch), "E08");
    require(_amount >= DEFAULT_MIN_PARTICIPATE_AMOUNT, "E09");
    require(_payout > BASE, "E20");
    // require(underLimitOrders[epoch].length <= MAX_LIMIT_ORDERS, "E35");

    token.safeTransferFrom(msg.sender, address(this), _amount);

    Option storage option = rounds[epoch].options[strike];
    LimitOrderSet.Data storage limitOrders = option.underLimitOrders;
    uint256 idx = counters[epoch].nextId();
    limitOrders.insert(
      LimitOrderSet.LimitOrder(
        idx,
        msg.sender,
        _payout,
        _amount,
        block.timestamp,
        LimitOrderSet.LimitOrderStatus.Undeclared
      ),
      prevIdx
    );
    emit ParticipateLimitOrder(
      idx,
      msg.sender,
      epoch,
      strike,
      _amount,
      _payout,
      block.timestamp,
      Position.Under,
      LimitOrderSet.LimitOrderStatus.Undeclared
    );
  }

  function cancelLimitOrder(
    uint256 idx,
    uint256 epoch,
    uint8 strike,
    Position position
  ) external nonReentrant {
    require(rounds[epoch].openTimestamp != 0, "E21");
    require(block.timestamp < rounds[epoch].startTimestamp, "E22");

    LimitOrderSet.LimitOrder storage order;

    if (position == Position.Over) {
      order = rounds[epoch].options[strike].overLimitOrders.orderMap[idx];
    } else {
      order = rounds[epoch].options[strike].underLimitOrders.orderMap[idx];
    }

    if (
      order.user == msg.sender &&
      order.status == LimitOrderSet.LimitOrderStatus.Undeclared
    ) {
      order.status = LimitOrderSet.LimitOrderStatus.Cancelled;
      if (order.amount > 0) {
        token.safeTransfer(msg.sender, order.amount);
      }
      emit ParticipateLimitOrder(
        order.idx,
        msg.sender,
        epoch,
        strike,
        order.amount,
        order.payout,
        order.blockTimestamp,
        position,
        LimitOrderSet.LimitOrderStatus.Cancelled
      );
    }
  }

  function _placeLimitOrders(uint256 epoch, uint8 strike) internal {
    Option storage option = rounds[epoch].options[strike];
    RoundAmount memory ra = RoundAmount(
       option.totalAmount,
       option.overAmount,
       option.underAmount
    );

    bool applyPayout = false;
    LimitOrderSet.Data storage sortedOverLimitOrders = option.overLimitOrders;
    LimitOrderSet.Data storage sortedUnderLimitOrders = option.underLimitOrders;

    uint256 idx;
    do {
      // proc over limit orders
      idx = sortedOverLimitOrders.first();
      while (
        idx != LimitOrderSet.QUEUE_START && idx != LimitOrderSet.QUEUE_END
      ) {
        LimitOrderSet.LimitOrder storage order = sortedOverLimitOrders.orderMap[
          idx
        ];

        uint expectedPayout = ((ra.totalAmount + order.amount) * BASE) /
          (ra.overAmount + order.amount);
        if (
          order.payout <= expectedPayout &&
          order.status == LimitOrderSet.LimitOrderStatus.Undeclared
        ) {
          ra.totalAmount += order.amount;
          ra.overAmount += order.amount;
          order.status = LimitOrderSet.LimitOrderStatus.Approve;
        }
        idx = sortedOverLimitOrders.next(idx);
      }

      applyPayout = false;

      // proc under limit orders
      idx = sortedUnderLimitOrders.first();
      while (
        idx != LimitOrderSet.QUEUE_START && idx != LimitOrderSet.QUEUE_END
      ) {
        LimitOrderSet.LimitOrder storage order = sortedUnderLimitOrders
          .orderMap[idx];

        uint expectedPayout = ((ra.totalAmount + order.amount) * BASE) /
          (ra.underAmount + order.amount);
        if (
          order.payout <= expectedPayout &&
          order.status == LimitOrderSet.LimitOrderStatus.Undeclared
        ) {
          ra.totalAmount += order.amount;
          ra.underAmount += order.amount;
          order.status = LimitOrderSet.LimitOrderStatus.Approve;
        }
        idx = sortedUnderLimitOrders.next(idx);

        applyPayout = true;
      }
    } while (applyPayout);

    // proc over limit orders
    idx = sortedOverLimitOrders.first();
    while (idx != LimitOrderSet.QUEUE_START && idx != LimitOrderSet.QUEUE_END) {
      LimitOrderSet.LimitOrder storage order = sortedOverLimitOrders.orderMap[
        idx
      ];
      if (order.status == LimitOrderSet.LimitOrderStatus.Cancelled) {
        // do nothing
      } else if (order.status == LimitOrderSet.LimitOrderStatus.Undeclared) {
        // refund participate amount to user, change status to cancelled.
        order.status = LimitOrderSet.LimitOrderStatus.Cancelled;
        token.safeTransfer(order.user, order.amount);
        emit ParticipateLimitOrder(
          order.idx,
          order.user,
          epoch,
          strike,
          order.amount,
          order.payout,
          order.blockTimestamp,
          Position.Over,
          LimitOrderSet.LimitOrderStatus.Cancelled
        );
      } else if (order.status == LimitOrderSet.LimitOrderStatus.Approve) {
        _participate(epoch, strike, Position.Over, order.user, order.amount);
        emit ParticipateLimitOrder(
          order.idx,
          order.user,
          epoch,
          strike,
          order.amount,
          order.payout,
          order.blockTimestamp,
          Position.Over,
          LimitOrderSet.LimitOrderStatus.Approve
        );
      }
      idx = sortedOverLimitOrders.next(idx);
    }

    // proc under limit orders
    idx = sortedUnderLimitOrders.first();
    while (idx != LimitOrderSet.QUEUE_START && idx != LimitOrderSet.QUEUE_END) {
      LimitOrderSet.LimitOrder storage order = sortedUnderLimitOrders.orderMap[
        idx
      ];
      if (order.status == LimitOrderSet.LimitOrderStatus.Cancelled) {
        // do nothing
      } else if (order.status == LimitOrderSet.LimitOrderStatus.Undeclared) {
        // refund participate amount to user, change status to cancelled.
        order.status = LimitOrderSet.LimitOrderStatus.Cancelled;
        token.safeTransfer(order.user, order.amount);
        emit ParticipateLimitOrder(
          order.idx,
          order.user,
          epoch,
          strike,
          order.amount,
          order.payout,
          order.blockTimestamp,
          Position.Under,
          LimitOrderSet.LimitOrderStatus.Cancelled
        );
      } else if (order.status == LimitOrderSet.LimitOrderStatus.Approve) {
        _participate(epoch, strike, Position.Under, order.user, order.amount);
        emit ParticipateLimitOrder(
          order.idx,
          order.user,
          epoch,
          strike,
          order.amount,
          order.payout,
          order.blockTimestamp,
          Position.Under,
          LimitOrderSet.LimitOrderStatus.Approve
        );
      }
      idx = sortedUnderLimitOrders.next(idx);
    }
  }
}
