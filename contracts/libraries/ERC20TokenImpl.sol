// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20TokenImpl is ERC20 {
  uint8 _decimals;
  address _adminAddress;

  constructor(string memory _name, string memory _symbol, uint8 _dec, address _admin) ERC20(_name, _symbol) {
    _decimals = _dec;
    _adminAddress = _admin;
  }

  modifier onlyAdmin() {
    require(msg.sender == _adminAddress, "Contract not allowed");
    _;
  }

  function mint(uint amount) external onlyAdmin {
    _mint(msg.sender, amount);
  }

  function decimals() public view virtual override returns (uint8) {
    return _decimals;
  }
  function admin() external view returns (address) {
    return _adminAddress;
  }
}
