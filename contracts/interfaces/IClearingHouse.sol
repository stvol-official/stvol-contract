// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { WithdrawalRequest, Coupon } from "../Types.sol";

interface IClearingHouse {
    function deposit(address user, uint256 amount) external;
    function withdraw(address user, uint256 amount) external;
    function userBalances(address user) external view returns (uint256);
    function requestWithdrawal(address user, uint256 amount) external returns (WithdrawalRequest memory);
    function getWithdrawalRequests(uint256 from) external view returns (WithdrawalRequest[] memory);
    function approveWithdrawal(uint256 idx) external;
    function rejectWithdrawal(uint256 idx, string calldata reason) external;
    function forceWithdrawAll(address user) external;
    function claimTreasury(address operatorVaultAddress) external;
    function treasuryAmount() external view returns (uint256);
    function depositCouponTo(address user, uint256 amount, uint256 expirationEpoch) external;
    function couponBalanceOf(address user) external view returns (uint256);
    function couponHolders() external view returns (address[] memory);
    function userCoupons(address user) external view returns (Coupon[] memory);
    function depositTo(address from, address to, uint256 amount) external;
} 