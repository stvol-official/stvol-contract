import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network soneium_testnet scripts/upgrade-vault.ts
 npx hardhat run --network soneium_mainnet scripts/upgrade-vault.ts
*/

const NETWORK = ["soneium_testnet", "soneium_mainnet"];
// const DEPLOYED_PROXY = "0x5063560c167c6a9f0d35Ae7c8599BC93AFBA51c6"; // for testnet
const DEPLOYED_PROXY = "0x70495AaBb840bD3e2e945e79b842772dD7892D80"; // for mainnet

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const contractName = "VaultManager";

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
    const VaultFactory = await ethers.getContractFactory(contractName);

    await upgrades.forceImport(PROXY, VaultFactory, { kind: "uups" });
    let contractAddress;
    if (isSafeOwner === "N") {
      const contract = await upgrades.upgradeProxy(PROXY, VaultFactory, {
        kind: "uups",
        redeployImplementation: "always",
      });
      await contract.waitForDeployment();
      contractAddress = await contract.getAddress();
      console.log(`🍣 ${contractName} Contract deployed at ${contractAddress}`);
    } else {
      const contract = await upgrades.prepareUpgrade(PROXY, VaultFactory, {
        kind: "uups",
        redeployImplementation: "always",
      });
      contractAddress = contract;
      console.log(` New implementation contract deployed at: ${contract}`);
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
       * newImplementation: ${contract}
       * Enter Data: 0x
       */
    }

    const network = await ethers.getDefaultProvider().getNetwork();

    await sleep(6000);

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: contractAddress,
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
