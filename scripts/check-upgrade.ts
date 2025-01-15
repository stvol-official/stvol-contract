import { ethers, network } from "hardhat";
import input from "@inquirer/input";

const DEPLOYED_PROXY = "0x6022C15bE2889f9Fca24891e6df82b5A46BaC832"; // for testnet

const checkUpgrade = async () => {
  const networkName = network.name;
  console.log(`Checking on ${networkName} network...`);

  // Get proxy address from input
  const PROXY = await input({
    message: "Enter the proxy address",
    default: DEPLOYED_PROXY,
    validate: (val) => {
      return ethers.isAddress(val);
    },
  });

  // Get new implementation address from input
  const NEW_IMPLEMENTATION = await input({
    message: "Enter the new implementation address",
    validate: (val) => {
      return ethers.isAddress(val);
    },
  });

  // Get proxy contract instance
  const proxy = await ethers.getContractAt("SuperVolHourly", PROXY);

  // Check current implementation
  const implSlot = "0xd15519bf3d12b1a27d33627290ce45a5eea6d098db2fbf692f01e59852393900";
  const currentImpl = await ethers.provider.getStorage(PROXY, implSlot);
  console.log("\nCurrent implementation:", currentImpl);

  // Check owner
  const owner = await proxy.owner();
  console.log("Contract owner:", owner);

  // Check new implementation contract
  const newImplCode = await ethers.provider.getCode(NEW_IMPLEMENTATION);
  console.log("New implementation has code:", newImplCode !== "0x");
  console.log("New implementation code length:", (newImplCode.length - 2) / 2, "bytes");

  // Additional checks
  try {
    const newImpl = await ethers.getContractAt("SuperVolHourly", NEW_IMPLEMENTATION);
    const implOwner = await newImpl.owner();
    console.log("New implementation owner:", implOwner);
  } catch (error) {
    console.log("Could not check new implementation owner - contract might not be initialized");
  }
};

checkUpgrade().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
