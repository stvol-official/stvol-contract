// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface ICommonErrors {
    // Common Errors
    error InvalidAddress();
    error InvalidAmount();
    error InsufficientBalance();
    error Unauthorized();
    error InvalidTime();
    error InvalidIdx();
    error RequestAlreadyProcessed();
    error OnlyAdmin();
    error OnlyOperator();

    // ClearingHouse Errors
    error ClearingHouseSpecificError();
    error InvalidSettlement();
    error InvalidCommissionFee();
    error InvalidInitDate();
    error InvalidTokenAddress();
    error InvalidRound();
    error InvalidRoundPrice();
    error InvalidId();
    error EpochHasNotStartedYet();
    error InvalidEpoch();

    // Vault Errors
    error VaultSpecificError();
    error InvalidVaultOperation();
    error VaultCannotDeposit();
    error VaultCannotWithdraw();
    error VaultNotFound();
    error VaultAlreadyClosed();
    error NonZeroBalance();
    error VaultAlreadyExists();
    error InvalidLeaderAddress();
    error InvalidVaultAddress();
    error LeaderCannotBeVault();
    error CannotWithdrawFromNonExistentMember();
    error VaultBalanceIsZero();
} 