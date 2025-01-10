const { ethers } = require("ethers");
require("dotenv").config();

if (!process.env.PRIVATE_KEY) {
  throw new Error("PRIVATE_KEY is not defined in .env file");
}
console.log(process.env.PRIVATE_KEY);

// ABI
const contractABI = [
  {
    inputs: [
      {
        internalType: "address",
        name: "operator",
        type: "address",
      },
    ],
    name: "addOperator",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
];

const CONFIG = {
  RPC_URL: "https://soneium.rpc.scs.startale.com?apikey=WIW3bW9VR6NydF09EMd451ojzd84TfHe",
  //   CONTRACT_ADDRESS: "0x618148f2Bb58C5c89737BB160070613d4E1b790a", // ClearingHouse
  CONTRACT_ADDRESS: "0xF94e7F50120fe8276B85E21f31C6de097eab8813", // Vault
  CHAIN_ID: 1868,
};

const OPERATOR_ADDRESS = "0x34834F208F149e0269394324c3f19e06dF2ca9cB"; // SuperVol Contract Address

async function main() {
  try {
    const provider = new ethers.JsonRpcProvider(CONFIG.RPC_URL);
    const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

    const contract = new ethers.Contract(CONFIG.CONTRACT_ADDRESS, contractABI, wallet);

    console.log("Sending transaction to add operator...");

    const tx = await contract.addOperator(OPERATOR_ADDRESS);
    console.log("Transaction sent:", tx.hash);

    const receipt = await tx.wait();

    console.log("Transaction successful!");
    console.log("Transaction hash:", receipt.hash);
    console.log("Gas used:", receipt.gasUsed.toString());
  } catch (error) {
    console.error("Error occurred:", error);
    process.exit(1);
  }
}

// 스크립트 실행
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
