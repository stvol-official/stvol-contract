// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { VaultStorage } from "./storage/VaultStorage.sol";

import {
    VaultInfo,
    VaultMember,
    VaultSnapshot
} from "./Types.sol";

contract Vault is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint256 private constant BASE = 10000; // 100%
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    error InvalidAmount();
    error InsufficientBalance();
    error InvalidAddress();
    error VaultNotFound();
    error VaultAlreadyClosed();
    error NonZeroBalance();
    error Unauthorized();
    error VaultAlreadyExists();
    error InvalidLeaderAddress();
    error InvalidVaultAddress();
    error LeaderCannotBeVault();    
    error CannotWithdrawFromNonExistentMember();
    error VaultBalanceIsZero();

    event VaultTransaction(
        address indexed vault,
        address indexed user,
        uint256 amount,
        bool isDeposit
    );
    event VaultCreated(address indexed vault, address indexed leader, uint256 sharePercentage);
    event DepositToVault(address indexed vault, address indexed user, uint256 amount);
    event WithdrawFromVault(address indexed vault, address indexed user, uint256 amount, uint256 profitShare);
    event VaultTransactionProcessed(uint256 indexed orderIdx, address indexed vault, address indexed member, uint256 memberBalance, uint256 memberShare, bool isWin);
    event VaultClosed(address indexed vault, address indexed leader);
    event VaultTransactionProcessedBatch(
        uint256 indexed orderIdx,
        address indexed vault,
        uint256 vaultBalance,
        address[] users,
        uint256[] balances,
        uint256[] shares,
        bool isWin
    );

    modifier onlyAdmin() {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        require(msg.sender == $.adminAddress, "onlyAdmin");
        _;
    }

    modifier onlyOperator() {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        require(msg.sender == $.operatorAddress, "onlyOperator");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _adminAddress,
        address _operatorAddress
    ) public initializer {
        require(_adminAddress != address(0), "Invalid admin address");
        require(_operatorAddress != address(0), "Invalid operator address");
        
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();

        VaultStorage.Layout storage $ = VaultStorage.layout();
        $.adminAddress = _adminAddress;
        $.operatorAddress = _operatorAddress;
    }

    function createVault(address vault, address leader, uint256 sharePercentage) external nonReentrant onlyOperator {
        if (sharePercentage > BASE) revert InvalidAmount();
        if (isVault(leader)) revert InvalidLeaderAddress();
        if (isVault(vault)) revert VaultAlreadyExists();
        if (leader == address(0)) revert InvalidLeaderAddress();
        if (vault == address(0)) revert InvalidVaultAddress();
        if (leader == vault) revert LeaderCannotBeVault();

        VaultStorage.Layout storage $ = VaultStorage.layout();
        VaultInfo storage vaultInfo = $.vaults[vault];
        if (vaultInfo.vault != address(0)) revert VaultAlreadyExists();

        vaultInfo.vault = vault;
        vaultInfo.leader = leader;
        vaultInfo.balance = 0;
        vaultInfo.profitShare = sharePercentage;
        vaultInfo.closed = false;
        vaultInfo.created = block.timestamp;
        $.vaultMembers[vault].push(VaultMember({
            vault: vault,
            user: leader,
            balance: 0,
            created: block.timestamp
        })); 

        emit VaultCreated(vault, leader, sharePercentage);
    } 

    function closeVault(address vault, address leader) external nonReentrant onlyOperator {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        VaultInfo storage vaultInfo = $.vaults[vault];
        if (vaultInfo.vault == address(0)) revert VaultNotFound();
        if (vaultInfo.leader != leader) revert Unauthorized();
        if (vaultInfo.closed) revert VaultAlreadyClosed();
        if (vaultInfo.balance != 0) revert NonZeroBalance();

        vaultInfo.closed = true;
        emit VaultClosed(vault, leader);
    } 

    function depositToVault(address vault, address user, uint256 amount) external nonReentrant onlyOperator returns (uint256) {
        VaultInfo storage vaultInfo = _validateVaultOperation(vault, amount, false);
        if (isVault(user)) revert Unauthorized();

        vaultInfo.balance += amount;
        _updateVaultMemberBalance(vault, user, amount, true);
        
        emit VaultTransaction(vault, user, amount, true);
        return amount;
    }

    function withdrawFromVault(address vault, address user, uint256 amount) external nonReentrant onlyOperator returns (uint256) {
        VaultInfo storage vaultInfo = _validateVaultOperation(vault, amount, true);
        if (isVault(user) || !isVaultMember(vault, user)) revert Unauthorized();

        uint256 memberShare;
        uint256 leaderShare;
        
        if (user == vaultInfo.leader) {
            memberShare = amount;
        } else {
            leaderShare = (amount * vaultInfo.profitShare) / BASE;
            memberShare = amount - leaderShare;
        }

        vaultInfo.balance -= memberShare;
        if (user != vaultInfo.leader) {
            _updateVaultMemberBalance(vault, vaultInfo.leader, leaderShare, true);
        }
        _updateVaultMemberBalance(vault, user, memberShare, false);
        
        emit VaultTransaction(vault, user, amount, false);
        return memberShare;
    }

    function processVaultTransaction(uint256 orderIdx, address vault, uint256 amount, bool isWin) external nonReentrant onlyOperator {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        VaultInfo storage vaultInfo = $.vaults[vault];
        if (vaultInfo.balance == 0) revert VaultBalanceIsZero();
        
        VaultSnapshot storage snapshot = $.orderVaultSnapshots[orderIdx];
        VaultMember[] storage members = $.vaultMembers[vault];

        // Prepare arrays to store batch data
        address[] memory users = new address[](members.length);
        uint256[] memory balances = new uint256[](members.length);
        uint256[] memory shares = new uint256[](members.length);

        // Calculate each member's share from the total vault balance and distribute the amount
        for (uint i = 0; i < members.length; i++) {
            VaultMember storage member = members[i];
            uint256 memberShare = (member.balance * amount) / vaultInfo.balance;
            member.balance = isWin ? member.balance + memberShare : member.balance - memberShare;
            snapshot.members.push(VaultMember({
                vault: vault,
                user: member.user,
                balance: member.balance,
                created: member.created
            }));

            // Store data for batch event
            users[i] = member.user;
            balances[i] = member.balance;
            shares[i] = memberShare;
        }
        vaultInfo.balance = isWin ? vaultInfo.balance + amount : vaultInfo.balance - amount;

        // Emit a single event with batch data
        emit VaultTransactionProcessedBatch(orderIdx, vault, vaultInfo.balance, users, balances, shares, isWin);
    }

    function _updateVaultMemberBalance(address vault, address user, uint256 amount, bool isDeposit) internal {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        VaultMember[] storage members = $.vaultMembers[vault];
        bool found = false;
        for (uint i = 0; i < members.length; i++) {
            if (members[i].user == user) {
                if (isDeposit) {
                    members[i].balance += amount;
                } else {
                    if (members[i].balance < amount) revert InsufficientBalance();
                    members[i].balance -= amount;
                }
                found = true;
                break;
            }
        }
        if (!found) {
            if (!isDeposit) revert CannotWithdrawFromNonExistentMember();
            $.vaultMembers[vault].push(VaultMember({
                vault: vault,
                user: user,
                balance: amount,
                created: block.timestamp
            }));
        }
    }

    function pause() external whenNotPaused onlyAdmin {
        _pause();
    }

    function unpause() external whenPaused onlyAdmin {
        _unpause();
    }

    function setAdmin(address _adminAddress) external onlyOwner {
        if (_adminAddress == address(0)) revert InvalidAddress();
        VaultStorage.Layout storage $ = VaultStorage.layout();
        $.adminAddress = _adminAddress;
    }

    function setOperator(address _operatorAddress) external onlyAdmin {
        if (_operatorAddress == address(0)) revert InvalidAddress();
        VaultStorage.Layout storage $ = VaultStorage.layout();
        $.operatorAddress = _operatorAddress;
    }

    /* public views */
    function isVault(address vault) public view returns (bool) {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        return $.vaults[vault].vault != address(0);
    } 

    function isVaultMember(address vault, address user) public view returns (bool) {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        VaultMember[] storage members = $.vaultMembers[vault];
        for (uint i = 0; i < members.length; i++) {
            if (members[i].user == user) {
                return true;
            }
        }
        return false;
    }

    function addresses() public view returns (address, address) {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        return ($.adminAddress, $.operatorAddress);
    }

    function getVaultInfo(address vault) public view returns (VaultInfo memory) {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        return $.vaults[vault];
    } 

    function getVaultMembers(address vault) external view returns (VaultMember[] memory) {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        return $.vaultMembers[vault];
    }

    function getVaultSnapshot(uint256 orderIdx) internal view returns (VaultSnapshot memory) {
        VaultStorage.Layout storage $ = VaultStorage.layout();
        return $.orderVaultSnapshots[orderIdx];
    }

    /* internal functions */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _validateVaultOperation(
        address vault,
        uint256 amount,
        bool checkBalance
    ) internal view returns (VaultInfo storage vaultInfo) {
        if (amount == 0) revert InvalidAmount();
        
        vaultInfo = VaultStorage.layout().vaults[vault];
        if (vaultInfo.vault == address(0)) revert VaultNotFound();
        if (vaultInfo.closed) revert VaultAlreadyClosed();
        if (checkBalance && vaultInfo.balance < amount) revert InsufficientBalance();
    }
}
