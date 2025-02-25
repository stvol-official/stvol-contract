// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import { ICommonErrors } from "./CommonErrors.sol";

interface ISuperVolErrors is ICommonErrors {
  error InvalidCommissionFee();
  error VaultCannotDeposit();
  error VaultCannotWithdraw();
  error InvalidId();
  error InvalidTokenAddress();
  error InvalidInitDate();
  error InvalidRound();
  error InvalidRoundPrice();
  error EpochHasNotStartedYet();
  error InvalidEpoch();
  error InvalidIndex();
  error PriceLengthMismatch();
  error InsufficientBalance(address user, uint256 available, uint256 required);
}
