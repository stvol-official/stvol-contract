import { ethers, network, run } from "hardhat";

const main = async () => {
    // Get network data from Hardhat config.
    const networkName = network.name;

    // Check if the network is supported.
    console.log(`Deploying to ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts. Deploying...");

    // Deploy contracts.
    const Reststone = await ethers.getContractFactory("RedstoneRelayerAdapter");
    const contract = await Reststone.deploy();

    // Wait for the contract to be deployed before exiting the script.
    await contract.deployed();
    console.log(`Deployed to ${contract.address}`);
};

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
