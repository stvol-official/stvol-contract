// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { VaultInfo, VaultMember} from "../types/Types.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";

library VaultStorage {
  // keccak256(abi.encode(uint256(keccak256("io.supervol.storage.vault")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0x3ba51e27037c89b8f55c98c430ae8aceea1a621192309f2a67c6375c8c04b300;

  struct Layout {
    IClearingHouse clearingHouse; // Clearing house
    address adminAddress; // Admin address
    mapping(address => bool) operators; // Operators
    mapping(address => mapping(address => VaultInfo)) vaults; // key: product -> vault address
    mapping(address => mapping(address => VaultMember[])) vaultMembers; // key: product -> vault address -> vault members
    address[] operatorList; // List of operators
    address[] vaultList; // List of vaults
    uint256 vaultCounter; // Add this line
    /* IMPROTANT: you can add new variables here */
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
