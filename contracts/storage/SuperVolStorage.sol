// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { IVault } from "../interfaces/IVault.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import {
    Round,
    FilledOrder,
    SettlementResult,
    WithdrawalRequest,
    Coupon  
} from "../Types.sol";

library SuperVolStorage {
    // keccak256(abi.encode(uint256(keccak256("io.supervol.storage.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 internal constant SLOT =
        0xd15519bf3d12b1a27d33627290ce45a5eea6d098db2fbf692f01e59852393900;

    struct Layout {
        IERC20 token; // Prediction token
        IPyth oracle;
        address adminAddress; // address of the admin
        address operatorAddress; // address of the operator
        address operatorVaultAddress; // address of the operator vault
        uint256 commissionfee; // commission rate (e.g. 200 = 2%, 150 = 1.50%)
        mapping(uint256 => Round) rounds;
        mapping(address => uint256) userBalances; // key: user address, value: balance
        mapping(uint256 => FilledOrder[]) filledOrders; // key: epoch
        uint256 lastFilledOrderId;
        uint256 lastSubmissionTime;
        WithdrawalRequest[] withdrawalRequests;
        uint256 lastSettledFilledOrderId; // globally
        mapping(uint256 => uint256) lastSettledFilledOrderIndex; // by round(epoch)
        mapping(address => Coupon[]) couponBalances; // user to coupon list
        uint256 couponAmount; // coupon vault
        uint256 usedCouponAmount; // coupon vault
        address[] couponHolders;
        mapping(uint256 => SettlementResult) settlementResults; // key: filled order idx
        IVault vault;
        IClearingHouse clearingHouse;
    }

    function layout() internal pure returns (Layout storage $) {
        bytes32 slot = SLOT;
        assembly {
            $.slot := slot
        }
    }
} 