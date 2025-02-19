import { ethers, network, run, upgrades } from "hardhat";
import config from "../config";

/*
 npx hardhat run --network soneium_testnet scripts/deploy-supervol-1min.ts
 npx hardhat run --network soneium_mainnet scripts/deploy-supervol-1min.ts
*/
const NETWORK = ["soneium_testnet", "soneium_mainnet"] as const;
type SupportedNetwork = (typeof NETWORK)[number];
const main = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name as SupportedNetwork;
  const contractName = "SuperVolOneMin";

  // Check if the network is supported.
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Check if the addresses in the config are set.
    if (
      config.Address.Usdc[networkName] === ethers.ZeroAddress ||
      config.Address.Oracle[networkName] === ethers.ZeroAddress ||
      config.Address.Admin[networkName] === ethers.ZeroAddress ||
      config.Address.Operator[networkName] === ethers.ZeroAddress ||
      config.Address.ClearingHouse[networkName] === ethers.ZeroAddress ||
      config.Address.Vault[networkName] === ethers.ZeroAddress
    ) {
      throw new Error("Missing addresses (Pyth Oracle and/or Admin/Operator)");
    }

    // Compile contracts.
    await run("compile");

    const [deployer] = await ethers.getSigners();
    console.log("Compiled contracts...");
    console.log("===========================================");
    console.log("Owner: %s", deployer.address);
    console.log("Usdc: %s", config.Address.Usdc[networkName]);
    console.log("Oracle: %s", config.Address.Oracle[networkName]);
    console.log("Admin: %s", config.Address.Admin[networkName]);
    console.log("Operator: %s", config.Address.Operator[networkName]);
    console.log("ClearingHouse: %s", config.Address.ClearingHouse[networkName]);
    console.log("Vault: %s", config.Address.Vault[networkName]);
    console.log("===========================================");

    // Deploy contracts.
    const SuperVolFactory = await ethers.getContractFactory(contractName);
    const superVolContract = await upgrades.deployProxy(
      SuperVolFactory,
      [
        config.Address.Usdc[networkName],
        config.Address.Oracle[networkName],
        config.Address.Admin[networkName],
        config.Address.Operator[networkName],
        config.Address.ClearingHouse[networkName],
        config.Address.Vault[networkName],
      ],
      { kind: "uups", initializer: "initialize" },
    );

    await superVolContract.waitForDeployment();

    // initialize 호출 확인
    console.log("Checking initialization...");
    const [adminAddress] = await superVolContract.addresses();
    if (adminAddress !== config.Address.Admin[networkName]) {
      console.error("Contract was not properly initialized!");
      console.error(`Expected admin address: ${config.Address.Admin[networkName]}`);
      console.error(`Actual admin address: ${adminAddress}`);
      throw new Error("Initialization failed");
    }
    console.log("Contract successfully initialized");

    const superVolContractAddress = await superVolContract.getAddress();
    console.log(`🍣 ${contractName} PROXY Contract deployed at ${superVolContractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

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

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
