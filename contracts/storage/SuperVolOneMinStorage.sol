// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVaultManager } from "../interfaces/IVaultManager.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { Round, OneMinOrder, SettlementResult, WithdrawalRequest, Coupon, PriceInfo } from "../types/Types.sol";
import { PythLazer } from "../libraries/PythLazer.sol";

library SuperVolOneMinStorage {
  // keccak256(abi.encode(uint256(keccak256("io.supervol.storage.onemin")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0x03838e20f04b62d54d0fa8d70d5d5628692314bf64c6ab0c5e3b3375749da000;

  struct Layout {
    IERC20 token; // Prediction token
    IPyth oracle;
    IVaultManager vaultManager;
    IClearingHouse clearingHouse;
    address adminAddress; // address of the admin
    address[] operatorAddresses; // address of the operator
    mapping(uint256 => uint256) commissionfees; // key: productId, commission rate (e.g. 200 = 2%, 150 = 1.50%)
    mapping(uint256 => mapping(uint256 => uint64)) priceHistory; // timestamp => productId => price
    mapping(uint256 => OneMinOrder) oneMinOrders; // key: order idx
    address vault;
    mapping(uint256 => PriceInfo) priceInfos; // productId => PriceInfo
    mapping(bytes32 => uint256) priceIdToProductId; // priceId => productId
    uint256 priceIdCount;
    PythLazer pythLazer;
    /* IMPROTANT: you can add new variables here */
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
