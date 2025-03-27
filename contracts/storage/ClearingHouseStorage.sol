// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IVaultManager.sol";
import { WithdrawalRequest, Coupon, ForceWithdrawalRequest, CouponUsageDetail, Product } from "../types/Types.sol";

library ClearingHouseStorage {
  // keccak256(abi.encode(uint256(keccak256("io.supervol.storage.clearinghouse")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0x8813a153063d7fe54e4155b960ce0bcfaac345da276d07e649f6c356f4752100;

  struct Layout {
    IERC20 token; // Prediction token
    address adminAddress; // Admin address
    address operatorVaultAddress; // Operator vault address
    mapping(address => bool) operators; // Operators
    mapping(address => uint256) userBalances; // User balances
    uint256 treasuryAmount; // Treasury amount
    WithdrawalRequest[] withdrawalRequests; // Withdrawal requests
    address[] operatorList; // List of operators
    ForceWithdrawalRequest[] forceWithdrawalRequests;
    uint256 forceWithdrawalDelay;
    IVaultManager vaultManager;
    mapping(address => Coupon[]) couponBalances; // user to coupon list
    uint256 couponAmount; // coupon amount
    uint256 usedCouponAmount; // used coupon amount
    address[] couponHolders;
    uint256 withdrawalFee; // withdrawal fee
    mapping(uint256 => bool) processedBatchIds; // processed batch ids
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) escrowBalances; // [DEPRECATED] epoch => user => idx => amount
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) escrowCoupons; // [DEPRECATED] epoch => user => idx => amount
    mapping(address => mapping(uint256 => CouponUsageDetail[])) couponUsageHistory; // user => epoch => CouponUsageDetail[]
    mapping(address => mapping(uint256 => mapping(address => mapping(uint256 => uint256)))) productEscrowBalances; // product => epoch => user => idx => amount
    mapping(address => mapping(uint256 => mapping(address => mapping(uint256 => uint256)))) productEscrowCoupons; // product => epoch => user => idx => amount
    mapping(address => Product) products; // product => Product
    address[] productAddresses; // product addresses
    /* IMPROTANT: you can add new variables here */
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
