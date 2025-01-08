import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network sonieum_testnet scripts/upgrade-supervol-hourly.ts
*/

const NETWORK = ["sonieum_testnet"];
const DEPLOYED_PROXY = "0x6022C15bE2889f9Fca24891e6df82b5A46BaC832"; // for minato

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

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    // Deploy contracts.
    const SuperVolFactory = await ethers.getContractFactory(contractName);

    // const stVolContract = await upgrades.forceImport(PROXY, StVolFactory, { kind: "uups" });
    const superVolContract = await upgrades.upgradeProxy(PROXY, SuperVolFactory, {
      kind: "uups",
      redeployImplementation: "always",
    });

    await superVolContract.waitForDeployment();
    const superVolContractAddress = await superVolContract.getAddress();
    console.log(`🍣 ${contractName} Contract deployed at ${superVolContractAddress}`);

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
