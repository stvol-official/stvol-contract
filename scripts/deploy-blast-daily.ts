import { ethers, network, run } from "hardhat";
import config from "../config";

const main = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const STVOL_NAME = "StVolDailyBlast";
  const PYTH_PRICE_FEED = "BTC_USD";

  // Check if the network is supported.
  if (networkName === "blast_sepolia") {
    console.log(`Deploying to ${networkName} network...`);

    // Check if the addresses in the config are set.
    if (
      config.Address.Oracle[networkName] === ethers.ZeroAddress ||
      config.Address.Admin[networkName] === ethers.ZeroAddress ||
      config.Address.Operator[networkName] === ethers.ZeroAddress ||
      config.Address.OperatorVault[networkName] === ethers.ZeroAddress
    ) {
      throw new Error("Missing addresses (Pyth Oracle and/or Admin/Operator)");
    }

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    console.log("===========================================");
    console.log("Oracle: %s", config.Address.Oracle[networkName]);
    console.log("Admin: %s", config.Address.Admin[networkName]);
    console.log("Operator: %s", config.Address.Operator[networkName]);
    console.log("Operator Vault: %s", config.Address.OperatorVault[networkName]);
    console.log("CommissionFee: %s", config.CommissionFee[networkName]);
    console.log("===========================================");

    // Deploy contracts.
    const StVolDaily = await ethers.getContractFactory(STVOL_NAME);
    const stVolContract = await StVolDaily.deploy(
      config.Address.Oracle[networkName],
      config.Address.Admin[networkName],
      config.Address.Operator[networkName],
      config.Address.OperatorVault[networkName],
      config.CommissionFee[networkName],
      config.PythPriceId[networkName][PYTH_PRICE_FEED],
    );

    await stVolContract.waitForDeployment();
    const stVolContractAddress = await stVolContract.getAddress();
    console.log(`🍣 ${STVOL_NAME} Contract deployed at ${stVolContractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    await run("verify:verify", {
      address: stVolContractAddress,
      network: network,
      contract: `contracts/${STVOL_NAME}.sol:${STVOL_NAME}`,
      constructorArguments: [
        config.Address.Oracle[networkName],
        config.Address.Admin[networkName],
        config.Address.Operator[networkName],
        config.Address.OperatorVault[networkName],
        config.CommissionFee[networkName],
        config.PythPriceId[networkName][PYTH_PRICE_FEED],
      ],
    });
    console.log("verify the contractAction done");
  } else {
    console.log(`Deploying to ${networkName} network is not supported...`);
  }
};

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
