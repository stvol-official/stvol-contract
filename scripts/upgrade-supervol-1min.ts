import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network soneium_testnet scripts/upgrade-supervol-1min.ts
 npx hardhat run --network soneium_mainnet scripts/upgrade-supervol-1min.ts
*/

const NETWORK = ["soneium_testnet", "soneium_mainnet"];
// const DEPLOYED_PROXY = "0x2fEF57866d4b4a6ba80FB3E3107E369B43a022A0"; // for testnet
const DEPLOYED_PROXY = "0xcD771C92bE9CD5b2281B3452Ce32C8f620E5BAE1"; // for mainnet

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const contractName = "SuperVolOneMin";

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
    const SuperVolFactory = await ethers.getContractFactory(contractName);

    const superVolContract = await upgrades.forceImport(PROXY, SuperVolFactory, {
      kind: "uups",
    });
    let superVolContractAddress;
    if (isSafeOwner === "N") {
      const superVolContract = await upgrades.upgradeProxy(PROXY, SuperVolFactory, {
        kind: "uups",
        redeployImplementation: "always",
      });
      await superVolContract.waitForDeployment();
      superVolContractAddress = await superVolContract.getAddress();
      console.log(`🍣 ${contractName} Contract deployed at ${superVolContractAddress}`);
    } else {
      const superVolContract = await upgrades.prepareUpgrade(PROXY, SuperVolFactory, {
        kind: "uups",
        redeployImplementation: "always",
      });
      superVolContractAddress = superVolContract;
      console.log(`🍣 New implementation contract deployed at: ${superVolContract}`);
      console.log("Use this address in your Safe transaction to upgrade the proxy");

      /**
       * Usage: https://safe.optimism.io/
       * Enter Address: 0x6022C15bE2889f9Fca24891e6df82b5A46BaC832
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
      address: superVolContractAddress,
      network: network,
      contract: `contracts/core/${contractName}.sol:${contractName}`,
      constructorArguments: [],
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
