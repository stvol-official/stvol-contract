// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import {VaultInfo} from "../Types.sol";

interface IVault {
    // Events
    event VaultTransaction(
        address indexed vault,
        address indexed user,
        uint256 amount,
        bool isDeposit
    );
    event VaultCreated(address indexed vault, address indexed leader, uint256 sharePercentage);
    event DepositToVault(address indexed vault, address indexed user, uint256 amount);
    event WithdrawFromVault(address indexed vault, address indexed user, uint256 amount, uint256 profitShare);
    event VaultTransactionProcessedBatch(uint256 indexed orderIdx, address indexed vault, uint256 vaultBalance, address[] users, uint256[] balances, uint256[] shares, bool isWin);


    // Errors
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

    // External Functions
    function initialize(address _adminAddress, address _operatorAddress) external;
    function createVault(address vault, address leader, uint256 sharePercentage) external;
    function closeVault(address vault, address leader) external;
    function depositToVault(address vault, address user, uint256 amount) external returns (uint256);
    function withdrawFromVault(address vault, address user, uint256 amount) external returns (uint256);
    function pause() external;
    function unpause() external;
    function setOperator(address _operatorAddress) external;
    function setAdmin(address _adminAddress) external;
    function processVaultTransaction(uint256 orderIdx, address vault, uint256 amount, bool isWin) external;

    // View Functions
    function isVault(address vault) external view returns (bool);
    function isVaultMember(address vault, address user) external view returns (bool);
    function addresses() external view returns (address, address);
    function getVaultInfo(address vault) external view returns (VaultInfo memory);
} 