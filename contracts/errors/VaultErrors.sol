// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import { ICommonErrors } from "./CommonErrors.sol";

interface IVaultErrors is ICommonErrors {
    error VaultSpecificError();
    error InvalidVaultOperation();
    error VaultNotFound();
    error VaultAlreadyClosed();
    error NonZeroBalance();
    error VaultAlreadyExists();
    error InvalidLeaderAddress();
    error InvalidVaultAddress();
    error LeaderCannotBeVault();
    error CannotWithdrawFromNonExistentMember();
    error VaultBalanceIsZero();
    error VaultCannotDeposit();
} 