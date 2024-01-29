// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "hardhat/console.sol";
import { StVolIntra } from "../StVolIntra.sol";
import "../libraries/IntraOrderSet.sol";


contract StVolIntraTest is StVolIntra {
    using IntraOrderSet for IntraOrderSet.Data;

    constructor(
        address _token,
        address _oracleAddress,
        address _adminAddress,
        address _operatorAddress,
        address _operatorVaultAddress,
        uint256 _commissionfee,
        bytes32 _priceId
    ) StVolIntra(
        _token,
        _oracleAddress,
        _adminAddress,
        _operatorAddress,
        _operatorVaultAddress,
        _commissionfee,
        _priceId
    ) {
    }

    function printOrders(uint256 epoch, uint8 strike) public {
        console.log("=== printOrders ===");

        Option storage option = rounds[epoch].options[strike];
        uint256 idx;
        
        console.log("== over orders ==");
        idx = option.overOrders.first();
        while (idx != IntraOrderSet.QUEUE_START && idx != IntraOrderSet.QUEUE_END) {
            IntraOrderSet.IntraOrder memory order = option.overOrders.orderMap[idx];            
            console.log("price: %s, unit: %s", order.price, order.unit);
            idx = option.overOrders.next(idx);
        }

        console.log("== under orders ==");
        idx = option.underOrders.first();
        while (idx != IntraOrderSet.QUEUE_START && idx != IntraOrderSet.QUEUE_END) {
            IntraOrderSet.IntraOrder memory order = option.underOrders.orderMap[idx];            
            console.log("price: %s, unit: %s", order.price, order.unit);
            idx = option.underOrders.next(idx);
        }

        console.log("== excuted orders ==");
        idx = 1;
        do {
            FilledOrder memory order = option.filledOrders[idx];
            if (order.idx == 0) break;

            console.log("idx: %s, over price: %s, unit: %s", order.idx, order.overPrice, order.unit);



            idx++;
        } while (true);



    }

}