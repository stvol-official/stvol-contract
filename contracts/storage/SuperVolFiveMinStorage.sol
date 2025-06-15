// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVaultManager } from "../interfaces/IVaultManager.sol";
import { IClearingHouse } from "../interfaces/IClearingHouse.sol";
import { Round, OneMinOrder as FiveMinOrder, SettlementResult, WithdrawalRequest, Coupon, PriceInfo } from "../types/Types.sol";

library SuperVolFiveMinStorage {
  // keccak256(abi.encode(uint256(keccak256("io.supervol.storage.fivemin")) - 1)) & ~bytes32(uint256(0xff));
  bytes32 internal constant SLOT =
    0xfe8b786fe8ff5a06af935bf0c103f7970840a75f5329efbcb025b0e8fd2e5c00;

  struct Layout {
    IERC20 token; // Prediction token
    IPyth oracle;
    IVaultManager vaultManager;
    IClearingHouse clearingHouse;
    address adminAddress; // address of the admin
    address[] operatorAddresses; // address of the operator
    mapping(uint256 => uint256) commissionfees; // key: productId, commission rate (e.g. 200 = 2%, 150 = 1.50%)
    mapping(uint256 => mapping(uint256 => uint64)) priceHistory; // timestamp => productId => price
    mapping(uint256 => FiveMinOrder) fiveMinOrders; // key: order idx
    address vault;
    mapping(uint256 => PriceInfo) priceInfos; // productId => PriceInfo
    mapping(bytes32 => uint256) priceIdToProductId; // priceId => productId
    uint256 priceIdCount;
    /* IMPROTANT: you can add new variables here */
  }

  function layout() internal pure returns (Layout storage $) {
    bytes32 slot = SLOT;
    assembly {
      $.slot := slot
    }
  }
}
