import { ethers, network, run, upgrades } from "hardhat";
import config from "../config";

/*
 npx hardhat run --network minato scripts/deploy-supervol-hourly.ts

*/
const main = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const SUPERVOL_NAME = "SuperVolHourly";

  // Check if the network is supported.
  if (networkName === "minato") {
    console.log(`Deploying to ${networkName} network...`);

    // Check if the addresses in the config are set.
    if (
      config.Address.Oracle[networkName] === ethers.ZeroAddress ||
      config.Address.Admin[networkName] === ethers.ZeroAddress ||
      config.Address.Operator[networkName] === ethers.ZeroAddress ||
      config.Address.OperatorVault[networkName] === ethers.ZeroAddress ||
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
    console.log("Oracle: %s", config.Address.Oracle[networkName]);
    console.log("Admin: %s", config.Address.Admin[networkName]);
    console.log("Operator: %s", config.Address.Operator[networkName]);
    console.log("Operator Vault: %s", config.Address.OperatorVault[networkName]);
    console.log("CommissionFee: %s", config.CommissionFee[networkName]);
    console.log("Vault: %s", config.Address.Vault[networkName]);
    console.log("===========================================");

    // Deploy contracts.
    const SuperVolFactory = await ethers.getContractFactory(SUPERVOL_NAME);
    const superVolContract = await upgrades.deployProxy(
      SuperVolFactory,
      [
        config.Address.Oracle[networkName],
        config.Address.Admin[networkName],
        config.Address.Operator[networkName],
        config.Address.OperatorVault[networkName],
        config.CommissionFee[networkName],
        config.Address.Vault[networkName],
      ],
      { kind: "uups" },
    );

    await superVolContract.waitForDeployment();
    const superVolContractAddress = await superVolContract.getAddress();
    console.log(`🍣 ${SUPERVOL_NAME} PROXY Contract deployed at ${superVolContractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

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

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
