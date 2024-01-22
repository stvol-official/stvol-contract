import { ethers, artifacts, contract } from "hardhat";
import { assert } from "chai";
import { BN, constants, expectEvent, expectRevert, time, ether, balance } from "@openzeppelin/test-helpers";

const StVolIntra = artifacts.require("StVolIntra");
const Oracle = artifacts.require("./mocks/pyth/MockPyth.sol");
const MockERC20 = artifacts.require("./utils/MockERC20.sol");

const GAS_PRICE = 8000000000; // hardhat default
const BLOCK_COUNT_MULTPLIER = 5;
const DECIMALS = 8; // Chainlink default for ETH/USD
const INITIAL_PRICE = 10000000000; // $100, 8 decimal places
const INTERVAL_SECONDS = 20 * BLOCK_COUNT_MULTPLIER; // 20 seconds * multiplier
const BUFFER_SECONDS = 5 * BLOCK_COUNT_MULTPLIER; // 5 seconds * multplier, round must lock/end within this buffer
const MIN_AMOUNT = ether("0.000001"); // 1 USDC
const UPDATE_ALLOWANCE = 30 * BLOCK_COUNT_MULTPLIER; // 30s * multiplier
const INITIAL_REWARD_RATE = 0.9; // 90%
const INITIAL_COMMISSION_RATE = 0.02; // 2%
const INITIAL_OPERATE_RATE = 0.3; // 30%
const INITIAL_PARTICIPATE_RATE = 0.7; // 70%


contract(
    'StVolIntra', 
    ([operator, admin, owner, overUser1, overUser2, overUser3, underUser1, underUser2, underUser3, participantVault]) => {
    // mock usdc total supply
    const _totalInitSupply = ether("10000000000");

    let stVol: any;
    let mockUsdc: any;
    let oracle: any;

    beforeEach(async () => {
        // Deploy USDC
        mockUsdc = await MockERC20.new("Mock USDC", "USDC", _totalInitSupply);
        // mint usdc for test accounts
        const MintAmount = ether("100"); // 100 USDC
  
        mockUsdc.mintTokens(MintAmount, { from: overUser1 });
        mockUsdc.mintTokens(MintAmount, { from: overUser2 });
        mockUsdc.mintTokens(MintAmount, { from: overUser3 });
        mockUsdc.mintTokens(MintAmount, { from: underUser1 });
        mockUsdc.mintTokens(MintAmount, { from: underUser2 });
        mockUsdc.mintTokens(MintAmount, { from: underUser3 });
  
        oracle = await Oracle.new(0, 0, { from: owner });
  
        stVol = await StVolIntra.new(
          mockUsdc.address,
          oracle.address,
          admin,
          operator,
          participantVault,
          INITIAL_COMMISSION_RATE * 10000,
          ethers.utils.hexZeroPad("0x2", 32),
          { from: owner }
        );
        // approve usdc amount for stVol contract
        mockUsdc.approve(stVol.address, ethers.constants.MaxUint256, { from: overUser1 });
        mockUsdc.approve(stVol.address, ethers.constants.MaxUint256, { from: overUser2 });
        mockUsdc.approve(stVol.address, ethers.constants.MaxUint256, { from: overUser3 });
        mockUsdc.approve(stVol.address, ethers.constants.MaxUint256, { from: underUser1 });
        mockUsdc.approve(stVol.address, ethers.constants.MaxUint256, { from: underUser2 });
        mockUsdc.approve(stVol.address, ethers.constants.MaxUint256, { from: underUser3 });
      });


      it("Should start genesis rounds", async () => {
        console.log("Starting genesis rounds");

        // FIXME: this should return a valid value
        const updateDate = await oracle.createPriceFeedUpdateData(
            ethers.utils.hexZeroPad("0x1983479347", 32),
            100000,
            0,
            0,
            0,
            0,
            0,
            0
        );


        await stVol.genesisStartRound([updateDate], 0, false);

      });
  
    
});