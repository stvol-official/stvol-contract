const { ethers } = require("ethers");

function printHash(input) {
  const hashInput = ethers.keccak256(ethers.toUtf8Bytes(input));
  const subtractedValue = BigInt(hashInput) - 1n;
  const finalHash = ethers.keccak256("0x" + subtractedValue.toString(16).padStart(64, "0"));
  const finalHashBigInt = BigInt(`0x${finalHash.slice(2)}`);
  const maskBigInt = BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00");
  const maskedHashBigInt = finalHashBigInt & maskBigInt;
  const maskedHash = "0x" + maskedHashBigInt.toString(16).padStart(64, "0");
  console.log(maskedHash);
}

// keccak256(abi.encode(uint256(keccak256("supervolhourly.main")) - 1)) & ~bytes32(uint256(0xff));
printHash("supervolhourly.main");
