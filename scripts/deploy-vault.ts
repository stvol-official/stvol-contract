import { ethers, network, run, upgrades } from "hardhat";
import config from "../config";

/*
 npx hardhat run --network soneium_testnet scripts/deploy-vault.ts
npx hardhat run --network soneium_mainnet scripts/deploy-vault.ts 
*/
const NETWORK = ["soneium_testnet", "soneium_mainnet"] as const;
type SupportedNetwork = (typeof NETWORK)[number];
const main = async () => {
  // Get network data from Hardhat config
  const networkName = network.name as SupportedNetwork;
  const contractName = "VaultManager";

  // Check if the network is supported
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Check if the addresses in the config are set
    if (config.Address.Admin[networkName] === ethers.ZeroAddress) {
      throw new Error("Missing addresses (Admin/Operator)");
    }

    // Compile contracts
    await run("compile");

    const [deployer] = await ethers.getSigners();

    console.log("Compiled contracts...");
    console.log("===========================================");
    console.log("Owner: %s", deployer.address);
    console.log("Admin: %s", config.Address.Admin[networkName]);
    console.log("===========================================");

    // Deploy contracts
    const VaultFactory = await ethers.getContractFactory(contractName);
    const vaultContract = await upgrades.deployProxy(
      VaultFactory,
      [config.Address.Admin[networkName]],
      { kind: "uups" },
    );

    await vaultContract.waitForDeployment();
    const vaultContractAddress = await vaultContract.getAddress();
    console.log(`🏦 ${contractName} PROXY Contract deployed at ${vaultContractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: vaultContractAddress,
      network: network,
      contract: `contracts/core/${contractName}.sol:${contractName}`,
      constructorArguments: [],
    });
    console.log("verify the contractAction done");
  } else {
    console.log(`Deploying to ${networkName} network is not supported...`);
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
