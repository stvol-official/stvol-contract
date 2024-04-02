// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.4;
import "../redstone/PriceFeedsAdapterWithoutRounds.sol";

contract RedstoneRelayerAdapter is PriceFeedsAdapterWithoutRounds {
  function getDataServiceId() public view virtual override returns (string memory) {
    return "redstone-blast-stvol-prod";
  }

  function getDataFeedIds() public pure override returns (bytes32[] memory dataFeedIds) {
    dataFeedIds = new bytes32[](2);
    dataFeedIds[1] = bytes32("BTC");
    dataFeedIds[0] = bytes32("ETH");
  }

  function getUniqueSignersThreshold() public pure override returns (uint8) {
    return 3;
  }

  function getAuthorisedSignerIndex(
    address signerAddress
  ) public view virtual override returns (uint8) {
    if (signerAddress == 0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774) {
      return 0;
    } else if (signerAddress == 0xdEB22f54738d54976C4c0fe5ce6d408E40d88499) {
      return 1;
    } else if (signerAddress == 0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202) {
      return 2;
    } else if (signerAddress == 0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE) {
      return 3;
    } else if (signerAddress == 0x9c5AE89C4Af6aA32cE58588DBaF90d18a855B6de) {
      return 4;
    } else {
      revert SignerNotAuthorised(signerAddress);
    }
  }
  // By default, we have 3 seconds between the updates, but in the Tangible Use Case
  // We need to set it to 0 to avoid conflicts between users

  // In production contract we strongly recommend to set it at least to 3
}
