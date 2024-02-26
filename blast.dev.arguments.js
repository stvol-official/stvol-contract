// for blast sepolia
const usdc = '0xe722424e913f48bAC7CD2C1Ae981e2cD09bd95EC';
const oracle = '0xA2aa501b19aff244D90cc15a4Cf739D2725B5729'; // PythContractAddress
const admin = '0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0';
const operator = '0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0';
const operatorVault = '0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0';
const commissionFee = 200; // 2%
const priceId = "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"; // ETH/USD
// const priceId = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43"; // BTC/USD

module.exports = [
    usdc,
    oracle,
    admin,
    operator,
    operatorVault,
    commissionFee,
    priceId
];