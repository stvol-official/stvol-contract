// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { VaultStorage } from "../storage/VaultStorage.sol";
import { IVaultErrors } from "../errors/VaultErrors.sol";
import "../types/Types.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract Vault is
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  IVaultErrors
{
  using Math for uint256;
  uint256 private constant BASE = 10000; // 100%

  event VaultTransaction(
    address indexed product,
    address indexed vault,
    address indexed user,
    uint256 amount,
    bool isDeposit,
    uint256 depositBalance,
    uint256 currentBalance
  );
  event VaultCreated(
    address indexed product,
    address indexed vault,
    address indexed leader,
    uint256 sharePercentage
  );
  event VaultClosed(address indexed product, address indexed vault, address indexed leader);
  event DebugLog(string message);

  modifier onlyAdmin() {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    if (msg.sender != $.adminAddress) revert OnlyAdmin();
    _;
  }

  modifier onlyOperator() {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    if (!$.operators[msg.sender]) revert OnlyOperator();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address _adminAddress) public initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);
    __Pausable_init();
    __ReentrancyGuard_init();

    if (_adminAddress == address(0)) revert InvalidAddress();

    VaultStorage.Layout storage $ = VaultStorage.layout();
    $.adminAddress = _adminAddress;
  }

  function createVault(
    address product,
    address leader,
    uint256 sharePercentage
  ) external nonReentrant onlyOperator returns (address) {
    if (leader == address(0)) revert InvalidLeaderAddress();
    if (sharePercentage > BASE) revert InvalidAmount();
    if (isVault(product, leader)) revert InvalidLeaderAddress();

    VaultStorage.Layout storage $ = VaultStorage.layout();
    $.vaultCounter++;
    address vault = address(
      uint160(
        uint256(keccak256(abi.encodePacked(block.timestamp, leader, $.vaultCounter, product)))
      )
    );

    if (isVault(product, vault)) revert VaultAlreadyExists();
    if (leader == vault) revert LeaderCannotBeVault();

    VaultInfo storage vaultInfo = $.vaults[product][vault];
    if (vaultInfo.vault != address(0)) revert VaultAlreadyExists();

    vaultInfo.vault = vault;
    vaultInfo.leader = leader;
    vaultInfo.balance = 0;
    vaultInfo.profitShare = sharePercentage;
    vaultInfo.closed = false;
    vaultInfo.created = block.timestamp;

    $.vaultList[product].push(vault);
    $.vaultMembers[product][vault].push(
      VaultMember({ vault: vault, user: leader, balance: 0, created: block.timestamp })
    );

    emit VaultCreated(product, vault, leader, sharePercentage);
    return vault;
  }

  function closeVault(
    address product,
    address vault,
    address leader
  ) external nonReentrant onlyOperator {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    VaultInfo storage vaultInfo = $.vaults[product][vault];

    if (vaultInfo.vault == address(0)) revert VaultNotFound();
    if (vaultInfo.leader != leader) revert Unauthorized();
    if (vaultInfo.closed) revert VaultAlreadyClosed();
    if (vaultInfo.balance != 0) revert NonZeroBalance();

    vaultInfo.closed = true;
    emit VaultClosed(product, vault, leader);
  }

  function depositToVault(
    address product,
    address vault,
    address user,
    uint256 amount
  ) external nonReentrant onlyOperator returns (uint256) {
    if (isVault(product, user)) revert VaultCannotDeposit();
    _validateVaultOperation(product, vault, amount, false);

    (uint256 depositBalance, uint256 currentBalance) = _updateVaultMemberBalance(
      product,
      vault,
      user,
      amount,
      true
    );

    emit VaultTransaction(product, vault, user, amount, true, depositBalance, currentBalance);
    return amount;
  }

  function withdrawFromVault(
    address product,
    address vault,
    address user,
    uint256 amount
  ) external nonReentrant onlyOperator returns (uint256) {
    if (isVault(product, user) || !isVaultMember(product, vault, user)) revert Unauthorized();
    VaultInfo storage vaultInfo = _validateVaultOperation(product, vault, amount, true);

    uint256 leaderShare;
    if (user != vaultInfo.leader) {
      leaderShare = (amount * vaultInfo.profitShare) / BASE;
    }

    if (user != vaultInfo.leader) {
      // Calculate leader's share
      _updateVaultMemberBalance(product, vault, vaultInfo.leader, leaderShare, true);
    }
    (uint256 depositBalance, uint256 currentBalance) = _updateVaultMemberBalance(
      product,
      vault,
      user,
      amount,
      false
    );

    emit VaultTransaction(product, vault, user, amount, false, depositBalance, currentBalance);
    return amount;
  }

  function pause() external whenNotPaused onlyAdmin {
    _pause();
  }

  function unpause() external whenPaused onlyAdmin {
    _unpause();
  }

  function setAdmin(address _adminAddress) external onlyOwner {
    if (_adminAddress == address(0)) revert InvalidAddress();
    VaultStorage.Layout storage $ = VaultStorage.layout();
    $.adminAddress = _adminAddress;
  }

  /* public views */
  function isVault(address product, address vault) public view returns (bool) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    for (uint i = 0; i < $.vaultList[product].length; i++) {
      if ($.vaultList[product][i] == vault) {
        return true;
      }
    }
    return false;
  }

  function isVaultMember(address product, address vault, address user) public view returns (bool) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    VaultMember[] storage members = $.vaultMembers[product][vault];
    for (uint i = 0; i < members.length; i++) {
      if (members[i].user == user) {
        return true;
      }
    }
    return false;
  }

  function addresses() public view returns (address) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    return ($.adminAddress);
  }

  function getOperators() public view returns (address[] memory) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    return $.operatorList;
  }

  function getVaultInfo(address product, address vault) public view returns (VaultInfo memory) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    return $.vaults[product][vault];
  }

  function getVaultMembers(
    address product,
    address vault
  ) external view returns (VaultMember[] memory) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    return $.vaultMembers[product][vault];
  }

  function addOperator(address operator) external onlyAdmin {
    if (operator == address(0)) revert InvalidAddress();
    VaultStorage.Layout storage $ = VaultStorage.layout();
    $.operators[operator] = true;
    $.operatorList.push(operator);
  }

  function removeOperator(address operator) external onlyAdmin {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    $.operators[operator] = false;
    for (uint i = 0; i < $.operatorList.length; i++) {
      if ($.operatorList[i] == operator) {
        $.operatorList[i] = $.operatorList[$.operatorList.length - 1];
        $.operatorList.pop();
        break;
      }
    }
  }

  function userBalances(
    address product,
    address vault,
    address user
  ) public view returns (uint256 depositBalance, uint256 currentBalance) {
    (VaultMember memory member, bool found) = _findMember(product, vault, user);
    if (!found) {
      return (0, 0);
    }

    depositBalance = member.balance;
    currentBalance = _getVaultMemberBalance(product, vault, user);
  }

  function vaultsByProduct(address product) public view returns (address[] memory) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    return $.vaultList[product];
  }

  /* internal functions */
  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  function _getTotalInitialDeposits(
    address product,
    address vault
  ) internal view returns (uint256) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    VaultMember[] storage members = $.vaultMembers[product][vault];
    uint256 totalDeposits = 0;
    for (uint i = 0; i < members.length; i++) {
      totalDeposits += members[i].balance;
    }
    return totalDeposits;
  }

  function _updateVaultMemberBalance(
    address product,
    address vault,
    address user,
    uint256 amount,
    bool isDeposit
  ) internal returns (uint256 depositBalance, uint256 currentBalance) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    VaultMember[] storage members = $.vaultMembers[product][vault];
    bool found = false;

    for (uint i = 0; i < members.length; i++) {
      if (members[i].user == user) {
        if (isDeposit) {
          members[i].balance += amount;
          $.vaults[product][vault].balance += amount;
          depositBalance = members[i].balance;
          currentBalance = members[i].balance;
        } else {
          members[i].balance -= amount;
          $.vaults[product][vault].balance -= amount;
          depositBalance = members[i].balance;
          currentBalance = members[i].balance;
        }
        found = true;
        break;
      }
    }
    if (!found) {
      if (!isDeposit) revert CannotWithdrawFromNonExistentMember();
      $.vaultMembers[product][vault].push(
        VaultMember({ vault: vault, user: user, balance: amount, created: block.timestamp })
      );
      $.vaults[product][vault].balance += amount;
      depositBalance = amount;
      currentBalance = amount;
    }
  }

  function _updateVaultMemberBalanceV2(
    address product,
    address vault,
    address user,
    uint256 amount,
    bool isDeposit
  ) internal returns (uint256 depositBalance, uint256 currentBalance) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    VaultMember[] storage members = $.vaultMembers[product][vault];
    bool found = false;

    // Calculate total initial deposits for balance calculation
    uint256 totalInitialDeposits = _getTotalInitialDeposits(product, vault);

    for (uint i = 0; i < members.length; i++) {
      if (members[i].user == user) {
        if (isDeposit) {
          members[i].balance += amount;
          depositBalance = members[i].balance;

          // Calculate balance after deposit
          uint256 newShareRatio = Math.mulDiv(
            members[i].balance,
            BASE,
            totalInitialDeposits + amount,
            Math.Rounding.Floor
          );
          currentBalance = Math.mulDiv(
            $.vaults[product][vault].balance + amount,
            newShareRatio,
            BASE,
            Math.Rounding.Floor
          );
          $.vaults[product][vault].balance += amount;
        } else {
          uint256 initialDepositReduction;

          // Calculate current balance
          uint256 userShareRatio = Math.mulDiv(
            members[i].balance,
            BASE,
            totalInitialDeposits,
            Math.Rounding.Floor
          );
          uint256 balance = Math.mulDiv(
            $.vaults[product][vault].balance,
            userShareRatio,
            BASE,
            Math.Rounding.Floor
          );
          if (balance < amount) revert InsufficientBalance();

          // Calculate proportional reduction of initialDeposit
          if (amount == balance) {
            initialDepositReduction = members[i].balance;
            members[i].balance = 0;
            currentBalance = 0;
          } else {
            uint256 reductionRatio = Math.mulDiv(amount, BASE, balance, Math.Rounding.Floor);
            initialDepositReduction = Math.mulDiv(
              members[i].balance,
              reductionRatio,
              BASE,
              Math.Rounding.Floor
            );
            members[i].balance -= initialDepositReduction;

            if (totalInitialDeposits == initialDepositReduction) {
              currentBalance = 0;
            } else {
              uint256 newShareRatio = Math.mulDiv(
                members[i].balance,
                BASE,
                totalInitialDeposits - initialDepositReduction,
                Math.Rounding.Floor
              );
              currentBalance = Math.mulDiv(
                $.vaults[product][vault].balance - amount,
                newShareRatio,
                BASE,
                Math.Rounding.Floor
              );
            }
          }
          $.vaults[product][vault].balance -= amount;
        }
        found = true;
        break;
      }
    }
    if (!found) {
      if (!isDeposit) revert CannotWithdrawFromNonExistentMember();
      $.vaultMembers[product][vault].push(
        VaultMember({ vault: vault, user: user, balance: amount, created: block.timestamp })
      );
      // Calculate balance for new member
      uint256 newShareRatio = Math.mulDiv(
        amount,
        BASE,
        totalInitialDeposits + amount,
        Math.Rounding.Floor
      );
      currentBalance = Math.mulDiv(
        $.vaults[product][vault].balance + amount,
        newShareRatio,
        BASE,
        Math.Rounding.Floor
      );
      $.vaults[product][vault].balance += amount;
    }
  }

  function _validateVaultOperation(
    address product,
    address vault,
    uint256 amount,
    bool checkBalance
  ) internal view returns (VaultInfo storage vaultInfo) {
    if (amount == 0) revert InvalidAmount();

    vaultInfo = VaultStorage.layout().vaults[product][vault];
    if (vaultInfo.vault == address(0)) revert VaultNotFound();
    if (vaultInfo.closed) revert VaultAlreadyClosed();
    if (checkBalance && vaultInfo.balance < amount) revert InsufficientBalance();
  }

  function _findMember(
    address product,
    address vault,
    address user
  ) internal view returns (VaultMember storage, bool) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    VaultMember[] storage members = $.vaultMembers[product][vault];
    for (uint i = 0; i < members.length; i++) {
      if (members[i].user == user) {
        return (members[i], true);
      }
    }
    return (members[0], false); // Return first element as dummy (never used when false)
  }

  function _calculateShareRatio(
    uint256 balance,
    uint256 totalBalance
  ) internal pure returns (uint256) {
    if (balance == 0 || totalBalance == 0) return 0;
    return Math.mulDiv(balance, BASE, totalBalance, Math.Rounding.Floor);
  }

  function _calculateMemberBalance(
    uint256 shareRatio,
    uint256 vaultBalance
  ) internal pure returns (uint256) {
    if (shareRatio == 0 || vaultBalance == 0) return 0;
    return Math.mulDiv(vaultBalance, shareRatio, BASE, Math.Rounding.Floor);
  }

  function _calculateLeaderShare(
    uint256 amount,
    uint256 profitShare
  ) internal pure returns (uint256) {
    if (amount == 0 || profitShare == 0) return 0;
    return Math.mulDiv(amount, profitShare, BASE, Math.Rounding.Floor);
  }

  function _getVaultMemberBalance(
    address product,
    address vault,
    address user
  ) internal view returns (uint256) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    VaultInfo storage vaultInfo = $.vaults[product][vault];
    (VaultMember storage member, bool found) = _findMember(product, vault, user);

    if (!found) return 0;

    uint256 totalDeposits = _getTotalInitialDeposits(product, vault);
    uint256 shareRatio = _calculateShareRatio(member.balance, totalDeposits);
    uint256 currentBalance = _calculateMemberBalance(shareRatio, vaultInfo.balance);

    if (user == vaultInfo.leader) {
      return currentBalance;
    } else {
      uint256 leaderShare = _calculateLeaderShare(currentBalance, vaultInfo.profitShare);
      return currentBalance - leaderShare;
    }
  }
}
