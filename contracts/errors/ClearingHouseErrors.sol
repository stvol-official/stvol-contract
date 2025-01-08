// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import { ICommonErrors } from "./CommonErrors.sol";

interface IClearingHouseErrors is ICommonErrors {
    error InvalidIdx();
    error RequestAlreadyProcessed();
    error ClearingHouseSpecificError();
    error InvalidSettlement();
    error InvalidCommissionFee();
    error InvalidTokenAddress();
} 