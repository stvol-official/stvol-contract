import { ethers, network, run, upgrades } from "hardhat";

/*
 npx hardhat run --network sonieum_testnet scripts/recovery-vault.ts
*/
const NETWORK = ["sonieum_testnet"];
const DEPLOYED_PROXY = "0x49Ff93096bD296E70652969a2205461998b75550"; // for minato
const OLD_IMPLEMENTATION_ADDRESS = "0xE10a008306B13514DFdf155449FFB21dbFdBd285";
const contractName = "Vault";

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    // Deploy contracts.
    const Proxy = await ethers.getContractAt(contractName, DEPLOYED_PROXY);
    console.log("Reverting to old implementation...");
    await Proxy.upgradeToAndCall(OLD_IMPLEMENTATION_ADDRESS, "0x");
    console.log("Proxy successfully reverted to old implementation!");
  } else {
    console.log(`Deploying to ${networkName} network is not supported...`);
  }
};

upgrade().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
