// for blast sepolia
const usdc = '0xe722424e913f48bAC7CD2C1Ae981e2cD09bd95EC';
const oracle = '0xA2aa501b19aff244D90cc15a4Cf739D2725B5729'; // PythContractAddress
const admin = '0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0';
const operator = '0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0';
const operatorVault = '0xC61042a7e9a6fe7E738550f24030D37Ecb296DC0';
const commissionFee = 200; // 2%
// const priceId = "0xca80ba6dc32e08d06f1aa886011eed1d77c77be9eb761cc10d72b7d0a2fd57a6"; // ETH/USD
const priceId = "0xf9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b"; // BTC/USD

module.exports = [
    usdc,
    oracle,
    admin,
    operator,
    operatorVault,
    commissionFee,
    priceId
];