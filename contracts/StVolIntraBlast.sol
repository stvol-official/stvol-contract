// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { StVolIntra } from "./StVolIntra.sol";

enum YieldMode {
  AUTOMATIC,
  VOID,
  CLAIMABLE
}

interface IERC20Rebasing {
  // changes the yield mode of the caller and update the balance
  // to reflect the configuration
  function configure(YieldMode) external returns (uint256);

  // "claimable" yield mode accounts can call this this claim their yield
  // to another address
  function claim(address recipient, uint256 amount) external returns (uint256);

  // read the claimable amount for an account
  function getClaimableAmount(address account) external view returns (uint256);
}

enum GasMode {
  VOID,
  CLAIMABLE
}

interface IBlast {
  // Note: the full interface for IBlast can be found below
  function configureClaimableGas() external;

  function claimAllGas(address contractAddress, address recipient) external returns (uint256);

  function claimMaxGas(address contractAddress, address recipientOfGas) external returns (uint256);

  function readGasParams(
    address contractAddress
  )
    external
    view
    returns (uint256 etherSeconds, uint256 etherBalance, uint256 lastUpdated, GasMode);
}

contract StVolIntraBlast is StVolIntra {
  // NOTE: these addresses will be slightly different on the Blast mainnet
  IERC20 public constant USDB = IERC20(0x0B8a205c26ECFc423DE29a8EF18e1229a0Cc4F47);
  IERC20Rebasing public constant WETH = IERC20Rebasing(0x4200000000000000000000000000000000000023);
  IBlast public constant BLAST = IBlast(0x4300000000000000000000000000000000000002);

  constructor(
    address _oracleAddress,
    address _adminAddress,
    address _operatorAddress,
    address _operatorVaultAddress,
    uint256 _commissionfee,
    bytes32 _priceId
  )
    StVolIntra(
      address(USDB),
      _oracleAddress,
      _adminAddress,
      _operatorAddress,
      _operatorVaultAddress,
      _commissionfee,
      _priceId
    )
  {
    // USDB.configure(YieldMode.CLAIMABLE); //configure claimable yield for USDB
    WETH.configure(YieldMode.CLAIMABLE); //configure claimable yield for WETH

    BLAST.configureClaimableGas();

    ONE_TOKEN = 10 ** 18;
    HUNDRED_TOKEN = 100 * ONE_TOKEN;
  }

  function getClaimableYield(address tokenAddress) external view onlyOwner returns (uint256) {
    return IERC20Rebasing(tokenAddress).getClaimableAmount(address(this));
  }

  function claimYield(
    address tokenAddress,
    address recipient
  ) external onlyOwner returns (uint256 claimAmount) {
    IERC20Rebasing token = IERC20Rebasing(tokenAddress);
    claimAmount = token.getClaimableAmount(address(this));
    token.claim(recipient, claimAmount);
  }

  function getClaimableGas()
    external
    view
    onlyOwner
    returns (uint256 etherSeconds, uint256 etherBalance, uint256 lastUpdated, GasMode)
  {
    return BLAST.readGasParams(address(this));
  }

  function claimAllGas(address recipient) external onlyOwner returns (uint256) {
    return BLAST.claimAllGas(address(this), recipient);
  }

  function claimMaxGas(address recipient) external onlyOwner returns (uint256) {
    return BLAST.claimMaxGas(address(this), recipient);
  }
}
