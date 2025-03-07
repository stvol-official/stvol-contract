// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface ICommonErrors {
  // Common Errors shared across all contracts
  error InvalidAddress();
  error InvalidAmount();
  error InsufficientBalance();
  error Unauthorized();
  error InvalidTime();
  error OnlyAdmin();
  error OnlyOperator();
  error VaultCannotWithdraw();
}
