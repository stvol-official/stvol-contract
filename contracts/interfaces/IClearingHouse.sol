// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { WithdrawalRequest } from "../types/Types.sol";

interface IClearingHouse {
  // Events
  event Deposit(address indexed to, address from, uint256 amount, uint256 result);
  event Withdraw(address indexed to, uint256 amount, uint256 result);
  event WithdrawalRequested(address indexed user, uint256 amount);
  event WithdrawalApproved(address indexed user, uint256 amount);
  event WithdrawalRejected(address indexed user, uint256 amount);

  // External Functions
  function initialize(
    address _usdcAddress,
    address _adminAddress,
    address _operatorAddress,
    address _vaultAddress
  ) external;
  function addTreasuryAmount(uint256 amount) external;
  function addUserBalance(address user, uint256 amount) external;
  function approveWithdrawal(uint256 idx) external;
  function claimTreasury(address operatorVaultAddress) external;
  function deposit(address user, uint256 amount) external;
  function depositTo(address from, address to, uint256 amount) external;
  function forceWithdrawAll(address user) external;
  function getWithdrawalRequests(uint256 from) external view returns (WithdrawalRequest[] memory);
  function rejectWithdrawal(uint256 idx, string calldata reason) external;
  function requestWithdrawal(
    address user,
    uint256 amount
  ) external returns (WithdrawalRequest memory);
  function treasuryAmount() external view returns (uint256);
  function userBalances(address user) external view returns (uint256);
  function withdraw(address user, uint256 amount) external;
  function pause() external;
  function unpause() external;
  function setOperatorVault(address _operatorVaultAddress) external;
  function setAdmin(address _adminAddress) external;
  function transferBalance(address from, address to, uint256 amount) external;
  function subtractUserBalance(address user, uint256 amount) external;
  function addOperator(address operator) external;
  function removeOperator(address operator) external;
  function useCoupon(address user, uint256 amount, uint256 epoch) external returns (uint256);
  function couponBalanceOf(address user) external view returns (uint256);
  function depositCouponTo(address user, uint256 amount, uint256 expirationEpoch) external;
  function lockInEscrow(address user, uint256 amount, uint256 epoch, uint256 idx) external;
  function releaseFromEscrow(
    address user,
    uint256 epoch,
    uint256 idx,
    uint256 amount,
    uint256 fee
  ) external;
  function settleEscrowWithFee(
    address from,
    address to,
    uint256 epoch,
    uint256 amount,
    uint256 idx,
    uint256 feeRate
  ) external;
  function escrowCoupons(address user, uint256 epoch, uint256 idx) external view returns (uint256);
}
