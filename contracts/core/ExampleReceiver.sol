// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { PythLazer } from "../libraries/PythLazer.sol";
import { PythLazerLib } from "../libraries/PythLazerLib.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract ExampleReceiver {
  PythLazer pythLazer;
  uint64 public price;
  uint64 public timestamp;
  uint16 public exponent;
  uint16 public publisher_count;

  event DebugLog(string message);

  constructor() {
    pythLazer = PythLazer(0xACeA761c27A909d4D3895128EBe6370FDE2dF481);
  }

  function updatePrice(bytes calldata update) public payable {
    uint256 verification_fee = pythLazer.verification_fee();
    require(msg.value >= verification_fee, "Insufficient fee provided");
    (bytes memory payload, ) = pythLazer.verifyUpdate{ value: verification_fee }(update);
    if (msg.value > verification_fee) {
      payable(msg.sender).transfer(msg.value - verification_fee);
    }

    (uint64 _timestamp, PythLazerLib.Channel channel, uint8 feedsLen, uint16 pos) = PythLazerLib
      .parsePayloadHeader(payload);
    emit DebugLog(string.concat("timestamp ", Strings.toString(_timestamp)));
    emit DebugLog(string.concat("channel ", Strings.toString(uint8(channel))));
    if (channel != PythLazerLib.Channel.RealTime) {
      revert("expected update from RealTime channel");
    }
    emit DebugLog(string.concat("feedsLen ", Strings.toString(feedsLen)));
    for (uint8 i = 0; i < feedsLen; i++) {
      uint32 feedId;
      uint8 num_properties;
      (feedId, num_properties, pos) = PythLazerLib.parseFeedHeader(payload, pos);
      emit DebugLog(string.concat("feedId ", Strings.toString(feedId)));
      emit DebugLog(string.concat("num_properties ", Strings.toString(num_properties)));
      for (uint8 j = 0; j < num_properties; j++) {
        PythLazerLib.PriceFeedProperty property;
        (property, pos) = PythLazerLib.parseFeedProperty(payload, pos);
        if (property == PythLazerLib.PriceFeedProperty.Price) {
          uint64 _price;
          (_price, pos) = PythLazerLib.parseFeedValueUint64(payload, pos);
          emit DebugLog(string.concat("price ", Strings.toString(_price)));
          if (feedId == 6 && _timestamp > timestamp) {
            price = _price;
            timestamp = _timestamp;
          }
        } else if (property == PythLazerLib.PriceFeedProperty.BestBidPrice) {
          uint64 _price;
          (_price, pos) = PythLazerLib.parseFeedValueUint64(payload, pos);
          emit DebugLog(string.concat("best bid price ", Strings.toString(_price)));
        } else if (property == PythLazerLib.PriceFeedProperty.BestAskPrice) {
          uint64 _price;
          (_price, pos) = PythLazerLib.parseFeedValueUint64(payload, pos);
          emit DebugLog(string.concat("best ask price ", Strings.toString(_price)));
        } else if (property == PythLazerLib.PriceFeedProperty.Exponent) {
          int16 _exponent;
          (_exponent, pos) = PythLazerLib.parseFeedValueInt16(payload, pos);
          emit DebugLog(string.concat("exponent ", Strings.toString(uint16(_exponent))));
        } else if (property == PythLazerLib.PriceFeedProperty.PublisherCount) {
          uint16 _publisher_count;
          (_publisher_count, pos) = PythLazerLib.parseFeedValueUint16(payload, pos);
          emit DebugLog(string.concat("publisher count ", Strings.toString(_publisher_count)));
          publisher_count = _publisher_count;
        } else {
          revert("unknown property");
        }
      }
    }
  }
}
