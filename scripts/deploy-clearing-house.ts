import { ethers, network, run, upgrades } from "hardhat";
import config from "../config";

/*
 npx hardhat run --network sonieum_testnet scripts/deploy-clearing-house.ts
 npx hardhat run --network sonieum_mainnet scripts/deploy-clearing-house.ts
*/
const NETWORK = ["sonieum_testnet", "sonieum_mainnet"] as const;
type SupportedNetwork = (typeof NETWORK)[number];
const main = async () => {
  // Get network data from Hardhat config
  const networkName = network.name as SupportedNetwork;
  const contractName = "ClearingHouse";

  // Check if the network is supported
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Check if the addresses in the config are set
    if (
      config.Address.Usdc[networkName] === ethers.ZeroAddress ||
      config.Address.Admin[networkName] === ethers.ZeroAddress ||
      config.Address.OperatorVault[networkName] === ethers.ZeroAddress
    ) {
      throw new Error("Missing addresses (Usdc/Admin/OperatorVault)");
    }

    // Compile contracts
    await run("compile");

    const [deployer] = await ethers.getSigners();

    console.log("Compiled contracts...");
    console.log("===========================================");
    console.log("Owner: %s", deployer.address);
    console.log("Usdc: %s", config.Address.Usdc[networkName]);
    console.log("Admin: %s", config.Address.Admin[networkName]);
    console.log("OperatorVault: %s", config.Address.OperatorVault[networkName]);
    console.log("===========================================");

    // Deploy contracts
    const ClearingHouseFactory = await ethers.getContractFactory(contractName);
    const clearingHouseContract = await upgrades.deployProxy(
      ClearingHouseFactory,
      [
        config.Address.Usdc[networkName],
        config.Address.Admin[networkName],
        config.Address.OperatorVault[networkName],
      ],
      { kind: "uups" },
    );

    await clearingHouseContract.waitForDeployment();
    const clearingHouseContractAddress = await clearingHouseContract.getAddress();
    console.log(`🏦 ${contractName} PROXY Contract deployed at ${clearingHouseContractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: clearingHouseContractAddress,
      network: network,
      contract: `contracts/core/${contractName}.sol:${contractName}`,
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
