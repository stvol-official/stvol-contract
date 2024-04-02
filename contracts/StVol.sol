// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
 * E09: Order amount must be greater than minOrderAmount
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
 * E20: Order payout must be greater than zero
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
    uint256 public constant DEFAULT_MIN_ORDER_AMOUNT = 1000000; // 1 USDC
    uint256 public constant DEFAULT_INTERVAL_SECONDS = 86400; // 24 * 60 * 60 * 1(1day)
    uint256 public constant DEFAULT_BUFFER_SECONDS = 1800; // 30 * 60 (30min)

    mapping(uint256 => Round) public rounds; // (key: epoch)
    mapping(uint256 => mapping(Position => AutoIncrementing.Counter))
        private _counters; // (key: epoch => position)

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
        mapping(address => OrderInfo[]) ledgers;
    }

    struct RoundResponse {
        uint256 epoch;
        uint256 openTimestamp;
        uint256 startTimestamp;
        uint256 closeTimestamp;
        uint256 startPrice;
        uint256 closePrice;
        uint256 startOracleId;
        uint256 closeOracleId;
        bool oracleCalled;
        uint256 intervalSeconds;
        uint256 bufferSeconds;
        OptionResponse[] options;
    }

    struct OptionResponse {
        uint8 strike; // 97, 99, 100, 101, 103
        uint256 totalAmount;
        uint256 overAmount;
        uint256 underAmount;
        uint256 rewardBaseCalAmount;
        uint256 rewardAmount;
    }

    struct OrderInfoResponse {
        uint8 strike;
        uint256 epoch;
        uint256 idx;
        uint256 amount;
        Position position;
        bool claimed; // default false
        bool isCancelled;
    }

    struct OrderInfo {
        uint256 idx;
        Position position;
        uint256 amount;
        bool claimed; // default false
        bool isCancelled;
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

    event PlaceMarketOrder(
        uint256 indexed idx,
        address indexed sender,
        uint256 indexed epoch,
        Position position,
        uint8 strike,
        uint256 amount,
        bool isCancelled,
        uint256 placeTimestamp
    );
    event PlaceLimitOrder(
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
        uint256 idx,
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
        uint256 openTimestamp,
        uint256 startTimestamp,
        uint256 closeTimestamp,
        uint8[] strikes
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
    ) Ownable(msg.sender) {
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

    function placeMarketOrder(
        uint256 _epoch,
        uint8 _strike,
        Position _position,
        uint256 _amount
    ) external whenNotPaused nonReentrant {
        require(_epoch == currentEpoch, "E07");
        require(_participable(_epoch), "E08");
        require(_amount >= DEFAULT_MIN_ORDER_AMOUNT, "E09");

        token.safeTransferFrom(msg.sender, address(this), _amount);
        _placeOrder(_epoch, _strike, _position, msg.sender, _amount);
    }

    function cancelMarketOrder(
        uint256 _epoch,
        uint256 _idx,
        uint8 _strike,
        Position _position
    ) external nonReentrant {
        require(rounds[_epoch].openTimestamp != 0, "E21");
        require(block.timestamp < rounds[_epoch].startTimestamp, "E22");

        Option storage option = rounds[_epoch].options[_strike];

        // Update user data
        OrderInfo storage orderInfo = _getOrderInfoByIdx(
            _epoch,
            _strike,
            _position,
            _idx,
            msg.sender
        );
        require(!orderInfo.isCancelled && !orderInfo.claimed, "E03");
        orderInfo.isCancelled = true;

        // Update user option data
        option.totalAmount = option.totalAmount - orderInfo.amount;
        if (orderInfo.position == Position.Over) {
            option.overAmount = option.overAmount - orderInfo.amount;
        } else {
            option.underAmount = option.underAmount - orderInfo.amount;
        }

        // refund
        token.safeTransfer(msg.sender, orderInfo.amount);

        emit PlaceMarketOrder(
            _idx,
            msg.sender,
            _epoch,
            orderInfo.position,
            _strike,
            orderInfo.amount,
            true,
            block.timestamp
        );
    }

    function claim(
        uint256 _epoch,
        uint8 _strike,
        Position _position,
        uint256 _idx
    ) external nonReentrant {
        uint256 reward; // Initializes reward

        require(rounds[_epoch].openTimestamp != 0, "E10");
        require(block.timestamp > rounds[_epoch].closeTimestamp, "E11");

        uint256 addedReward = 0;

        Round storage round = rounds[_epoch];
        Option storage option = round.options[_strike];
        OrderInfo storage orderInfo = _getOrderInfoByIdx(
            _epoch,
            _strike,
            _position,
            _idx,
            msg.sender
        );

        // Round valid, claim rewards
        if (round.oracleCalled) {
            require(
                claimable(_epoch, _strike, _position, _idx, msg.sender),
                "E12"
            );
            if (
                (option.overAmount > 0 && option.underAmount > 0) &&
                (round.startPrice != round.closePrice)
            ) {
                addedReward +=
                    (orderInfo.amount * option.rewardAmount) /
                    option.rewardBaseCalAmount;
            }
        } else {
            // Round invalid, refund Participate amount
            require(
                refundable(_epoch, _strike, _position, _idx, msg.sender),
                "E13"
            );
        }
        orderInfo.claimed = true;
        reward = orderInfo.amount + addedReward;

        emit Claim(msg.sender, _epoch, _strike, _position, _idx, reward);

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
        bytes[] calldata _priceUpdateData,
        uint64 _initDate,
        bool _isFixed
    ) external payable whenNotPaused onlyOperator {
        require(genesisOpenOnce && genesisStartOnce, "E14");

        (int64 pythPrice, uint publishTime) = _getPythPrice(
            _priceUpdateData,
            _initDate,
            _isFixed
        );

        Round storage currentRound = rounds[currentEpoch];
        require(
            publishTime >= currentRound.startTimestamp - bufferSeconds &&
                publishTime <= currentRound.startTimestamp + bufferSeconds,
            "E15"
        );

        // CurrentEpoch refers to previous round (n-1)
        _safeStartRound(currentEpoch, uint64(pythPrice));
        for (uint i = 0; i < currentRound.availableOptions.length; i++) {
            _placeLimitOrders(currentEpoch, currentRound.availableOptions[i]);
        }
        _safeEndRound(currentEpoch - 1, uint64(pythPrice));

        Round storage prevRound = rounds[currentEpoch - 1];
        for (uint i = 0; i < prevRound.availableOptions.length; i++) {
            _calculateRewards(currentEpoch - 1, prevRound.availableOptions[i]);
        }

        // Increment currentEpoch to current round (n)
        currentEpoch = currentEpoch + 1;
        _safeOpenRound(currentEpoch, _initDate);
    }

    function _getPythPrice(
        bytes[] memory _priceUpdateData,
        uint64 _fixedTimestamp,
        bool _isFixed
    ) internal returns (int64, uint) {
        bytes32[] memory pythPair = new bytes32[](1);
        pythPair[0] = priceId;

        uint fee = oracle.getUpdateFee(_priceUpdateData);
        if (_isFixed) {
            PythStructs.PriceFeed memory pythPrice = oracle
                .parsePriceFeedUpdates{value: fee}(
                _priceUpdateData,
                pythPair,
                _fixedTimestamp,
                _fixedTimestamp + uint64(bufferSeconds)
            )[0];
            return (pythPrice.price.price, _fixedTimestamp);
        } else {
            oracle.updatePriceFeeds{value: fee}(_priceUpdateData);
            return (
                oracle.getPrice(priceId).price,
                oracle.getPrice(priceId).publishTime
            );
        }
    }

    function genesisStartRound(
        bytes[] calldata _priceUpdateData,
        uint64 _initDate,
        bool _isFixed
    ) external payable whenNotPaused onlyOperator {
        require(genesisOpenOnce, "E16");
        require(!genesisStartOnce, "E32");

        (int64 pythPrice, uint publishTime) = _getPythPrice(
            _priceUpdateData,
            _initDate,
            _isFixed
        );
        Round storage currentRound = rounds[currentEpoch];
        require(
            publishTime >= currentRound.startTimestamp - bufferSeconds &&
                publishTime <= currentRound.startTimestamp + bufferSeconds,
            "E15"
        );

        _safeStartRound(currentEpoch, uint64(pythPrice));
        for (uint i = 0; i < currentRound.availableOptions.length; i++) {
            _placeLimitOrders(currentEpoch, currentRound.availableOptions[i]);
        }

        currentEpoch = currentEpoch + 1;
        _openRound(currentEpoch, _initDate);
        genesisStartOnce = true;
    }

    function genesisOpenRound(
        uint256 _initDate
    ) external whenNotPaused onlyOperator {
        require(!genesisOpenOnce, "E33");

        currentEpoch = currentEpoch + 1;
        _openRound(currentEpoch, _initDate);
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

    function withdraw(uint _amount) external onlyAdmin {
        require(_amount <= address(this).balance);
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

    function setOperatorVault(
        address _operatorVaultAddress
    ) external onlyAdmin {
        require(_operatorVaultAddress != address(0), "E31");
        operatorVaultAddress = _operatorVaultAddress;
    }

    function setCommissionfee(
        uint256 _commissionfee
    ) external whenPaused onlyAdmin {
        require(_commissionfee <= MAX_COMMISSION_FEE, "E04");
        commissionfee = _commissionfee;
    }

    function addOptionStrike(uint8 _strike) external onlyAdmin {
        int idx = -1;
        for (uint i = 0; i < availableOptionStrikes.length; i++) {
            if (_strike == availableOptionStrikes[i]) {
                idx = int(i);
                break;
            }
        }
        require(idx == -1, "Already Exists");
        availableOptionStrikes.push(_strike);
    }

    function removeOptionStrike(uint8 _strike) external onlyAdmin {
        int idx = -1;
        for (uint i = 0; i < availableOptionStrikes.length; i++) {
            if (_strike == availableOptionStrikes[i]) {
                idx = int(i);
                break;
            }
        }
        require(idx != -1, "Not Exists");
        availableOptionStrikes[uint(idx)] = availableOptionStrikes[
            availableOptionStrikes.length - 1
        ];
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
                Option storage option = rounds[epoch].options[
                    round.availableOptions[i]
                ];
                OrderInfo[] storage orderInfos = option.ledgers[_user];

                // pre-market
                for (uint j = 0; j < orderInfos.length; j++) {
                    uint256 addedReward = 0;
                    OrderInfo storage ledger = orderInfos[j];

                    if (
                        claimable(
                            epoch,
                            option.strike,
                            ledger.position,
                            ledger.idx,
                            _user
                        )
                    ) {
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
                        if (
                            refundable(
                                epoch,
                                option.strike,
                                ledger.position,
                                ledger.idx,
                                _user
                            )
                        ) {
                            addedReward += ledger.amount;
                        }
                    }

                    if (addedReward != 0) {
                        ledger.claimed = true;
                        reward += addedReward;
                        emit Claim(
                            _user,
                            epoch,
                            option.strike,
                            ledger.position,
                            ledger.idx,
                            addedReward
                        );
                    }
                }
                // refund limit-order amount
                if (
                    refundable(epoch, option.strike, Position.Over, 0, _user) ||
                    refundable(epoch, option.strike, Position.Under, 0, _user)
                ) {
                    reward += _getUndeclaredAmt(epoch, option.strike, _user);
                }
            }
        }
        if (reward > 0) {
            token.safeTransfer(_user, reward);
        }
    }

    function claimable(
        uint256 _epoch,
        uint8 _strike,
        Position _position,
        uint256 _idx,
        address _user
    ) public view returns (bool) {
        Round storage round = rounds[_epoch];
        Option storage option = round.options[_strike];
        OrderInfo memory orderInfo = _getOrderInfoByIdx(
            _epoch,
            _strike,
            _position,
            _idx,
            _user
        );

        bool isPossible = false;
        if (option.overAmount > 0 && option.underAmount > 0) {
            isPossible = ((round.closePrice >
                _getStrikePrice(round.startPrice, _strike) &&
                orderInfo.position == Position.Over) ||
                (round.closePrice <
                    _getStrikePrice(round.startPrice, _strike) &&
                    orderInfo.position == Position.Under) ||
                (round.closePrice ==
                    _getStrikePrice(round.startPrice, _strike)));
        } else {
            // refund user's fund if there is no paticipation on the other side
            isPossible = true;
        }
        return
            round.oracleCalled &&
            orderInfo.amount != 0 &&
            !orderInfo.claimed &&
            !orderInfo.isCancelled &&
            isPossible;
    }

    function refundable(
        uint256 _epoch,
        uint8 _strike,
        Position _position,
        uint256 _idx,
        address _user
    ) public view returns (bool) {
        Round storage round = rounds[_epoch];
        uint256 refundAmt = 0;
        bool claimed = false;
        bool isCancelled = false;

        if (_idx > 0) {
            OrderInfo memory orderInfo = _getOrderInfoByIdx(
                _epoch,
                _strike,
                _position,
                _idx,
                _user
            );
            refundAmt += orderInfo.amount;
            claimed = orderInfo.claimed;
            isCancelled = orderInfo.isCancelled;
        } else {
            refundAmt = _getUndeclaredAmt(_epoch, _strike, _user);
        }

        return
            !round.oracleCalled &&
            !claimed &&
            !isCancelled &&
            block.timestamp > round.closeTimestamp + bufferSeconds &&
            refundAmt != 0;
    }

    function _getUndeclaredAmt(
        uint256 _epoch,
        uint8 _strike,
        address _user
    ) internal view returns (uint256) {
        uint256 amt = 0;
        Option storage option = rounds[_epoch].options[_strike];

        amt += option.overLimitOrders.getUndeclaredAmt(_user);
        amt += option.underLimitOrders.getUndeclaredAmt(_user);
        return amt;
    }

    function _calculateRewards(uint256 _epoch, uint8 _strike) internal {
        Round storage round = rounds[_epoch];
        Option storage option = round.options[_strike];
        require(
            option.rewardBaseCalAmount == 0 && option.rewardAmount == 0,
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
            if (round.closePrice > _getStrikePrice(round.startPrice, _strike)) {
                rewardBaseCalAmount = option.overAmount;
                treasuryAmt = (option.underAmount * commissionfee) / BASE;
                rewardAmount = option.underAmount - treasuryAmt;
            }
            // Under wins
            else if (
                round.closePrice < _getStrikePrice(round.startPrice, _strike)
            ) {
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
            _epoch,
            _strike,
            rewardBaseCalAmount,
            rewardAmount,
            treasuryAmt
        );
    }

    function _getStrikePrice(
        uint256 _price,
        uint8 _strike
    ) internal pure returns (uint256) {
        return (_price * uint256(_strike)) / 100;
    }

    function _safeEndRound(uint256 _epoch, uint256 _price) internal {
        require(rounds[_epoch].startTimestamp != 0, "E26");
        require(block.timestamp >= rounds[_epoch].closeTimestamp, "E27");
        require(
            block.timestamp <= rounds[_epoch].closeTimestamp + bufferSeconds,
            "E28"
        );
        rounds[_epoch].closePrice = uint256(_price);
        rounds[_epoch].oracleCalled = true;

        emit EndRound(_epoch, rounds[_epoch].closePrice);
    }

    function _safeStartRound(uint256 _epoch, uint256 _price) internal {
        require(rounds[_epoch].openTimestamp != 0, "E23");
        require(block.timestamp >= rounds[_epoch].startTimestamp, "E24");
        require(
            block.timestamp <= rounds[_epoch].startTimestamp + bufferSeconds,
            "E25"
        );
        rounds[_epoch].startPrice = _price;
        emit StartRound(_epoch, rounds[_epoch].startPrice);
    }

    function _safeOpenRound(uint256 _epoch, uint256 _initDate) internal {
        require(genesisOpenOnce, "E16");
        require(rounds[_epoch - 2].closeTimestamp != 0, "E17");
        require(block.timestamp >= rounds[_epoch - 2].closeTimestamp, "E18");
        require(block.timestamp >= _initDate, "E19");
        _openRound(_epoch, _initDate);
    }

    function _openRound(uint256 _epoch, uint256 _initDate) internal {
        rounds[_epoch].openTimestamp = _initDate;
        rounds[_epoch].startTimestamp = _initDate + intervalSeconds;
        rounds[_epoch].closeTimestamp = _initDate + (2 * intervalSeconds);
        rounds[_epoch].epoch = _epoch;

        for (uint i = 0; i < availableOptionStrikes.length; i++) {
            _initOption(_epoch, availableOptionStrikes[i]);
        }
        uint8[] memory strikes = availableOptionStrikes;
        emit OpenRound(
            _epoch,
            rounds[_epoch].openTimestamp,
            rounds[_epoch].startTimestamp,
            rounds[_epoch].closeTimestamp,
            strikes
        );
    }

    function _initOption(uint256 _epoch, uint8 _strike) internal {
        Round storage round = rounds[_epoch];
        round.availableOptions.push(_strike);
        round.options[_strike].strike = _strike;
        round.options[_strike].totalAmount = 0;
        round.options[_strike].overLimitOrders.initializeEmptyList();
        round.options[_strike].underLimitOrders.initializeEmptyList();
    }

    function _participable(uint256 _epoch) internal view returns (bool) {
        return
            rounds[_epoch].openTimestamp != 0 &&
            rounds[_epoch].startTimestamp != 0 &&
            block.timestamp > rounds[_epoch].openTimestamp &&
            block.timestamp < rounds[_epoch].startTimestamp;
    }

    function _placeOrder(
        uint256 _epoch,
        uint8 _strike,
        Position _position,
        address _user,
        uint256 _amount
    ) internal {
        Option storage option = rounds[_epoch].options[_strike];
        uint256 idx = _counters[_epoch][_position].nextId();

        option.ledgers[_user].push(
            OrderInfo(idx, _position, _amount, false, false)
        );
        option.totalAmount = option.totalAmount + _amount;
        if (_position == Position.Over) {
            option.overAmount = option.overAmount + _amount;
        } else {
            option.underAmount = option.underAmount + _amount;
        }
        emit PlaceMarketOrder(
            idx,
            _user,
            _epoch,
            _position,
            _strike,
            _amount,
            false,
            block.timestamp
        );
    }

    function placeLimitOrder(
        uint256 _epoch,
        uint8 _strike,
        uint256 _amount,
        Position _position,
        uint256 _payout,
        uint256 _prevIdx
    ) external whenNotPaused nonReentrant {
        require(_epoch == currentEpoch, "E07");
        require(_participable(_epoch), "E08");
        require(_amount >= DEFAULT_MIN_ORDER_AMOUNT, "E09");
        require(_payout > BASE, "E20");
        // require(overLimitOrders[epoch].length <= MAX_LIMIT_ORDERS, "E35");
        token.safeTransferFrom(msg.sender, address(this), _amount);

        Option storage option = rounds[_epoch].options[_strike];
        LimitOrderSet.Data storage limitOrders = _position == Position.Over
            ? option.overLimitOrders
            : option.underLimitOrders;
        uint256 idx = _counters[_epoch][_position].nextId();
        limitOrders.insert(
            LimitOrderSet.LimitOrder(
                idx,
                msg.sender,
                _payout,
                _amount,
                block.timestamp,
                LimitOrderSet.LimitOrderStatus.Undeclared
            ),
            _prevIdx
        );

        emit PlaceLimitOrder(
            idx,
            msg.sender,
            _epoch,
            _strike,
            _amount,
            _payout,
            block.timestamp,
            _position,
            LimitOrderSet.LimitOrderStatus.Undeclared
        );
    }

    function cancelLimitOrder(
        uint256 _epoch,
        uint256 _idx,
        uint8 _strike,
        Position _position
    ) external nonReentrant {
        require(rounds[_epoch].openTimestamp != 0, "E21");
        require(block.timestamp < rounds[_epoch].startTimestamp, "E22");

        LimitOrderSet.LimitOrder storage order;

        if (_position == Position.Over) {
            order = rounds[_epoch].options[_strike].overLimitOrders.orderMap[
                _idx
            ];
        } else {
            order = rounds[_epoch].options[_strike].underLimitOrders.orderMap[
                _idx
            ];
        }

        if (
            order.user == msg.sender &&
            order.status == LimitOrderSet.LimitOrderStatus.Undeclared
        ) {
            order.status = LimitOrderSet.LimitOrderStatus.Cancelled;
            if (order.amount > 0) {
                token.safeTransfer(msg.sender, order.amount);
            }
            emit PlaceLimitOrder(
                order.idx,
                msg.sender,
                _epoch,
                _strike,
                order.amount,
                order.payout,
                order.blockTimestamp,
                _position,
                LimitOrderSet.LimitOrderStatus.Cancelled
            );
        }
    }

    function _placeLimitOrders(uint256 _epoch, uint8 _strike) internal {
        Option storage option = rounds[_epoch].options[_strike];
        RoundAmount memory optionAmount = RoundAmount(
            option.totalAmount,
            option.overAmount,
            option.underAmount
        );

        bool applyPayout = false;
        LimitOrderSet.Data storage sortedOverLimitOrders = option
            .overLimitOrders;
        LimitOrderSet.Data storage sortedUnderLimitOrders = option
            .underLimitOrders;

        uint256 idx;
        do {
            // proc over limit orders
            idx = sortedOverLimitOrders.first();
            while (
                idx != LimitOrderSet.QUEUE_START &&
                idx != LimitOrderSet.QUEUE_END
            ) {
                LimitOrderSet.LimitOrder storage order = sortedOverLimitOrders
                    .orderMap[idx];

                uint expectedPayout = ((optionAmount.totalAmount + order.amount) * BASE) /
                    (optionAmount.overAmount + order.amount);
                if (
                    order.payout <= expectedPayout &&
                    order.status == LimitOrderSet.LimitOrderStatus.Undeclared
                ) {
                    optionAmount.totalAmount += order.amount;
                    optionAmount.overAmount += order.amount;
                    order.status = LimitOrderSet.LimitOrderStatus.Approve;
                }
                idx = sortedOverLimitOrders.next(idx);
            }

            applyPayout = false;

            // proc under limit orders
            idx = sortedUnderLimitOrders.first();
            while (
                idx != LimitOrderSet.QUEUE_START &&
                idx != LimitOrderSet.QUEUE_END
            ) {
                LimitOrderSet.LimitOrder storage order = sortedUnderLimitOrders
                    .orderMap[idx];

                uint expectedPayout = ((optionAmount.totalAmount + order.amount) * BASE) /
                    (optionAmount.underAmount + order.amount);
                if (
                    order.payout <= expectedPayout &&
                    order.status == LimitOrderSet.LimitOrderStatus.Undeclared
                ) {
                    optionAmount.totalAmount += order.amount;
                    optionAmount.underAmount += order.amount;
                    order.status = LimitOrderSet.LimitOrderStatus.Approve;
                    applyPayout = true;
                }
                idx = sortedUnderLimitOrders.next(idx);
            }
        } while (applyPayout);

        // proc over limit orders
        idx = sortedOverLimitOrders.first();
        while (
            idx != LimitOrderSet.QUEUE_START && idx != LimitOrderSet.QUEUE_END
        ) {
            LimitOrderSet.LimitOrder storage order = sortedOverLimitOrders
                .orderMap[idx];
            if (order.status == LimitOrderSet.LimitOrderStatus.Cancelled) {
                // do nothing
            } else if (
                order.status == LimitOrderSet.LimitOrderStatus.Undeclared
            ) {
                // refund ordered amount to user, change status to cancelled.
                order.status = LimitOrderSet.LimitOrderStatus.Cancelled;
                token.safeTransfer(order.user, order.amount);
                emit PlaceLimitOrder(
                    order.idx,
                    order.user,
                    _epoch,
                    _strike,
                    order.amount,
                    order.payout,
                    order.blockTimestamp,
                    Position.Over,
                    LimitOrderSet.LimitOrderStatus.Cancelled
                );
            } else if (order.status == LimitOrderSet.LimitOrderStatus.Approve) {
                _placeOrder(
                    _epoch,
                    _strike,
                    Position.Over,
                    order.user,
                    order.amount
                );
                emit PlaceLimitOrder(
                    order.idx,
                    order.user,
                    _epoch,
                    _strike,
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
        while (
            idx != LimitOrderSet.QUEUE_START && idx != LimitOrderSet.QUEUE_END
        ) {
            LimitOrderSet.LimitOrder storage order = sortedUnderLimitOrders
                .orderMap[idx];
            if (order.status == LimitOrderSet.LimitOrderStatus.Cancelled) {
                // do nothing
            } else if (
                order.status == LimitOrderSet.LimitOrderStatus.Undeclared
            ) {
                // refund ordered amount to user, change status to cancelled.
                order.status = LimitOrderSet.LimitOrderStatus.Cancelled;
                token.safeTransfer(order.user, order.amount);
                emit PlaceLimitOrder(
                    order.idx,
                    order.user,
                    _epoch,
                    _strike,
                    order.amount,
                    order.payout,
                    order.blockTimestamp,
                    Position.Under,
                    LimitOrderSet.LimitOrderStatus.Cancelled
                );
            } else if (order.status == LimitOrderSet.LimitOrderStatus.Approve) {
                _placeOrder(
                    _epoch,
                    _strike,
                    Position.Under,
                    order.user,
                    order.amount
                );
                emit PlaceLimitOrder(
                    order.idx,
                    order.user,
                    _epoch,
                    _strike,
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

    function _getOrderInfoByIdx(
        uint256 _epoch,
        uint8 _strike,
        Position _position,
        uint256 _idx,
        address _user
    ) internal view returns (OrderInfo storage) {
        Option storage option = rounds[_epoch].options[_strike];
        OrderInfo[] storage orderInfos = option.ledgers[_user];
        int selectedIdx = -1;

        for (uint i = 0; i < orderInfos.length; i++) {
            if (
                orderInfos[i].idx == _idx && orderInfos[i].position == _position
            ) {
                selectedIdx = int(i);
                break;
            }
        }
        require(selectedIdx > -1, "E03");
        return orderInfos[uint(selectedIdx)];
    }

    function viewAvailableOptionLength() external view returns (uint256) {
        return availableOptionStrikes.length;
    }

    function viewRound(
        uint256 _epoch
    ) external view returns (RoundResponse memory) {
        Round storage round = rounds[_epoch];
        OptionResponse[] memory options = new OptionResponse[](
            round.availableOptions.length
        );

        for (uint256 i = 0; i < round.availableOptions.length; i++) {
            options[i] = OptionResponse({
                strike: round.options[round.availableOptions[i]].strike,
                totalAmount: round
                    .options[round.availableOptions[i]]
                    .totalAmount,
                overAmount: round.options[round.availableOptions[i]].overAmount,
                underAmount: round
                    .options[round.availableOptions[i]]
                    .underAmount,
                rewardBaseCalAmount: round
                    .options[round.availableOptions[i]]
                    .rewardBaseCalAmount,
                rewardAmount: round
                    .options[round.availableOptions[i]]
                    .rewardAmount
            });
        }

        RoundResponse memory roundResponse = RoundResponse({
            epoch: round.epoch,
            openTimestamp: round.openTimestamp,
            startTimestamp: round.startTimestamp,
            closeTimestamp: round.closeTimestamp,
            startPrice: round.startPrice,
            closePrice: round.closePrice,
            startOracleId: round.startOracleId,
            closeOracleId: round.closeOracleId,
            oracleCalled: round.oracleCalled,
            intervalSeconds: intervalSeconds,
            bufferSeconds: bufferSeconds,
            options: options
        });
        return roundResponse;
    }

    function viewUserLedger(
        uint256 _epoch,
        uint8 _strike,
        address _user
    ) external view returns (OrderInfoResponse[] memory) {
        Round storage round = rounds[_epoch];
        OrderInfo[] memory orderInfos = round.options[_strike].ledgers[_user];
        uint256 size = orderInfos.length;

        OrderInfoResponse[] memory orderInfoResponse = new OrderInfoResponse[](
            size
        );
        for (uint256 j = 0; j < size; j++) {
            orderInfoResponse[j] = OrderInfoResponse(
                _strike,
                _epoch,
                orderInfos[j].idx,
                orderInfos[j].amount,
                orderInfos[j].position,
                orderInfos[j].claimed,
                orderInfos[j].isCancelled
            );
        }
        return orderInfoResponse;
    }
}
