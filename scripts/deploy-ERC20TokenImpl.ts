import { ethers, network, run } from "hardhat";

const main = async () => {
  // Get network data from Hardhat config.
  const networkName = network.name;
  const name = "STVOL TEST USDB";
  const symbol = "vUSDB";
  const decimal = 18;

  // Check if the network is supported.
  if (networkName === "goerli" || networkName === "arbitrum_sepolia" || networkName === "blast_sepolia") {
    console.log(`Deploying to ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts. Deploying...");

    const ERC20TokenImpl = await ethers.getContractFactory("ERC20TokenImpl");
    const contract = await ERC20TokenImpl.deploy(name, symbol, decimal);

    // Wait for the contract to be deployed before exiting the script.
    await contract.deployed();
    console.log(`Deployed to ${contract.address}`);

    await run("verify:verify", {
      address: contract.address,
      network: ethers.provider.network,
      constructorArguments: [name, symbol, decimal]
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
