// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVault } from "../interfaces/IVault.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { Round, FilledOrder, SettlementResult, WithdrawalRequest, Coupon } from "../types/Types.sol";

library SuperVolStorage {
  // keccak256(abi.encode(uint256(keccak256("io.supervol.storage.main")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0xd15519bf3d12b1a27d33627290ce45a5eea6d098db2fbf692f01e59852393900;

  struct Layout {
    IERC20 token; // Prediction token
    IPyth oracle;
    IVault vault;
    IClearingHouse clearingHouse;
    address adminAddress; // address of the admin
    address operatorAddress; // address of the operator
    uint256 commissionfee; // commission rate (e.g. 200 = 2%, 150 = 1.50%)
    mapping(uint256 => Round) rounds;
    mapping(uint256 => FilledOrder[]) filledOrders; // key: epoch
    uint256 lastFilledOrderId;
    uint256 lastSubmissionTime;
    uint256 lastSettledFilledOrderId; // globally
    mapping(uint256 => uint256) lastSettledFilledOrderIndex; // by round(epoch)
    mapping(address => Coupon[]) couponBalances; // user to coupon list
    uint256 couponAmount; // coupon vault
    uint256 usedCouponAmount; // coupon vault
    address[] couponHolders;
    mapping(uint256 => SettlementResult) settlementResults; // key: filled order idx
    mapping(address => bool) migratedHolders;
    uint256 migratedHoldersCount;
    mapping(uint256 => mapping(address => uint256)) escrowBalances; // epoch => user => amount
    mapping(uint256 => mapping(address => uint256)) escrowCoupons; // epoch => user => amount
    /* IMPROTANT: you can add new variables here */
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
