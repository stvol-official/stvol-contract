import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network soneium_testnet scripts/upgrade-clearing-house.ts
 npx hardhat run --network soneium_mainnet scripts/upgrade-clearing-house.ts
*/

const NETWORK = ["soneium_testnet", "soneium_mainnet"];
// const DEPLOYED_PROXY = "0xB48434a7160AAC2C4e5cdB3C3Cc2Ecfd83c6E292"; // for testnet
const DEPLOYED_PROXY = "0x618148f2Bb58C5c89737BB160070613d4E1b790a"; // for mainnet

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const contractName = "ClearingHouse";

  const PROXY = await input({
    message: "Enter the proxy address",
    default: DEPLOYED_PROXY,
    validate: (val) => {
      return ethers.isAddress(val);
    },
  });

  const isSafeOwner = await input({
    message: "Is the owner safe address?",
    default: "N",
  });

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    // Deploy contracts.
    const ClearingHouseFactory = await ethers.getContractFactory(contractName);

    // await upgrades.forceImport(PROXY, ClearingHouseFactory, { kind: "uups" });
    let clearingHouseContractAddress;
    if (isSafeOwner === "N") {
      const clearingHouseContract = await upgrades.upgradeProxy(PROXY, ClearingHouseFactory, {
        kind: "uups",
        redeployImplementation: "always",
      });
      await clearingHouseContract.waitForDeployment();
      clearingHouseContractAddress = await clearingHouseContract.getAddress();
      console.log(`🍣 ${contractName} Contract deployed at ${clearingHouseContractAddress}`);
    } else {
      const clearingHouseContract = await upgrades.prepareUpgrade(PROXY, ClearingHouseFactory, {
        kind: "uups",
        redeployImplementation: "always",
      });
      clearingHouseContractAddress = clearingHouseContract;
      console.log(`🍣 New implementation contract deployed at: ${clearingHouseContract}`);
      console.log("Use this address in your Safe transaction to upgrade the proxy");

      /**
       * Usage: https://safe.optimism.io/
       * Enter Address: 0x7D17584f8D6d798EdD4fBEA0EE5a8fAF0f4d6bd2
       * Enter ABI:
       [
          {
            "inputs": [
              {
                "internalType": "address",
                "name": "newImplementation",
                "type": "address"
              },
              {
                "internalType": "bytes",
                "name": "data",
                "type": "bytes"
              }
            ],
            "name": "upgradeToAndCall",
            "outputs": [],
            "stateMutability": "nonpayable",
            "type": "function"
          }
        ]
       * Contract Method: upgradeToAndCall(address newImplementation, bytes data)
       * newImplementation: ${superVolContract}
       * Enter Data: 0x
       */
    }
    const network = await ethers.getDefaultProvider().getNetwork();

    await sleep(6000);

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: clearingHouseContractAddress,
      network: network,
      contract: `contracts/core/${contractName}.sol:${contractName}`,
    });
    console.log("verify the contractAction done");
  } else {
    console.log(`Deploying to ${networkName} network is not supported...`);
  }
};

upgrade().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
