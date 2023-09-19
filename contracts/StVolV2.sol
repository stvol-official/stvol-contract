// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/**
 * @title StVolV2
 */
import "hardhat/console.sol";

contract StVolV2 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token; // Prediction token

    IPyth public oracle;

    bool public genesisOpenOnce = false;
    bool public genesisStartOnce = false;

    bytes32 public priceId; // address of the pyth price
    address public adminAddress; // address of the admin
    address public operatorAddress; // address of the operator
    address public keeperAddress; // address of the keeper
    address public participantVaultAddress; // address of the participant vault

    uint256 public bufferSeconds; // number of seconds for valid execution of a participate round
    uint256 public intervalSeconds; // interval in seconds between two participate rounds

    uint256 public minParticipateAmount; // minimum participate amount (denominated in wei)
    uint256 public commissionfee; // commission rate (e.g. 200 = 2%, 150 = 1.50%)
    uint256 public treasuryAmount; // treasury amount that was not claimed
    uint256 public operateRate; // operate distribute rate (e.g. 200 = 2%, 150 = 1.50%)
    uint256 public participantRate; // participant distribute rate (e.g. 200 = 2%, 150 = 1.50%)

    uint256 public currentEpoch; // current epoch for round

    uint256 public constant BASE = 10000; // 100%
    uint256 public constant MAX_COMMISSION_FEE = 200; // 2%

    mapping(uint256 => mapping(Position => mapping(address => ParticipateInfo)))
        public ledger;
    mapping(uint256 => Round) public rounds;
    mapping(address => uint256[]) public userRounds;

    enum Position {
        Over,
        Under
    }

    struct Round {
        uint256 epoch;
        uint256 openTimestamp;
        uint256 startTimestamp;
        uint256 closeTimestamp;
        int256 startPrice;
        int256 closePrice;
        uint256 startOracleId;
        uint256 closeOracleId;
        uint256 totalAmount;
        uint256 overAmount;
        uint256 underAmount;
        uint256 rewardBaseCalAmount;
        uint256 rewardAmount;
        bool oracleCalled;
    }

    struct ParticipateInfo {
        Position position;
        uint256 amount;
        bool claimed; // default false
    }

    event ParticipateUnder(
        address indexed sender,
        uint256 indexed epoch,
        uint256 amount
    );
    event ParticipateOver(
        address indexed sender,
        uint256 indexed epoch,
        uint256 amount
    );
    event Claim(address indexed sender, uint256 indexed epoch, Position position, uint256 amount);
    event EndRound(
        uint256 indexed epoch,
        int256 price
    );
    event StartRound(
        uint256 indexed epoch,
        int256 price
    );

    event NewAdminAddress(address admin);
    event NewBufferAndIntervalSeconds(
        uint256 bufferSeconds,
        uint256 intervalSeconds
    );
    event NewMinParticipateAmount(
        uint256 indexed epoch,
        uint256 minParticipateAmount
    );
    event NewCommissionfee(uint256 indexed epoch, uint256 commissionfee);
    event NewDistributeRate(uint256 operateRate, uint256 participantRate);
    event NewOperatorAddress(address operator);
    event NewOracle(address oracle);
    event NewKeeperAddress(address operator);
    event NewParticipantVaultAddress(address participantVault);

    event Pause(uint256 indexed epoch);
    event RewardsCalculated(
        uint256 indexed epoch,
        uint256 rewardBaseCalAmount,
        uint256 rewardAmount,
        uint256 treasuryAmount
    );

    event OpenRound(uint256 indexed epoch);
    event TokenRecovery(address indexed token, uint256 amount);
    event TreasuryClaim(uint256 amount);
    event Unpause(uint256 indexed epoch);

    modifier onlyAdmin() {
        require(msg.sender == adminAddress, "Not admin");
        _;
    }

    modifier onlyAdminOrOperatorOrKeeper() {
        require(
            msg.sender == adminAddress ||
                msg.sender == operatorAddress ||
                msg.sender == keeperAddress,
            "Not operator/admin/keeper"
        );
        _;
    }
    modifier onlyKeeperOrOperator() {
        require(
            msg.sender == keeperAddress || msg.sender == operatorAddress,
            "Not keeper/operator"
        );
        _;
    }
    modifier onlyOperator() {
        require(msg.sender == operatorAddress, "Not operator");
        _;
    }

    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    /**
     * @notice Constructor
     * @param _token: prediction token
     * @param _oracleAddress: oracle address
     * @param _adminAddress: admin address
     * @param _operatorAddress: operator address
     * @param _participantVaultAddress: participant vault address
     * @param _intervalSeconds: number of time within an interval
     * @param _bufferSeconds: buffer of time for resolution of price
     * @param _minParticipateAmount: minimum participate amounts (in wei)
     * @param _commissionfee: commission fee (1000 = 10%)
     * @param _operateRate: operate rate (3000 = 30%)
     * @param _participantRate: participant rate (7000 = 70%)
     * @param _priceId: pyth price address
     */
    constructor(
        IERC20 _token,
        address _oracleAddress,
        address _adminAddress,
        address _operatorAddress,
        address _participantVaultAddress,
        uint256 _intervalSeconds,
        uint256 _bufferSeconds,
        uint256 _minParticipateAmount,
        uint256 _commissionfee,
        uint256 _operateRate,
        uint256 _participantRate,
        bytes32 _priceId
    ) {
        require(
            _commissionfee <= MAX_COMMISSION_FEE,
            "Commission fee too high"
        );
        require(
            _operateRate + _participantRate == BASE,
            "Distribute total rate must be 10000 (100%)"
        );

        token = _token;
        oracle = IPyth(_oracleAddress);
        adminAddress = _adminAddress;
        operatorAddress = _operatorAddress;
        participantVaultAddress = _participantVaultAddress;
        intervalSeconds = _intervalSeconds;
        bufferSeconds = _bufferSeconds;
        minParticipateAmount = _minParticipateAmount;
        commissionfee = _commissionfee;
        operateRate = _operateRate;
        participantRate = _participantRate;
        priceId = _priceId;
    }

    /**
     * @notice Participate under position
     * @param epoch: epoch
     */
    function participateUnder(
        uint256 epoch,
        uint256 _amount
    ) external whenNotPaused nonReentrant notContract {
        require(epoch == currentEpoch, "Participate is too early/late");
        require(_participable(epoch), "Round not participable");
        require(
            _amount >= minParticipateAmount,
            "Participate amount must be greater than minParticipateAmount"
        );

        token.safeTransferFrom(msg.sender, address(this), _amount);
        // Update round data
        uint256 amount = _amount;
        Round storage round = rounds[epoch];
        round.totalAmount = round.totalAmount + amount;
        round.underAmount = round.underAmount + amount;

        // Update user data
        ParticipateInfo storage participateInfo = ledger[epoch][Position.Under][
            msg.sender
        ];
        participateInfo.position = Position.Under;
        participateInfo.amount = participateInfo.amount + amount;
        userRounds[msg.sender].push(epoch);

        emit ParticipateUnder(msg.sender, epoch, amount);
    }

    /**
     * @notice Participate over position
     * @param epoch: epoch
     */
    function participateOver(
        uint256 epoch,
        uint256 _amount
    ) external whenNotPaused nonReentrant notContract {
        require(epoch == currentEpoch, "Participate is too early/late");
        require(_participable(epoch), "Round not participable");
        require(
            _amount >= minParticipateAmount,
            "Participate amount must be greater than minParticipateAmount"
        );

        token.safeTransferFrom(msg.sender, address(this), _amount);
        // Update round data
        uint256 amount = _amount;
        Round storage round = rounds[epoch];
        round.totalAmount = round.totalAmount + amount;
        round.overAmount = round.overAmount + amount;

        // Update user data
        ParticipateInfo storage participateInfo = ledger[epoch][Position.Over][
            msg.sender
        ];
        participateInfo.position = Position.Over;
        participateInfo.amount = participateInfo.amount + amount;
        userRounds[msg.sender].push(epoch);

        emit ParticipateOver(msg.sender, epoch, amount);
    }

    /**
     * @notice Claim reward for an epoch
     * @param epoch: epoch
     */
    function claim(
        uint256 epoch,
        Position position
    ) external nonReentrant notContract {
        uint256 reward; // Initializes reward

        require(
            rounds[epoch].openTimestamp != 0,
            "Round has not started"
        );
        require(
            block.timestamp > rounds[epoch].closeTimestamp,
            "Round has not ended"
        );

        uint256 addedReward = 0;

        // Round valid, claim rewards
        if (rounds[epoch].oracleCalled) {
            require(
                claimable(epoch, position, msg.sender),
                "Not eligible for claim"
            );
            Round memory round = rounds[epoch];
            addedReward +=
                (ledger[epoch][position][msg.sender].amount *
                    round.rewardAmount) /
                round.rewardBaseCalAmount;
        } else {
            // Round invalid, refund Participate amount
            require(
                refundable(epoch, position, msg.sender),
                "Not eligible for refund"
            );
            addedReward += ledger[epoch][position][msg.sender].amount;
        }
        ledger[epoch][position][msg.sender].claimed = true;
        reward += addedReward;

        emit Claim(msg.sender, epoch, position, addedReward);

        if (reward > 0) {
            token.safeTransfer(msg.sender, reward);
        }
    }

    /**
     * @notice Open the next round n, lock price for round n-1, end round n-2
     * @dev Callable by operator
     */
    function executeRound(bytes[] calldata priceUpdateData) external payable whenNotPaused onlyKeeperOrOperator {
        require(
            genesisOpenOnce && genesisStartOnce,
            "Can only run after genesisOpenRound and genesisStartRound is triggered"
        );

        uint fee = oracle.getUpdateFee(priceUpdateData);
        oracle.updatePriceFeeds{ value: fee }(priceUpdateData);
        PythStructs.Price memory pythPrice = oracle.getPrice(priceId);

        // CurrentEpoch refers to previous round (n-1)
        _safeStartRound(currentEpoch, pythPrice.price);
        _safeEndRound(currentEpoch - 1, pythPrice.price);
        _calculateRewards(currentEpoch - 1);

        // Increment currentEpoch to current round (n)
        currentEpoch = currentEpoch + 1;
        _safeOpenRound(currentEpoch);
    }

    /**
     * @notice Start genesis round
     * @dev Callable by operator
     */
    function genesisStartRound(bytes[] calldata priceUpdateData) external payable whenNotPaused onlyKeeperOrOperator {
        require(
            genesisOpenOnce,
            "Can only run after genesisOpenRound is triggered"
        );
        require(!genesisStartOnce, "Can only run genesisStartRound once");

        uint fee = oracle.getUpdateFee(priceUpdateData);
        oracle.updatePriceFeeds{ value: fee }(priceUpdateData);
        PythStructs.Price memory pythPrice = oracle.getPrice(priceId);

        _safeStartRound(currentEpoch, pythPrice.price);

        currentEpoch = currentEpoch + 1;
        _openRound(currentEpoch);
        genesisStartOnce = true;
    }

    /**
     * @notice Open genesis round
     * @dev Callable by admin or operator
     */
    function genesisOpenRound() external whenNotPaused onlyKeeperOrOperator {
        require(!genesisOpenOnce, "Can only run genesisOpenRound once");

        currentEpoch = currentEpoch + 1;
        _openRound(currentEpoch);
        genesisOpenOnce = true;
    }

    /**
     * @notice called by the admin to pause, triggers stopped state
     * @dev Callable by admin or operator
     */
    function pause() external whenNotPaused onlyAdminOrOperatorOrKeeper {
        _pause();

        emit Pause(currentEpoch);
    }

    /**
     * @notice Claim all rewards in treasury
     * @dev Callable by admin
     */
    function claimTreasury() external nonReentrant onlyAdmin {
        uint256 currentTreasuryAmount = treasuryAmount;
        treasuryAmount = 0;
        
        // operator 30%, participant vault 70%
        token.safeTransfer(operatorAddress, (currentTreasuryAmount * operateRate) / BASE);
        token.safeTransfer(participantVaultAddress, (currentTreasuryAmount * participantRate) / BASE);

        emit TreasuryClaim(currentTreasuryAmount);
    }

    /**
     * @notice called by the admin to unpause, returns to normal state
     * Reset genesis state. Once paused, the rounds would need to be kickstarted by genesis
     * @dev Callable by admin or operator or keeper
     */
    function unpause() external whenPaused onlyAdminOrOperatorOrKeeper {
        genesisOpenOnce = false;
        genesisStartOnce = false;
        _unpause();

        emit Unpause(currentEpoch);
    }

    /**
     * @notice Set buffer and interval (in seconds)
     * @dev Callable by admin
     */
    function setBufferAndIntervalSeconds(
        uint256 _bufferSeconds,
        uint256 _intervalSeconds
    ) external whenPaused onlyAdmin {
        require(
            _bufferSeconds < _intervalSeconds,
            "bufferSeconds must be inferior to intervalSeconds"
        );
        bufferSeconds = _bufferSeconds;
        intervalSeconds = _intervalSeconds;

        emit NewBufferAndIntervalSeconds(_bufferSeconds, _intervalSeconds);
    }

    /**
     * @notice Set minParticipateAmount
     * @dev Callable by admin
     */
    function setMinParticipateAmount(
        uint256 _minParticipateAmount
    ) external whenPaused onlyAdmin {
        require(_minParticipateAmount != 0, "Must be superior to 0");
        minParticipateAmount = _minParticipateAmount;

        emit NewMinParticipateAmount(currentEpoch, minParticipateAmount);
    }

    /**
     * @notice Set operator address
     * @dev Callable by admin
     */
    function setOperator(address _operatorAddress) external onlyAdmin {
        require(_operatorAddress != address(0), "Cannot be zero address");
        operatorAddress = _operatorAddress;

        emit NewOperatorAddress(_operatorAddress);
    }

    /**
     * @notice Set keeper address
     * @dev Callable by admin
     */
    function setKeeper(address _keeperAddress) external onlyAdmin {
        require(_keeperAddress != address(0), "Cannot be zero address");
        keeperAddress = _keeperAddress;

        emit NewKeeperAddress(_keeperAddress);
    }

    /**
     * @notice Set participant vault address
     * @dev Callable by admin
     */
    function setParticipantVault(
        address _participantVaultAddress
    ) external onlyAdmin {
        require(
            _participantVaultAddress != address(0),
            "Cannot be zero address"
        );
        participantVaultAddress = _participantVaultAddress;

        emit NewParticipantVaultAddress(_participantVaultAddress);
    }

    /**
     * @notice Set Oracle address
     * @dev Callable by admin
     */
    function setOracle(address _oracle) external whenPaused onlyAdmin {
        require(_oracle != address(0), "Cannot be zero address");
        oracle = IPyth(_oracle);

        emit NewOracle(_oracle);
    }


    /**
     * @notice Set treasury fee
     * @dev Callable by admin
     */
    function setCommissionfee(
        uint256 _commissionfee
    ) external whenPaused onlyAdmin {
        require(
            _commissionfee <= MAX_COMMISSION_FEE,
            "Commission fee too high"
        );
        commissionfee = _commissionfee;

        emit NewCommissionfee(currentEpoch, commissionfee);
    }

    /**
     * @notice Set distribute rate
     * @dev Callable by admin
     */
    function setDistributeRate(
        uint256 _operateRate,
        uint256 _participantRate
    ) external whenPaused onlyAdmin {
        require(
            _operateRate + _participantRate == BASE,
            "Distribute total rate must be 10000 (100%)"
        );
        operateRate = _operateRate;

        participantRate = _participantRate;

        emit NewDistributeRate(operateRate, participantRate);
    }

    /**
     * @notice It allows the owner to recover tokens sent to the contract by mistake
     * @param _token: token address
     * @param _amount: token amount
     * @dev Callable by owner
     */
    function recoverToken(address _token, uint256 _amount) external onlyOwner {
        require(_token != address(token), "Cannot be prediction token address");
        IERC20(_token).safeTransfer(address(msg.sender), _amount);

        emit TokenRecovery(_token, _amount);
    }

    /**
     * @notice Set admin address
     * @dev Callable by owner
     */
    function setAdmin(address _adminAddress) external onlyOwner {
        require(_adminAddress != address(0), "Cannot be zero address");
        adminAddress = _adminAddress;

        emit NewAdminAddress(_adminAddress);
    }

    /**
     * @notice Returns round epochs and participate information for a user that has participated
     * @param user: user address
     * @param cursor: cursor
     * @param size: size
     */
    function getUserRounds(
        address user,
        uint256 cursor,
        uint256 size
    )
        external
        view
        returns (
            uint256[] memory,
            ParticipateInfo[] memory,
            ParticipateInfo[] memory,
            uint256
        )
    {
        uint256 length = size;

        if (length > userRounds[user].length - cursor) {
            length = userRounds[user].length - cursor;
        }

        uint256[] memory values = new uint256[](length);
        ParticipateInfo[] memory overParticipateInfo = new ParticipateInfo[](
            length
        );
        ParticipateInfo[] memory underParticipateInfo = new ParticipateInfo[](
            length
        );

        for (uint256 i = 0; i < length; i++) {
            values[i] = userRounds[user][cursor + i];
            for (uint8 j = 0; j < 2; j++) {
                Position p = (j == 0) ? Position.Over : Position.Under;
                if (p == Position.Over) {
                    overParticipateInfo[i] = ledger[values[i]][p][user];
                } else {
                    underParticipateInfo[i] = ledger[values[i]][p][user];
                }
            }
        }

        return (
            values,
            overParticipateInfo,
            underParticipateInfo,
            cursor + length
        );
    }

    /**
     * @notice Returns round epochs length
     * @param user: user address
     */
    function getUserRoundsLength(address user) external view returns (uint256) {
        return userRounds[user].length;
    }

    /**
     * @notice Get the claimable stats of specific epoch and user account
     * @param epoch: epoch
     * @param position: Position
     * @param user: user address
     */
    function claimable(
        uint256 epoch,
        Position position,
        address user
    ) public view returns (bool) {
        ParticipateInfo memory participateInfo = ledger[epoch][position][user];
        Round memory round = rounds[epoch];

        return
            round.oracleCalled &&
            participateInfo.amount != 0 &&
            !participateInfo.claimed &&
            (
                (round.closePrice > round.startPrice && participateInfo.position == Position.Over) 
                ||
                (round.closePrice < round.startPrice && participateInfo.position == Position.Under)
                ||
                (round.closePrice == round.startPrice && (participateInfo.position == Position.Over || participateInfo.position == Position.Under))
            );
    }

    /**
     * @notice Get the refundable stats of specific epoch and user account
     * @param epoch: epoch
     * @param user: user address
     */
    function refundable(
        uint256 epoch,
        Position position,
        address user
    ) public view returns (bool) {
        ParticipateInfo memory participateInfo = ledger[epoch][position][user];
        Round memory round = rounds[epoch];
        return
            !round.oracleCalled &&
            !participateInfo.claimed &&
            block.timestamp > round.closeTimestamp + bufferSeconds &&
            participateInfo.amount != 0;
    }

    /**
     * @notice Calculate rewards for round
     * @param epoch: epoch
     */
    function _calculateRewards(uint256 epoch) internal {
        require(
            rounds[epoch].rewardBaseCalAmount == 0 &&
                rounds[epoch].rewardAmount == 0,
            "Rewards calculated"
        );
        Round storage round = rounds[epoch];
        uint256 rewardBaseCalAmount;
        uint256 treasuryAmt;
        uint256 rewardAmount;

        // Over wins
        if (round.closePrice > round.startPrice) {
            rewardBaseCalAmount = round.overAmount;
            treasuryAmt = (round.underAmount * commissionfee) / BASE;
            rewardAmount = round.totalAmount - treasuryAmt;
        }
        // Under wins
        else if (round.closePrice < round.startPrice) {
            rewardBaseCalAmount = round.underAmount;
            treasuryAmt = (round.overAmount * commissionfee) / BASE;
            rewardAmount = round.totalAmount - treasuryAmt;
        }
        // No one wins refund participant amount to users
        else {
            rewardBaseCalAmount = round.totalAmount;
            rewardAmount = round.totalAmount;
            treasuryAmt = 0;
        }
        round.rewardBaseCalAmount = rewardBaseCalAmount;
        round.rewardAmount = rewardAmount;

        // Add to treasury
        treasuryAmount += treasuryAmt;

        emit RewardsCalculated(
            epoch,
            rewardBaseCalAmount,
            rewardAmount,
            treasuryAmt
        );
    }

    /**
     * @notice End round
     * @param epoch: epoch
     * @param price: price of the round
     */
    function _safeEndRound(
        uint256 epoch,
        int256 price
    ) internal {
        require(
            rounds[epoch].startTimestamp != 0,
            "Can only end round after round has locked"
        );
        require(
            block.timestamp >= rounds[epoch].closeTimestamp,
            "Can only end round after closeTimestamp"
        );
        require(
            block.timestamp <= rounds[epoch].closeTimestamp + bufferSeconds,
            "Can only end round within bufferSeconds"
        );
        Round storage round = rounds[epoch];
        round.closePrice = price;
        round.oracleCalled = true;

        emit EndRound(epoch, round.closePrice);
    }

    /**
     * @notice Start round
     * @param epoch: epoch
     * @param price: price of the round
     */
    function _safeStartRound(
        uint256 epoch,
        int256 price
    ) internal {
        require(
            rounds[epoch].openTimestamp != 0,
            "Can only lock round after round has started"
        );
        require(
            block.timestamp >= rounds[epoch].startTimestamp,
            "Can only start round after startTimestamp"
        );
        require(
            block.timestamp <= rounds[epoch].startTimestamp + bufferSeconds,
            "Can only start round within bufferSeconds"
        );
        Round storage round = rounds[epoch];
        round.closeTimestamp = block.timestamp + intervalSeconds;
        round.startPrice = price;

        emit StartRound(epoch, round.startPrice);
    }

    /**
     * @notice Open round
     * Previous round n-2 must end
     * @param epoch: epoch
     */
    function _safeOpenRound(uint256 epoch) internal {
        require(
            genesisOpenOnce,
            "Can only run after genesisOpenRound is triggered"
        );
        require(
            rounds[epoch - 2].closeTimestamp != 0,
            "Can only open round after round n-2 has ended"
        );
        require(
            block.timestamp >= rounds[epoch - 2].closeTimestamp,
            "Can only open new round after round n-2 closeTimestamp"
        );
        _openRound(epoch);
    }

    /**
     * @notice Start round
     * Previous round n-2 must end
     * @param epoch: epoch
     */
    function _openRound(uint256 epoch) internal {
        Round storage round = rounds[epoch];
        round.openTimestamp = block.timestamp;
        round.startTimestamp = block.timestamp + intervalSeconds;
        round.closeTimestamp = block.timestamp + (2 * intervalSeconds);
        round.epoch = epoch;
        round.totalAmount = 0;

        emit OpenRound(epoch);
    }

    /**
     * @notice Determine if a round is valid for receiving bets
     * Round must have started and locked
     * Current timestamp must be within openTimestamp and closeTimestamp
     */
    function _participable(uint256 epoch) internal view returns (bool) {
        return
            rounds[epoch].openTimestamp != 0 &&
            rounds[epoch].startTimestamp != 0 &&
            block.timestamp > rounds[epoch].openTimestamp &&
            block.timestamp < rounds[epoch].startTimestamp;
    }

    /**
     * @notice Get latest recorded price from oracle
     * If it falls below allowed buffer or has not updated, it would be invalid.
     */
    // function _getPriceFromOracle(bytes[] calldata priceUpdateData) public payable returns (PythStructs.Price memory) {
    //     uint fee = oracle.getUpdateFee(priceUpdateData);
    //     oracle.updatePriceFeeds{ value: fee }(priceUpdateData);
    //     return oracle.getPrice(priceId);
    // }

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

    event TestEvent(uint256 data);
}