// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {
    VaultInfo,
    VaultMember,
    VaultSnapshot
} from "../types/Types.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";

library VaultStorage {
    // keccak256(abi.encode(uint256(keccak256("io.supervol.storage.vault")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 internal constant SLOT =
        0x3ba51e27037c89b8f55c98c430ae8aceea1a621192309f2a67c6375c8c04b300;

    struct Layout {
        IClearingHouse clearingHouse; // Clearing house
        address adminAddress; // Admin address
        mapping(address => bool) operators; // Operators
        mapping(address => VaultInfo) vaults; // key: vault address 
        mapping(address => VaultMember[]) vaultMembers; // key: vault address, value: vault members 
        mapping(uint256 => VaultSnapshot) orderVaultSnapshots; // Mapping from order index to vault snapshot
        address[] operatorList; // List of operators
        /* IMPROTANT: you can add new variables here */
    }

    function layout() internal pure returns (Layout storage $) {
        bytes32 slot = SLOT;
        assembly {
            $.slot := slot
        }
    }
} 