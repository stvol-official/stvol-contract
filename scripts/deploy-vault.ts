import { ethers, network, run, upgrades } from "hardhat";
import config from "../config";

/*
 npx hardhat run --network minato scripts/deploy-vault.ts
*/

const main = async () => {
  // Get network data from Hardhat config
  const networkName = network.name;
  const VAULT_NAME = "Vault";

  // Check if the network is supported
  if (networkName === "minato") {
    console.log(`Deploying to ${networkName} network...`);

    // Check if the addresses in the config are set
    if (
      config.Address.Admin[networkName] === ethers.ZeroAddress ||
      config.Address.Operator[networkName] === ethers.ZeroAddress
    ) {
      throw new Error("Missing addresses (Admin/Operator)");
    }

    // Compile contracts
    await run("compile");

    const [deployer] = await ethers.getSigners();

    console.log("Compiled contracts...");
    console.log("===========================================");
    console.log("Owner: %s", deployer.address);
    console.log("Admin: %s", config.Address.Admin[networkName]);
    console.log("Operator: %s", config.Address.Operator[networkName]);
    console.log("===========================================");

    // Deploy contracts
    const VaultFactory = await ethers.getContractFactory(VAULT_NAME);
    const vaultContract = await upgrades.deployProxy(
      VaultFactory,
      [config.Address.Admin[networkName], config.Address.Operator[networkName]],
      { kind: "uups" },
    );

    await vaultContract.waitForDeployment();
    const vaultContractAddress = await vaultContract.getAddress();
    console.log(`🏦 ${VAULT_NAME} PROXY Contract deployed at ${vaultContractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: vaultContractAddress,
      network: network,
      contract: `contracts/${VAULT_NAME}.sol:${VAULT_NAME}`,
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
