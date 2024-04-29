// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20TokenImpl is ERC20 {
  uint8 _decimals;

  constructor(string memory _name, string memory _symbol, uint8 _dec) ERC20(_name, _symbol) {
    _decimals = _dec;
  }

  function mint(uint amount) external {
    _mint(msg.sender, amount);
  }

  function decimals() public view virtual override returns (uint8) {
    return _decimals;
  }
}
