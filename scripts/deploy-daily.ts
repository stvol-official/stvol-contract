import { ethers, network, run } from "hardhat";
import config from "../config";
import select from "@inquirer/select";

const main = async (feed: string) => {
  if (feed !== "ETH_USD" && feed !== "BTC_USD") {
    throw new Error('Invalid PYTH_PRICE_FEED input. Must be "ETH_USD" or "BTC_USD".');
  }

  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const STVOL_NAME = "StVolDaily";
  const PYTH_PRICE_FEED = feed;

  // Check if the network is supported.
  if (networkName === "blast_sepolia") {
    console.log(`Deploying to ${networkName} network...`);

    // Check if the addresses in the config are set.
    if (
      config.Address.Usdc[networkName] === ethers.ZeroAddress ||
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
    console.log("USDC: %s", config.Address.Usdc[networkName]);
    console.log("Oracle: %s", config.Address.Oracle[networkName]);
    console.log("Admin: %s", config.Address.Admin[networkName]);
    console.log("Operator: %s", config.Address.Operator[networkName]);
    console.log("Operator Vault: %s", config.Address.OperatorVault[networkName]);
    console.log("CommissionFee: %s", config.CommissionFee[networkName]);
    console.log("===========================================");

    // Deploy contracts.
    const StVol = await ethers.getContractFactory(STVOL_NAME);
    const stVolContract = await StVol.deploy(
      config.Address.Usdc[networkName],
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

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: stVolContractAddress,
      network: network,
      contract: `contracts/${STVOL_NAME}.sol:${STVOL_NAME}`,
      constructorArguments: [
        config.Address.Usdc[networkName],
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

select({
  message: "Select a COIN",
  choices: [
    {
      name: "BTC_USD",
      value: "BTC_USD",
    },
    {
      name: "ETH_USD",
      value: "ETH_USD",
    },
  ],
}).then((value) => {
  // We recommend this pattern to be able to use async/await everywhere
  // and properly handle errors.

  main(value).catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
});
