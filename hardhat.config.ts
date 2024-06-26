//import "@nomiclabs/hardhat-truffle5";
//import "@nomiclabs/hardhat-waffle";
//import "@nomiclabs/hardhat-etherscan";
//import "hardhat-abi-exporter";
//import "hardhat-gas-reporter";

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

const infuraKey = process.env.INFURA_KEY;

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more
export default {
  networks: {
    hardhat: {
      // forking: {
      //   url: `https://mainnet.infura.io/v3/${infuraKey}`,
      //   enabled: true,
      // },
      chainId: 31337,
    },
    localhost: {
      chainId: 31337,
    },
    mainnet: {
      url: `https://mainnet.infura.io/v3/${infuraKey}`,
      accounts: {
        mnemonic,
      },
      saveDeployments: true,
      chainId: 1,
    },
    arbitrum: {
      url: `https://arbitrum-mainnet.infura.io/v3/${infuraKey}`,
      gas: 22000000,
      allowUnlimitedContractSize: true,
      accounts: {
        mnemonic,
      },
      chainId: 42161,
    },
    sepolia: {
      url: `https://sepolia.infura.io/v3/${infuraKey}`,
      allowUnlimitedContractSize: true,
      accounts: {
        mnemonic,
      },
      chainId: 11155111,
    },
    arbitrum_sepolia: {
      url: `https://arbitrum-sepolia.infura.io/v3/${infuraKey}`,
      gas: 22000000,
      allowUnlimitedContractSize: true,
      accounts: {
        mnemonic,
      },
      chainId: 421614,
    },
    blast_sepolia: {
      url: "https://sepolia.blast.io",
      accounts: {
        mnemonic,
      },
      chainId: 168587773,
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
      mainnet: process.env.ETHERSCAN_KEY,
      goerli: process.env.ETHERSCAN_KEY,
      arbitrumOne: process.env.ARBITRUM_ETHERSCAN_KEY,
      arbitrumGoerli: process.env.ARBITRUM_ETHERSCAN_KEY,
      sepolia: process.env.ETHERSCAN_KEY,
      arbitrumSepolia: process.env.ARBITRUM_ETHERSCAN_KEY,
      blastSepolia: "blast_sepolia", // apiKey is not required, just set a placeholder
    },
    customChains: [
      {
        network: "arbitrumSepolia",
        chainId: 421614,
        urls: {
          apiURL: "https://api-sepolia.arbiscan.io/api",
          browserURL: "https://sepolia.arbiscan.io/",
        },
      },
      {
        network: "blastSepolia",
        chainId: 168587773,
        urls: {
          apiURL: "https://api-sepolia.blastscan.io/api",
          browserURL: "https://sepolia.blastscan.io/",
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
