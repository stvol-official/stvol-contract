import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network sonieum_testnet scripts/upgrade-clearing-house.ts
 npx hardhat run --network sonieum_mainnet scripts/upgrade-clearing-house.ts
*/

const NETWORK = ["sonieum_testnet", "sonieum_mainnet"];
// const DEPLOYED_PROXY = "0x7D17584f8D6d798EdD4fBEA0EE5a8fAF0f4d6bd2"; // for testnet
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

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    // Deploy contracts.
    const ClearingHouseFactory = await ethers.getContractFactory(contractName);

    // await upgrades.forceImport(PROXY, ClearingHouseFactory, { kind: "uups" });
    const contract = await upgrades.upgradeProxy(PROXY, ClearingHouseFactory, {
      kind: "uups",
      redeployImplementation: "always",
    });

    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();
    console.log(`🍣 ${contractName} Contract deployed at ${contractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    await sleep(6000);

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: contractAddress,
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
