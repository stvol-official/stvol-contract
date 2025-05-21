import { ethers, network, run } from "hardhat";

/*
 npx hardhat run --network soneium_testnet scripts/deploy-example-receiver.ts
 npx hardhat run --network soneium_mainnet scripts/deploy-example-receiver.ts 
*/
const NETWORK = ["soneium_testnet", "soneium_mainnet"] as const;
type SupportedNetwork = (typeof NETWORK)[number];

const main = async () => {
  // Get network data from Hardhat config
  const networkName = network.name as SupportedNetwork;
  const contractName = "ExampleReceiver";

  // Check if the network is supported
  if (NETWORK.includes(networkName)) {
    console.log(`Deploying to ${networkName} network...`);

    // Compile contracts
    await run("compile");

    const [deployer] = await ethers.getSigners();

    console.log("Compiled contracts...");
    console.log("===========================================");
    console.log("Owner: %s", deployer.address);
    console.log("===========================================");

    // Deploy libraries first
    const PythLazerLibFactory = await ethers.getContractFactory("PythLazerLib");
    const pythLazerLib = await PythLazerLibFactory.deploy();
    await pythLazerLib.waitForDeployment();
    const pythLazerLibAddress = await pythLazerLib.getAddress();
    console.log(`📡 PythLazerLib deployed at ${pythLazerLibAddress}`);

    // Deploy ExampleReceiver with library link
    const ExampleReceiverFactory = await ethers.getContractFactory(contractName, {
      libraries: {
        PythLazerLib: pythLazerLibAddress,
      },
    });
    const exampleReceiverContract = await ExampleReceiverFactory.deploy();

    await exampleReceiverContract.waitForDeployment();
    const exampleReceiverAddress = await exampleReceiverContract.getAddress();
    console.log(`📡 ${contractName} Contract deployed at ${exampleReceiverAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: exampleReceiverAddress,
      network: network,
      contract: `contracts/core/${contractName}.sol:${contractName}`,
      constructorArguments: [],
    });
    console.log("Contract verification completed");
  } else {
    console.log(`Deploying to ${networkName} network is not supported...`);
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
