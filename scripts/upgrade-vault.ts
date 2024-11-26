import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network minato scripts/upgrade-stvol-hourly.ts
*/

const NETWORK = ["base", "base_sepolia", "minato"];
const DEPLOYED_PROXY = "0x9Ac4ea5E80D6EC5F432521a970A51348037a7253"; // for minato

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const CONTRACT_NAME = "Vault";

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
    const VaultFactory = await ethers.getContractFactory(CONTRACT_NAME);

    // const stVolContract = await upgrades.forceImport(PROXY, VaultFactory, { kind: "uups" });
    const contract = await upgrades.upgradeProxy(PROXY, VaultFactory, {
      kind: "uups",
      redeployImplementation: "always",
    });

    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();
    console.log(`🍣 ${CONTRACT_NAME} Contract deployed at ${contractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    await sleep(6000);

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: contractAddress,
      network: network,
      contract: `contracts/${CONTRACT_NAME}.sol:${CONTRACT_NAME}`,
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
