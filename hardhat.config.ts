import "@nomicfoundation/hardhat-verify";
import "solidity-coverage";
import "@openzeppelin/hardhat-upgrades";
import "@typechain/hardhat";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-chai-matchers";

import * as fs from "fs";
import * as dotenv from "dotenv";

dotenv.config();

const mnemonic = fs.existsSync(".secret")
  ? fs.readFileSync(".secret").toString().trim()
  : "test test test test test test test test test test test junk";

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more
export default {
  networks: {
    hardhat: {
      chainId: 31337,
    },
    localhost: {
      chainId: 31337,
    },
    sonieum_testnet: {
      url: `https://rpc.minato.soneium.org`,
      gas: 22000000,
      allowUnlimitedContractSize: true,
      accounts: {
        mnemonic,
      },
      chainId: 1946,
      timeout: 60000,
    },
    sonieum_mainnet: {
      url: `https://soneium.rpc.scs.startale.com?apikey=WIW3bW9VR6NydF09EMd451ojzd84TfHe`,
      gas: 22000000,
      allowUnlimitedContractSize: true,
      accounts: {
        mnemonic,
      },
      chainId: 1868,
      timeout: 60000,
    },
  },
  solidity: {
    compilers: [
      {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: true,
        },
      },
      {
        version: "0.8.4",
        settings: {
          optimizer: {
            enabled: true,
            runs: 400,
          },
          viaIR: true,
        },
      },
    ],
  },
  typechain: {
    outDir: "typechain",
    target: "ethers-v6",
  },
  contractSizer: {
    alphaSort: true,
  },
  defaultNetwork: "hardhat",
  etherscan: {
    apiKey: {
      sonieum_testnet: "empty", // apiKey is not required, just set a placeholder
      sonieum_mainnet: "empty", // apiKey is not required, just set a placeholder
    },
    customChains: [
      {
        network: "sonieum_testnet",
        chainId: 1946,
        urls: {
          apiURL: "https://soneium-minato.blockscout.com/api",
          browserURL: "https://soneium-minato.blockscout.com",
        },
      },
      {
        network: "sonieum_mainnet",
        chainId: 1868,
        urls: {
          apiURL: "https://soneium.blockscout.com/api",
          browserURL: "https://soneium.blockscout.com",
        },
      },
    ],
  },
  sourcify: {
    enabled: true,
  },
  abiExporter: {
    path: "./data/abi",
    clear: true,
    flat: false,
  },
};
