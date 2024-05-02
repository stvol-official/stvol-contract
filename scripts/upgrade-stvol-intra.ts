import { ethers, network, run, upgrades } from "hardhat";
import select from "@inquirer/select";
import input from "@inquirer/input";

/*
 npx hardhat run --network blast_sepolia scripts/upgrade-stvol-intra.ts
*/

const DEPLOYED_PROXY = {
  ETH_USD: "0xdEA4dEF85861cc5B43A510b8AEB4fA465D9C3841",
  BTC_USD: "0x0533b42D1004d13bAECCEBc67353d6Ee8005a236",
  WIF_USD: "0xb14939d917738149942d7B679f2B948D879708AC",
};

const main = async (feed: string) => {
  if (feed !== "ETH_USD" && feed !== "BTC_USD" && feed !== "WIF_USD") {
    throw new Error('Invalid PYTH_PRICE_FEED input. Must be "ETH_USD" or "BTC_USD" or "WIF_USD".');
  }

  // Get network data from Hardhat config (see hardhat.config.ts).
  const networkName = network.name;
  const STVOL_NAME = "StVolIntraBlast";
  const PYTH_PRICE_FEED = feed;

  const PROXY = await input({
    message: "Enter " + feed + " proxy address",
    default: DEPLOYED_PROXY[PYTH_PRICE_FEED],
    validate: (val) => {
      return ethers.isAddress(val);
    },
  });

  // Check if the network is supported.
  if (networkName === "blast_sepolia") {
    console.log(`Deploying to ${networkName} network...`);

    // Compile contracts.
    await run("compile");
    console.log("Compiled contracts...");

    // Deploy contracts.
    const StVolFactory = await ethers.getContractFactory(STVOL_NAME);

    // const stVolContract = await upgrades.forceImport(PROXY, StVolFactory, { kind: "uups" });
    const stVolContract = await upgrades.upgradeProxy(PROXY, StVolFactory, { kind: "uups" });

    await stVolContract.waitForDeployment();
    const stVolContractAddress = await stVolContract.getAddress();
    console.log(`🍣 ${STVOL_NAME} Contract deployed at ${stVolContractAddress}`);

    const network = await ethers.getDefaultProvider().getNetwork();

    console.log("Verifying contracts...");
    await run("verify:verify", {
      address: stVolContractAddress,
      network: network,
      contract: `contracts/${STVOL_NAME}.sol:${STVOL_NAME}`,
      constructorArguments: [],
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
    {
      name: "WIF_USD",
      value: "WIF_USD",
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
