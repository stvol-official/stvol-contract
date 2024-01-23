import { ethers, artifacts, contract } from "hardhat";
import { assert } from "chai";
import { BN, constants, expectEvent, expectRevert, time, ether, balance } from "@openzeppelin/test-helpers";

const StVolIntra = artifacts.require("StVolIntraTest");
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
    'StVolIntraTest', 
    ([operator, admin, owner, overUser1, overUser2, overUser3, underUser1, underUser2, underUser3, participantVault]) => {
    // mock usdc total supply
    const _totalInitSupply = ether("10000000000");

    const priceId = '0x000000000000000000000000000000000000000000000000000000000000abcd';
    const FIRST_PRICE = 100000;

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
  
        oracle = await Oracle.new(60, 0);
  
        stVol = await StVolIntra.new(
          mockUsdc.address,
          oracle.address,
          admin,
          operator,
          participantVault,
          INITIAL_COMMISSION_RATE * 10000,
          priceId,
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

        const currentTimestamp = (await time.latest()).toNumber();
        console.log("current time is ", currentTimestamp);

        const updateData = await oracle.createPriceFeedUpdateData(priceId, FIRST_PRICE, 10 * FIRST_PRICE, -5, FIRST_PRICE, 10 * FIRST_PRICE, currentTimestamp);

        await oracle.updatePriceFeeds([updateData]);
        await stVol.genesisStartRound([updateData], currentTimestamp, false);


        const OVER = 0, UNDER = 1;

        console.log("place over orders");
        await stVol.submitLimitOrder(1, 100, OVER, 1000000, 10, 0, {from: overUser1});
        await stVol.submitLimitOrder(1, 100, OVER, 99000000, 10, 0, {from: overUser2});
        await stVol.submitLimitOrder(1, 100, OVER, 50000000, 10, 0, {from: overUser3});

        console.log("place under orders");
        await stVol.submitLimitOrder(1, 100, UNDER, 2000000, 15, 0, {from: underUser1});
        await stVol.submitLimitOrder(1, 100, UNDER, 55000000, 15, 0, {from: underUser2});
        await stVol.submitLimitOrder(1, 100, UNDER, 98000000, 10, 0, {from: underUser3});
        await stVol.submitLimitOrder(1, 100, UNDER, 99000000, 5, 0, {from: underUser3});

        await stVol.submitLimitOrder(1, 100, UNDER, 99000000, 15, 0, {from: underUser1});
        await stVol.submitLimitOrder(1, 100, UNDER, 88000000, 15, 0, {from: underUser2});
        await stVol.submitLimitOrder(1, 100, UNDER, 77000000, 10, 0, {from: underUser3});
        await stVol.submitLimitOrder(1, 100, UNDER, 66000000, 5, 0, {from: underUser3});

        await stVol.printOrders(1, 100);

        const values = await stVol.getTotalMarketPrice(1, 100, OVER, 35, {from: underUser1});
        console.log('total unit:' + values[0] + ', total price: ' + values[1] + ', average price: ' + (values[1] / values[0]));

        await stVol.executeMarketOrder(1, 100, OVER, 33000000, 50, {from: underUser1});

        await stVol.printOrders(1, 100);



      });
  
    
});