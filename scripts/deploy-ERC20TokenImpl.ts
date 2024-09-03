import { ethers, network, run } from "hardhat";

/*
 npx hardhat run --network minato scripts/deploy-ERC20TokenImpl.ts
 npx hardhat verify --constructor-args dev.erc20.arguments.js --network minato 0xe722424e913f48bAC7CD2C1Ae981e2cD09bd95EC
*/

const main = async () => {
  // Get network data from Hardhat config.
  const networkName = network.name;
  const name = "SUPERVOL TEST USDC";
  const symbol = "vUSDC";
  const decimal = 6;

  // Check if the network is supported.
  if (
    networkName === "goerli" ||
    networkName === "arbitrum_sepolia" ||
    networkName === "blast_sepolia" ||
    networkName === "base_sepolia" ||
    networkName === "soneium_sepolia"
  ) {
    console.log(`Deploying to ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts. Deploying...");
    console.log("===========================================");
    console.log("networkName: %s", networkName);
    console.log("name: %s", name);
    console.log("symbol: %s", symbol);
    console.log("decimal: %d", decimal);

    const ERC20TokenImpl = await ethers.getContractFactory("ERC20TokenImpl");
    const contract = await ERC20TokenImpl.deploy(name, symbol, decimal);

    // Wait for the contract to be deployed before exiting the script.
    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();
    console.log(`Deployed to ${contractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    await run("verify:verify", {
      address: contractAddress,
      network: network,
      constructorArguments: [name, symbol, decimal],
    });
  } else {
    console.log(`Deploying to ${networkName} network is not supported...`);
  }
};

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
