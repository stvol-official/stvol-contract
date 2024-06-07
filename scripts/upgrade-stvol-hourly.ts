import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network blast_sepolia scripts/upgrade-stvol-hourly.ts
*/

const DEPLOYED_PROXY = "0x2B709CeB281d3764231269f2f4b59b2EDA9e7D61"; // for development
// 0xeA56775374B5858eA454fB857477E0E728C9062d for production

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const STVOL_NAME = "StVolHourly";

  const PROXY = await input({
    message: "Enter the proxy address",
    default: DEPLOYED_PROXY,
    validate: (val) => {
      return ethers.isAddress(val);
    },
  });

  // Check if the network is supported.
  if (networkName === "blast_sepolia") {
    console.log(`Deploying to ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    // Deploy contracts.
    const StVolFactory = await ethers.getContractFactory(STVOL_NAME);

    // const stVolContract = await upgrades.forceImport(PROXY, StVolFactory, { kind: "uups" });
    const stVolContract = await upgrades.upgradeProxy(PROXY, StVolFactory, {
      kind: "uups",
      redeployImplementation: "always",
    });

    await stVolContract.waitForDeployment();
    const stVolContractAddress = await stVolContract.getAddress();
    console.log(`🍣 ${STVOL_NAME} Contract deployed at ${stVolContractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    await sleep(5000);

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: stVolContractAddress,
      network: network,
      contract: `contracts/${STVOL_NAME}.sol:${STVOL_NAME}`,
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
