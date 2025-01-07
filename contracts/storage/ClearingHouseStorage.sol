// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IVault.sol";
import { WithdrawalRequest, Coupon } from "../Types.sol";

library ClearingHouseStorage {
  struct Layout {
    IERC20 token;
    IVault vault;
    address operatorAddress;
    mapping(address => uint256) userBalances;
    uint256 treasuryAmount;
    WithdrawalRequest[] withdrawalRequests;
    uint256 lastSubmissionTime;
    uint256 couponAmount;
    mapping(address => Coupon[]) couponBalances;
    address[] couponHolders;
  }

  bytes32 internal constant STORAGE_SLOT =
    keccak256('volt.clearinghouse.storage');

  function layout() internal pure returns (Layout storage l) {
    bytes32 slot = STORAGE_SLOT;
    assembly {
      l.slot := slot
    }
  }
} 