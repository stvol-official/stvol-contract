import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network minato scripts/upgrade-supervol-hourly.ts
*/

const NETWORK = ["minato"];
const DEPLOYED_PROXY = "0x492a3118b1c6328C01e123a1E38C6bed7375C92F"; // for minato

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const SUPERVOL_NAME = "SuperVolHourly";

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
    const SuperVolFactory = await ethers.getContractFactory(SUPERVOL_NAME);

    // const stVolContract = await upgrades.forceImport(PROXY, StVolFactory, { kind: "uups" });
    const superVolContract = await upgrades.upgradeProxy(PROXY, SuperVolFactory, {
      kind: "uups",
      redeployImplementation: "always",
    });

    await superVolContract.waitForDeployment();
    const superVolContractAddress = await superVolContract.getAddress();
    console.log(`🍣 ${SUPERVOL_NAME} Contract deployed at ${superVolContractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    await sleep(6000);

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: superVolContractAddress,
      network: network,
      contract: `contracts/${SUPERVOL_NAME}.sol:${SUPERVOL_NAME}`,
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
