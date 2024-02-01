import { ethers, artifacts, contract } from "hardhat";
import { assert } from "chai";
import { BN, constants, expectEvent, expectRevert, time, ether, balance } from "@openzeppelin/test-helpers";

const StVol = artifacts.require("StVol");
const Pyth = artifacts.require("/contracts/mocks/pyth/MockPyth.sol:MockPyth");
const MockERC20 = artifacts.require("/contracts/utils/MockERC20.sol");

const BLOCK_COUNT_MULTPLIER = 5;
const DECIMALS = 8; // Chainlink default for ETH/USD
const INITIAL_PRICE = 10000000000; // $100, 8 decimal places
const INTERVAL_SECONDS = 86400; // 24 * 60 * 60 * 1(1day)
const BUFFER_SECONDS = 1800; // 30 * 60 (30min)
const MIN_AMOUNT = 1000000 // 1 USDC
const UPDATE_ALLOWANCE = 30 * BLOCK_COUNT_MULTPLIER; // 30s * multiplier
const INITIAL_REWARD_RATE = 0.9; // 90%
const INITIAL_COMMISSION_RATE = 0.02; // 2%
const INITIAL_OPERATE_RATE = 0.3; // 30%
const INITIAL_PARTICIPATE_RATE = 0.7; // 70%
const MULTIPLIER = 10000;
const PRICE_100 = 100000000;
const PRICE_120 = 120000000;
const PRICE_150 = 150000000;

const enum STRIKE {
  _97 = 97,
  _99 = 99,
  _100 = 100,
  _101 = 101,
  _103 = 103,

}

// Enum: 0 = Over, 1 = Under
const Position = {
  Over: "0",
  Under: "1",
};
const LimitOrderStatus = {
  Undeclared: "0",
  Approve: "1",
  Cancelled: "2"

}

interface RoundResponse {
  epoch: number
  openTimestamp: number
  startTimestamp: number
  closeTimestamp: number
  startPrice: number
  closePrice: number
  startOracleId: number
  closeOracleId: number
  oracleCalled: boolean
  options: OptionResponse[] | any[]
}

interface OptionResponse {
  strike: number
  totalAmount: number
  overAmount: number
  underAmount: number
  rewardBaseCalAmount: number
  rewardAmount: number
}

const assertBNArray = (arr1: any[], arr2: any | any[]) => {
  assert.equal(arr1.length, arr2.length);
  arr1.forEach((n1, index) => {
    assert.equal(n1.toString(), new BN(arr2[index]).toString());
  });
};

contract(
  "StVol.v1",
  ([operator, admin, owner, overUser1, overUser2, overUser3, underUser1, underUser2, underUser3, participantVault, overLimitUser1, overLimitUser2, overLimitUser3, underLimitUser1, underLimitUser2, underLimitUser3]) => {
    // mock usdc total supply
    const _totalInitSupply = ether("10000000000");
    let currentEpoch: any;
    let pyth: any;
    let stVol: any;
    let mockUsdc: any;
    const priceId = '0x000000000000000000000000000000000000000000000000000000000000abcd';
    const validTimePeriod = 60;
    const singleUpdateFeeInWei = 1;

    async function nextEpoch(currentTimestamp: number) {
      await time.increaseTo(currentTimestamp + INTERVAL_SECONDS); // Elapse 20 seconds
    }

    async function getRoundInfo(epoch: number) {
      const round = (await stVol.viewRound(epoch) as RoundResponse);
      const options = round.options;
      // options.forEach((item, idx) => {
      //   console.log(`item: ${item} : idx: ${idx}`)
      // })
      return { round, options }
    }

    beforeEach(async () => {
      // Deploy USDC
      mockUsdc = await MockERC20.new("Mock USDC", "USDC", _totalInitSupply);
      // mint usdc for test accounts
      const MintAmount = ether("100"); // 100 USDC

      mockUsdc.mintTokens(MintAmount, { from: overUser1 });
      mockUsdc.mintTokens(MintAmount, { from: overUser2 });
      mockUsdc.mintTokens(MintAmount, { from: overUser3 });
      mockUsdc.mintTokens(MintAmount, { from: overLimitUser1 });
      mockUsdc.mintTokens(MintAmount, { from: overLimitUser2 });
      mockUsdc.mintTokens(MintAmount, { from: overLimitUser3 });
      mockUsdc.mintTokens(MintAmount, { from: underLimitUser1 });
      mockUsdc.mintTokens(MintAmount, { from: underLimitUser2 });
      mockUsdc.mintTokens(MintAmount, { from: underLimitUser3 });
      mockUsdc.mintTokens(MintAmount, { from: underUser1 });
      mockUsdc.mintTokens(MintAmount, { from: underUser2 });
      mockUsdc.mintTokens(MintAmount, { from: underUser3 });

      pyth = await Pyth.new(validTimePeriod, singleUpdateFeeInWei);

      stVol = await StVol.new(
        mockUsdc.address,
        pyth.address,
        admin,
        operator,
        participantVault,
        String(INITIAL_COMMISSION_RATE * 10000),
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
      mockUsdc.approve(stVol.address, ethers.constants.MaxUint256, { from: overLimitUser1 });
      mockUsdc.approve(stVol.address, ethers.constants.MaxUint256, { from: overLimitUser2 });
      mockUsdc.approve(stVol.address, ethers.constants.MaxUint256, { from: overLimitUser3 });
      mockUsdc.approve(stVol.address, ethers.constants.MaxUint256, { from: underLimitUser1 });
      mockUsdc.approve(stVol.address, ethers.constants.MaxUint256, { from: underLimitUser2 });
      mockUsdc.approve(stVol.address, ethers.constants.MaxUint256, { from: underLimitUser3 });
    });

    it("Initialize", async () => {
      assert.equal(await mockUsdc.balanceOf(stVol.address), 0);
      assert.equal(await stVol.currentEpoch(), 0);
      assert.equal(await stVol.adminAddress(), admin);
      assert.equal(await stVol.treasuryAmount(), 0);
      assert.equal(await stVol.genesisOpenOnce(), false);
      assert.equal(await stVol.genesisStartOnce(), false);
      assert.equal(await stVol.paused(), false);
      assert.equal(await stVol.availableOptionStrikes(0), STRIKE._97)
      assert.equal(await stVol.availableOptionStrikes(1), STRIKE._99)
      assert.equal(await stVol.availableOptionStrikes(2), STRIKE._100)
      assert.equal(await stVol.availableOptionStrikes(3), STRIKE._101)
      assert.equal(await stVol.availableOptionStrikes(4), STRIKE._103)
    });

    it("Should start genesis rounds (round 1, round 2, round 3)", async () => {
      // Manual block calculation
      let currentTimestamp = (await time.latest()).toNumber();

      // Epoch 0
      assert.equal((await time.latest()).toNumber(), currentTimestamp);
      assert.equal(await stVol.currentEpoch(), 0);

      // Epoch 1: Start genesis round 1
      let tx = await stVol.genesisOpenRound(currentTimestamp);

      const eventOpenRound = expectEvent(tx, "OpenRound", {
        epoch: new BN(1),
        initDate: new BN(currentTimestamp),
        // strikes: [new BN(97),new BN(99),new BN(100),new BN(101),new BN(103)] // [CAUTION] Does not support arrays of bignumbers.
      });
      assertBNArray(eventOpenRound.args["strikes"], [STRIKE._97, STRIKE._99, STRIKE._100, STRIKE._101, STRIKE._103])
      assert.equal(await stVol.currentEpoch(), 1);

      // Start round 1
      assert.equal(await stVol.genesisOpenOnce(), true);
      assert.equal(await stVol.genesisStartOnce(), false);
      assert.equal((await stVol.rounds(1)).openTimestamp, currentTimestamp);
      assert.equal((await stVol.rounds(1)).startTimestamp, currentTimestamp + INTERVAL_SECONDS);
      assert.equal((await stVol.rounds(1)).closeTimestamp, currentTimestamp + INTERVAL_SECONDS * 2);
      assert.equal((await stVol.rounds(1)).epoch, 1);

      let round = await getRoundInfo(1)
      assertBNArray(round.options[0], [STRIKE._97, 0, 0, 0, 0, 0]);
      assertBNArray(round.options[1], [STRIKE._99, 0, 0, 0, 0, 0]);
      assertBNArray(round.options[2], [STRIKE._100, 0, 0, 0, 0, 0]);
      assertBNArray(round.options[3], [STRIKE._101, 0, 0, 0, 0, 0]);
      assertBNArray(round.options[4], [STRIKE._103, 0, 0, 0, 0, 0]);

      // Elapse 20 blocks
      currentTimestamp += INTERVAL_SECONDS;
      await time.increaseTo(currentTimestamp);
      // update pythPrice updateData
      let updateData = await pyth.createPriceFeedUpdateData(priceId, PRICE_100, 10 * PRICE_100, -5, PRICE_100, 10 * PRICE_100, currentTimestamp);
      let requiredFee = await pyth.getUpdateFee([updateData]);

      await pyth.updatePriceFeeds([updateData], { value: requiredFee });

      // Epoch 2: Lock genesis round 1 and starts round 2
      tx = await stVol.genesisStartRound([updateData], currentTimestamp, false, { value: requiredFee });

      expectEvent(tx, "StartRound", {
        epoch: new BN(1),
        price: new BN(PRICE_100),
      });

      expectEvent(tx, "OpenRound", { epoch: new BN(2) });
      assert.equal(await stVol.currentEpoch(), 2);

      // Lock round 1
      assert.equal(await stVol.genesisOpenOnce(), true);
      assert.equal(await stVol.genesisStartOnce(), true);
      assert.equal((await stVol.rounds(1)).startPrice, PRICE_100);

      // Start round 2
      assert.equal((await stVol.rounds(2)).openTimestamp, currentTimestamp);
      assert.equal((await stVol.rounds(2)).startTimestamp, currentTimestamp + INTERVAL_SECONDS);
      assert.equal((await stVol.rounds(2)).closeTimestamp, currentTimestamp + 2 * INTERVAL_SECONDS);
      assert.equal((await stVol.rounds(2)).epoch, 2);
      round = await getRoundInfo(1)

      assertBNArray(round.options[0], [STRIKE._97, 0, 0, 0, 0, 0]);
      assertBNArray(round.options[1], [STRIKE._99, 0, 0, 0, 0, 0]);
      assertBNArray(round.options[2], [STRIKE._100, 0, 0, 0, 0, 0]);
      assertBNArray(round.options[3], [STRIKE._101, 0, 0, 0, 0, 0]);
      assertBNArray(round.options[4], [STRIKE._103, 0, 0, 0, 0, 0]);

      // Elapse 20 blocks
      currentTimestamp += INTERVAL_SECONDS;
      await time.increaseTo(currentTimestamp);
      // update pythPrice updateData
      updateData = await pyth.createPriceFeedUpdateData(priceId, PRICE_120, 10 * PRICE_120, -5, PRICE_120, 10 * PRICE_120, currentTimestamp);
      requiredFee = await pyth.getUpdateFee([updateData]);

      await pyth.updatePriceFeeds([updateData], { value: requiredFee });

      // Epoch 3: End genesis round 1, locks round 2, starts round 3
      tx = await stVol.executeRound([updateData], currentTimestamp, false, { value: requiredFee });

      expectEvent(tx, "EndRound", {
        epoch: new BN(1),
        price: new BN(PRICE_120),
      });

      expectEvent(tx, "StartRound", {
        epoch: new BN(2),
        price: new BN(PRICE_120),
      });

      expectEvent(tx, "OpenRound", { epoch: new BN(3) });
      assert.equal(await stVol.currentEpoch(), 3);

      // End round 1
      assert.equal((await stVol.rounds(1)).closePrice, PRICE_120);

      // Lock round 2
      assert.equal((await stVol.rounds(2)).startPrice, PRICE_120);
    });

    it("Should participate with strike by user", async () => {
      let currentTimestamp = (await time.latest()).toNumber();
      let idx = 0;

      // Epoch 1
      await stVol.genesisOpenRound(currentTimestamp);
      currentEpoch = await stVol.currentEpoch();

      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Over, ether("1.1"), { from: overUser1 }); // 1.1 USDC
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Over, ether("1.2"), { from: overUser2 }); // 1.2 USDC
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Under, ether("1.4"), { from: underUser1 }); // 1.4 USDC

      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("3.7").toString()); // 3.7 USDC
      let round = await getRoundInfo(currentEpoch);
      let [options_97, options_99, options_100, options_101, options_102] = round.options;

      assert.equal(options_100.totalAmount, ether("3.7").toString()); // 3.7 USDC
      assert.equal(options_100.overAmount, ether("2.3").toString()); // 2.3 USDC
      assert.equal(options_100.underAmount, ether("1.4").toString()); // 1.4 USDC

      // strike, epoch, idx, amount, position, claimed, isCancelled
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, overUser1))[0], ["100", "1", (++idx).toString(), ether("1.1").toString(), '0', false, false]);
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, overUser2))[0], ["100", "1", (++idx).toString(), ether("1.2").toString(), '0', false, false]);
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, underUser1))[0], ["100", "1", (++idx).toString(), ether("1.4").toString(), '1', false, false]);

      // Epoch 2
      currentTimestamp += INTERVAL_SECONDS;
      await time.increaseTo(currentTimestamp);
      // update pythPrice updateData
      let updateData = await pyth.createPriceFeedUpdateData(priceId, PRICE_100, 10 * PRICE_100, -5, PRICE_100, 10 * PRICE_100, currentTimestamp);
      let requiredFee = await pyth.getUpdateFee([updateData]);

      await pyth.updatePriceFeeds([updateData], { value: requiredFee });
      // reset idx is 0
      idx = 0;

      await stVol.genesisStartRound([updateData], currentTimestamp, true, { value: requiredFee }); // For round 1
      currentEpoch = await stVol.currentEpoch();

      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Over, ether("2.1"), { from: overUser1 }); // 2.1 USDC
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Over, ether("2.2"), { from: overUser2 }); // 2.2 USDC
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Under, ether("2.4"), { from: underUser1 }); // 2.4 USDC

      round = await getRoundInfo(currentEpoch);
      [options_97, options_99, options_100, options_101, options_102] = round.options;

      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("10.4").toString()); // 10.4 USDC (3.7+6.7)
      assert.equal(options_100.totalAmount, ether("6.7").toString()); // 2.1 USDC
      assert.equal(options_100.overAmount, ether("4.3").toString()); // 2.2 USDC
      assert.equal(options_100.underAmount, ether("2.4").toString()); // 2.4 USDC

      // strike, epoch, idx, amount, position, claimed, isCancelled
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, overUser1))[0], ["100", "2", (++idx).toString(), ether("2.1").toString(), '0', false, false]);
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, overUser2))[0], ["100", "2", (++idx).toString(), ether("2.2").toString(), '0', false, false]);
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, underUser1))[0], ["100", "2", (++idx).toString(), ether("2.4").toString(), '1', false, false]);

      // Epoch 3
      currentTimestamp += INTERVAL_SECONDS;
      await time.increaseTo(currentTimestamp);

      updateData = await pyth.createPriceFeedUpdateData(priceId, PRICE_100, 10 * PRICE_100, -5, PRICE_100, 10 * PRICE_100, currentTimestamp);
      requiredFee = await pyth.getUpdateFee([updateData]);

      await pyth.updatePriceFeeds([updateData], { value: requiredFee });
      // reset idx is 0
      idx = 0;

      await stVol.executeRound([updateData], currentTimestamp, true, { value: requiredFee });
      currentEpoch = await stVol.currentEpoch();

      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Over, ether("3.1"), { from: overUser1 }); // 3.1 USDC
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Over, ether("3.2"), { from: overUser2 }); // 3.2 USDC
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Under, ether("3.4"), { from: underUser1 }); // 3.4 USDC

      round = await getRoundInfo(currentEpoch);
      [options_97, options_99, options_100, options_101, options_102] = round.options;

      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("20.1").toString()); // 20.1 USDC (3.7+6.7+9.7)
      assert.equal(options_100.totalAmount, ether("9.7").toString()); // 9.7 USDC
      assert.equal(options_100.overAmount, ether("6.3").toString()); // 6.3 USDC
      assert.equal(options_100.underAmount, ether("3.4").toString()); // 3.4 USDC

      // strike, epoch, idx, amount, position, claimed, isCancelled
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, overUser1))[0], ["100", "3", (++idx).toString(), ether("3.1").toString(), '0', false, false]);
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, overUser2))[0], ["100", "3", (++idx).toString(), ether("3.2").toString(), '0', false, false]);
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, underUser1))[0], ["100", "3", (++idx).toString(), ether("3.4").toString(), '1', false, false]);

      // Epoch 4
      currentTimestamp += INTERVAL_SECONDS;
      await time.increaseTo(currentTimestamp);

      updateData = await pyth.createPriceFeedUpdateData(priceId, PRICE_100, 10 * PRICE_100, -5, PRICE_100, 10 * PRICE_100, currentTimestamp);
      requiredFee = await pyth.getUpdateFee([updateData]);
      await pyth.updatePriceFeeds([updateData], { value: requiredFee });
      // reset idx is 0
      idx = 0;

      await stVol.executeRound([updateData], currentTimestamp, true, { value: requiredFee });
      currentEpoch = await stVol.currentEpoch();

      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Over, ether("4.1"), { from: overUser1 }); // 4.1 USDC
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Over, ether("4.2"), { from: overUser2 }); // 4.2 USDC
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Under, ether("4.4"), { from: underUser1 }); // 4.4 USDC

      round = await getRoundInfo(currentEpoch);
      [options_97, options_99, options_100, options_101, options_102] = round.options;

      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("32.8").toString()); // 32.8 USDC (3.7+6.7+9.7+12.7)
      assert.equal(options_100.totalAmount, ether("12.7").toString()); // 12.7 USDC
      assert.equal(options_100.overAmount, ether("8.3").toString()); // 8.3 USDC
      assert.equal(options_100.underAmount, ether("4.4").toString()); // 4.4 USDC

      // strike, epoch, idx, amount, position, claimed, isCancelled
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, overUser1))[0], ["100", "4", (++idx).toString(), ether("4.1").toString(), '0', false, false]);
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, overUser2))[0], ["100", "4", (++idx).toString(), ether("4.2").toString(), '0', false, false]);
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, underUser1))[0], ["100", "4", (++idx).toString(), ether("4.4").toString(), '1', false, false]);
    });

    it("Should refund all user's participant amount when round is fail", async () => {
      let currentTimestamp = (await time.latest()).toNumber();
      await time.increaseTo(currentTimestamp);
      let prevIdx = 0;

      // Epoch 1
      await stVol.genesisOpenRound(currentTimestamp);
      currentEpoch = await stVol.currentEpoch();
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Under, ether("10"), { from: underUser1 });

      // place limit order
      let limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._100, ether("1"), Position.Over, new BN(2 * MULTIPLIER), prevIdx, { from: overLimitUser1 }); // payout:2x


      let expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(2),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(2 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(Position.Over),
        status: new BN(LimitOrderStatus.Undeclared)
      });

      limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._100, ether("1"), Position.Over, new BN(2 * MULTIPLIER), prevIdx, { from: overLimitUser1 }); // payout:2x
      expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(3),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(2 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(0),
        status: new BN(0)
      });

      limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._100, ether("1"), Position.Over, new BN(2 * MULTIPLIER), prevIdx, { from: overLimitUser1 }); // payout:2x
      expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(4),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(2 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(0),
        status: new BN(0)
      });

      limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._100, ether("1"), Position.Over, new BN(2 * MULTIPLIER), prevIdx, { from: overLimitUser1 }); // payout:2x
      expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(5),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(2 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(Position.Over),
        status: new BN(LimitOrderStatus.Undeclared)
      });

      limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._100, ether("1"), Position.Over, new BN(2 * MULTIPLIER), prevIdx, { from: overLimitUser1 }); // payout:2x
      expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(6),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(2 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(Position.Over),
        status: new BN(LimitOrderStatus.Undeclared)
      });


      limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._100, ether("1"), Position.Under, new BN(5 * MULTIPLIER), 0, { from: underLimitUser1 }); // payout:5x
      expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(7),
        sender: underLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(5 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(Position.Under),
        status: new BN(LimitOrderStatus.Undeclared)
      });

      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("16").toString());

      // Epoch 2
      // execute limit order 
      currentTimestamp += INTERVAL_SECONDS * 2 + BUFFER_SECONDS;
      await time.increaseTo(currentTimestamp);

      await stVol.claimAll({ from: overLimitUser1 })
      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("11").toString());

      await stVol.pause({ from: admin });
      await stVol.redeemAll(underLimitUser1, { from: admin });
      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("10").toString());

      await stVol.claimAll({ from: underUser1 });
      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("0").toString());
    });

    it("Should place limit order with different payout", async () => {
      let currentTimestamp = (await time.latest()).toNumber();
      await time.increaseTo(currentTimestamp);
      let prevIdx = 0;

      // Epoch 1
      await stVol.genesisOpenRound(currentTimestamp);
      currentEpoch = await stVol.currentEpoch();
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Under, ether("10"), { from: underUser1 });

      // place limit order
      let limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._100, ether("1"), Position.Over, new BN(2 * MULTIPLIER), prevIdx, { from: overLimitUser1 }); // payout:2x
      let expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(2),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(2 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(Position.Over),
        status: new BN(LimitOrderStatus.Undeclared)
      });

      limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._100, ether("1"), Position.Over, new BN(2.1 * MULTIPLIER), prevIdx, { from: overLimitUser1 }); // payout:2x
      expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(3),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(2.1 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(0),
        status: new BN(0)
      });

      limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._100, ether("1"), Position.Over, new BN(2.3 * MULTIPLIER), 2, { from: overLimitUser1 }); // payout:2x
      expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(4),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(2.3 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(Position.Over),
        status: new BN(LimitOrderStatus.Undeclared)
      });
    });
    it("Should cancel market orders", async () => {
      let currentTimestamp = (await time.latest()).toNumber();
      await time.increaseTo(currentTimestamp);

      // Epoch 1
      await stVol.genesisOpenRound(currentTimestamp);
      currentEpoch = await stVol.currentEpoch();
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Under, ether("10"), { from: underUser1 });
      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("10").toString());

      let round = await getRoundInfo(currentEpoch);
      let [options_97, options_99, options_100, options_101, options_102] = round.options;

      assert.equal(options_100.totalAmount, ether("10").toString());
      assert.equal(options_100.overAmount, ether("0").toString());
      assert.equal(options_100.underAmount, ether("10").toString());

      await stVol.cancelMarketOrder(currentEpoch, 1, STRIKE._100, { from: underUser1 });
      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("0").toString());

      round = await getRoundInfo(currentEpoch);
      [options_97, options_99, options_100, options_101, options_102] = round.options;

      assert.equal(options_100.totalAmount, ether("0").toString());
      assert.equal(options_100.overAmount, ether("0").toString());
      assert.equal(options_100.underAmount, ether("0").toString());

      // strike, epoch, idx, amount, position, claimed, isCancelled
      assert.includeOrderedMembers((await stVol.viewUserLedger(currentEpoch, STRIKE._100, underUser1))[0], ["100", "1", "1", ether("10").toString(), Position.Under, false, true]);
    });

    it("Should cancel limit orders", async () => {
      let currentTimestamp = (await time.latest()).toNumber();
      await time.increaseTo(currentTimestamp);
      let prevIdx = 0;

      // Epoch 1
      await stVol.genesisOpenRound(currentTimestamp);
      currentEpoch = await stVol.currentEpoch();

      let limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._99, ether("1"), Position.Over, new BN(2 * MULTIPLIER), prevIdx, { from: overLimitUser1 });
      let expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(1),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._99.toString(),
        amount: ether("1"),
        payout: new BN(2 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(Position.Over),
        status: new BN(LimitOrderStatus.Undeclared)
      });

      limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._100, ether("1"), Position.Over, new BN(2 * MULTIPLIER), prevIdx, { from: overLimitUser1 });
      expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(2),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(2 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(Position.Over),
        status: new BN(LimitOrderStatus.Undeclared)
      });
      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("2").toString());

      let round = await getRoundInfo(currentEpoch);
      let [options_97, options_99, options_100, options_101, options_102] = round.options;

      assert.equal(options_99.totalAmount, ether("0").toString());
      assert.equal(options_99.overAmount, ether("0").toString());
      assert.equal(options_99.underAmount, ether("0").toString());
      assert.equal(options_100.totalAmount, ether("0").toString());
      assert.equal(options_100.overAmount, ether("0").toString());
      assert.equal(options_100.underAmount, ether("0").toString());

      limitOrderTx = await stVol.cancelLimitOrder(currentEpoch, 1, STRIKE._99, Position.Over, { from: overLimitUser1 });
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(1),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._99.toString(),
        amount: ether("1"),
        payout: new BN(2 * MULTIPLIER),
        // placeTimestamp: new BN(expectedTimestamp),
        position: new BN(Position.Over),
        status: new BN(LimitOrderStatus.Cancelled)
      });
      limitOrderTx = await stVol.cancelLimitOrder(currentEpoch, 2, STRIKE._100, Position.Over, { from: overLimitUser1 });
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(2),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(2 * MULTIPLIER),
        // placeTimestamp: new BN(expectedTimestamp),
        position: new BN(Position.Over),
        status: new BN(LimitOrderStatus.Cancelled)
      });
      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("0").toString());
    });

    it("Should place market orders when round is starting", async () => {
      let currentTimestamp = (await time.latest()).toNumber();
      await time.increaseTo(currentTimestamp);
      let prevIdx = 0;

      // Epoch 1
      await stVol.genesisOpenRound(currentTimestamp);
      currentEpoch = await stVol.currentEpoch();

      // place an under market order 
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Under, ether("2"), { from: underUser1 });

      let limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._100, ether("1"), Position.Over, new BN(2 * MULTIPLIER), prevIdx, { from: overLimitUser1 });
      let expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(2),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(2 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(Position.Over),
        status: new BN(LimitOrderStatus.Undeclared)
      });

      limitOrderTx = await stVol.placeLimitOrder(currentEpoch, STRIKE._100, ether("1"), Position.Over, new BN(2.1 * MULTIPLIER), prevIdx, { from: overLimitUser1 });
      expectedTimestamp = (await time.latest()).toNumber();
      expectEvent(limitOrderTx, "PlaceLimitOrder", {
        idx: new BN(3),
        sender: overLimitUser1,
        epoch: currentEpoch,
        strike: STRIKE._100.toString(),
        amount: ether("1"),
        payout: new BN(2.1 * MULTIPLIER),
        placeTimestamp: new BN(expectedTimestamp),
        position: new BN(Position.Over),
        status: new BN(LimitOrderStatus.Undeclared)
      });
      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("4").toString());

      // Epoch 2
      currentTimestamp += INTERVAL_SECONDS;
      await time.increaseTo(currentTimestamp);
      // update pythPrice updateData
      let updateData = await pyth.createPriceFeedUpdateData(priceId, PRICE_100, 10 * PRICE_100, -5, PRICE_100, 10 * PRICE_100, currentTimestamp);
      let requiredFee = await pyth.getUpdateFee([updateData]);

      await pyth.updatePriceFeeds([updateData], { value: requiredFee });
      await stVol.genesisStartRound([updateData], currentTimestamp, true, { value: requiredFee }); // For round 1
      currentEpoch = await stVol.currentEpoch();

      let round = await getRoundInfo(1);
      let [options_97, options_99, options_100, options_101, options_102] = round.options;

      assert.equal((await mockUsdc.balanceOf(stVol.address)).toString(), ether("3").toString()); // under:2, over limit(payout: 2): 1, refund: 1
      assert.equal(options_100.totalAmount, ether("3").toString());
      assert.equal(options_100.overAmount, ether("1").toString());
      assert.equal(options_100.underAmount, ether("2").toString());
    });

    it("Should claim rewards", async () => {
      let currentTimestamp = (await time.latest()).toNumber();
      await time.increaseTo(currentTimestamp);

      // Epoch 1
      await stVol.genesisOpenRound(currentTimestamp);
      currentEpoch = await stVol.currentEpoch();

      // place an under market order 
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Over, ether("2"), { from: overUser1 });
      await stVol.placeMarketOrder(currentEpoch, STRIKE._100, Position.Under, ether("2"), { from: underUser1 });

      assert.equal(await stVol.claimable(1, STRIKE._100, 1, overUser1), false);
      assert.equal(await stVol.claimable(1, STRIKE._100, 2, underUser1), false);

      // Elapse 20 blocks
      currentTimestamp += INTERVAL_SECONDS;
      await time.increaseTo(currentTimestamp);
      // update pythPrice updateData
      let updateData = await pyth.createPriceFeedUpdateData(priceId, PRICE_100, 10 * PRICE_100, -5, PRICE_100, 10 * PRICE_100, currentTimestamp);
      let requiredFee = await pyth.getUpdateFee([updateData]);

      await pyth.updatePriceFeeds([updateData], { value: requiredFee });

      // Epoch 2: Lock genesis round 1 and starts round 2
      let tx = await stVol.genesisStartRound([updateData], currentTimestamp, false, { value: requiredFee });

      // Epoch 3
      currentTimestamp += INTERVAL_SECONDS;
      await time.increaseTo(currentTimestamp);

      updateData = await pyth.createPriceFeedUpdateData(priceId, PRICE_120, 10 * PRICE_120, -5, PRICE_120, 10 * PRICE_120, currentTimestamp);
      requiredFee = await pyth.getUpdateFee([updateData]);

      await pyth.updatePriceFeeds([updateData], { value: requiredFee });

      await stVol.executeRound([updateData], currentTimestamp, true, { value: requiredFee });
      currentEpoch = await stVol.currentEpoch();

      assert.equal(await stVol.claimable(1, STRIKE._100, 1, overUser1), true);
      assert.equal(await stVol.claimable(1, STRIKE._100, 2, underUser1), false);

      tx = await stVol.claim(1, STRIKE._100, 1, { from: overUser1 });
      expectEvent(tx, "Claim", { sender: overUser1, epoch: new BN("1"), strike: STRIKE._100.toString(), position: Position.Over, amount: ether("3.96") });
    });
  }
);