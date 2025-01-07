// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IVault.sol";
import { WithdrawalRequest, Coupon } from "../types/Types.sol";

library ClearingHouseStorage {
  // keccak256(abi.encode(uint256(keccak256("io.supervol.storage.clearinghouse")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
        0x8813a153063d7fe54e4155b960ce0bcfaac345da276d07e649f6c356f4752100;

  struct Layout {
    IERC20 token;
    address adminAddress;
    address operatorVaultAddress;
    mapping(address => bool) operators;
    mapping(address => uint256) userBalances;
    uint256 treasuryAmount;
    WithdrawalRequest[] withdrawalRequests;
  }
  
  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
} 