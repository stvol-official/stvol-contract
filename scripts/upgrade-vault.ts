import { ethers, network, run, upgrades } from "hardhat";
import input from "@inquirer/input";

/*
 npx hardhat run --network soneium_testnet scripts/upgrade-vault.ts
 npx hardhat run --network soneium_mainnet scripts/upgrade-vault.ts
*/

const NETWORK = ["soneium_testnet", "soneium_mainnet"];
const DEPLOYED_PROXY = "0xb5Eed5D364f6BF91ee7F4245Ec875a8CaF4bFD41"; // for testnet
// const DEPLOYED_PROXY = "0xF94e7F50120fe8276B85E21f31C6de097eab8813"; // for mainnet

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

const upgrade = async () => {
  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const contractName = "Vault";

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
    const VaultFactory = await ethers.getContractFactory(contractName);

    // await upgrades.forceImport(PROXY, VaultFactory, { kind: "uups" });
    const contract = await upgrades.upgradeProxy(PROXY, VaultFactory, {
      kind: "uups",
      redeployImplementation: "always",
    });

    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();
    console.log(`🍣 ${contractName} Contract deployed at ${contractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    await sleep(6000);

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: contractAddress,
      network: network,
      contract: `contracts/core/${contractName}.sol:${contractName}`,
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
