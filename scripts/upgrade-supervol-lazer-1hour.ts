import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network soneium_testnet scripts/upgrade-supervol-lazer-1hour.ts
 npx hardhat run --network soneium_mainnet scripts/upgrade-supervol-lazer-1hour.ts
*/

const NETWORK = ["soneium_testnet", "soneium_mainnet"];
const DEPLOYED_PROXY = "0xBcaC3552EC63cb03363B33bC9182eb594e209FC7"; // for testnet
const PYTH_LAZER_LIB_ADDRESS = "0x9F75E45a06FA4bd0a89f97e606EfC24A64916750"; // for testnet

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const contractName = "SuperVolHourly";

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
    console.log(`Upgrading to ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    // Use existing library address instead of deploying new one
    console.log(`📡 Using existing PythLazerLib at ${PYTH_LAZER_LIB_ADDRESS}`);

    // Deploy contracts with existing library linking
    const SuperVolFactory = await ethers.getContractFactory(contractName, {
      libraries: {
        PythLazerLib: PYTH_LAZER_LIB_ADDRESS,
      },
    });

    const superVolContract = await upgrades.forceImport(PROXY, SuperVolFactory, {
      kind: "uups",
    });

    let superVolContractAddress;
    if (isSafeOwner === "N") {
      const superVolContract = await upgrades.upgradeProxy(PROXY, SuperVolFactory, {
        kind: "uups",
        redeployImplementation: "always",
        unsafeAllowLinkedLibraries: true,
      });
      await superVolContract.waitForDeployment();
      superVolContractAddress = await superVolContract.getAddress();
      console.log(`🍣 ${contractName} Contract upgraded at ${superVolContractAddress}`);
    } else {
      const superVolContract = await upgrades.prepareUpgrade(PROXY, SuperVolFactory, {
        kind: "uups",
        redeployImplementation: "always",
        unsafeAllowLinkedLibraries: true,
      });
      superVolContractAddress = superVolContract;
      console.log(`�� New implementation contract deployed at: ${superVolContract}`);
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
    console.log(`Upgrading to ${networkName} network is not supported...`);
  }
};

upgrade().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
