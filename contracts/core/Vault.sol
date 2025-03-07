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

contract Vault is
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  IVaultErrors
{
  uint256 private constant BASE = 10000; // 100%

  event VaultTransaction(
    address indexed product,
    address indexed vault,
    address indexed user,
    uint256 amount,
    bool isDeposit,
    uint256 memberBalance
  );
  event VaultCreated(
    address indexed product,
    address indexed vault,
    address indexed leader,
    uint256 sharePercentage
  );
  event VaultClosed(address indexed product, address indexed vault, address indexed leader);

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
    if (isVault(leader)) revert InvalidLeaderAddress();

    VaultStorage.Layout storage $ = VaultStorage.layout();
    $.vaultCounter++;
    address vault = address(
      uint160(
        uint256(keccak256(abi.encodePacked(block.timestamp, leader, $.vaultCounter, product)))
      )
    );

    if (isVault(vault)) revert VaultAlreadyExists();
    if (leader == vault) revert LeaderCannotBeVault();

    VaultInfo storage vaultInfo = $.vaults[product][vault];
    if (vaultInfo.vault != address(0)) revert VaultAlreadyExists();

    vaultInfo.vault = vault;
    vaultInfo.leader = leader;
    vaultInfo.balance = 0;
    vaultInfo.profitShare = sharePercentage;
    vaultInfo.closed = false;
    vaultInfo.created = block.timestamp;

    $.vaultList.push(vault);
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
    if (isVault(user)) revert VaultCannotDeposit();
    VaultInfo storage vaultInfo = _validateVaultOperation(product, vault, amount, false);

    vaultInfo.balance += amount;
    uint256 memberBalance = _updateVaultMemberBalance(product, vault, user, amount, true);

    emit VaultTransaction(product, vault, user, amount, true, memberBalance);
    return amount;
  }

  function withdrawFromVault(
    address product,
    address vault,
    address user,
    uint256 amount
  ) external nonReentrant onlyOperator returns (uint256) {
    if (isVault(user) || !isVaultMember(product, vault, user)) revert Unauthorized();
    VaultInfo storage vaultInfo = _validateVaultOperation(product, vault, amount, true);

    uint256 withdrawableAmount = _getVaultMemberBalance(product, vault, user);
    if (withdrawableAmount < amount) revert InsufficientBalance();

    vaultInfo.balance -= amount;

    uint256 memberBalance;
    if (user != vaultInfo.leader) {
      // Calculate leader's share
      uint256 leaderShare = _calculateLeaderShare(amount, vaultInfo.profitShare);
      _updateVaultMemberBalance(product, vault, vaultInfo.leader, leaderShare, true);
    }
    memberBalance = _updateVaultMemberBalance(product, vault, user, amount, false);

    emit VaultTransaction(product, vault, user, amount, false, memberBalance);
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
  function isVault(address vault) public view returns (bool) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    for (uint i = 0; i < $.vaultList.length; i++) {
      if ($.vaultList[i] == vault) {
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

  function getVaultMember(
    address product,
    address vault,
    address user
  ) public view returns (VaultMember memory) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    VaultMember[] storage members = $.vaultMembers[product][vault];
    for (uint i = 0; i < members.length; i++) {
      if (members[i].user == user) {
        return members[i];
      }
    }
    return VaultMember(vault, user, 0, 0);
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

  function getVaultBalanceOf(
    address product,
    address vault,
    address user
  ) public view returns (uint256) {
    if (!isVault(vault)) revert VaultNotFound();
    return _getVaultMemberBalance(product, vault, user);
  }

  function getVaultSnapshot(
    address product,
    uint256 orderIdx
  ) internal view returns (VaultSnapshot memory) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    return $.orderVaultSnapshots[product][orderIdx];
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

  function getVaultMemberInfo(
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
  ) internal returns (uint256) {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    VaultMember[] storage members = $.vaultMembers[product][vault];
    bool found = false;
    uint256 memberBalance;

    // Calculate total initial deposits for balance calculation
    uint256 totalInitialDeposits = _getTotalInitialDeposits(product, vault);

    for (uint i = 0; i < members.length; i++) {
      if (members[i].user == user) {
        uint256 initialDepositReduction;
        if (isDeposit) {
          members[i].balance += amount;
          // Calculate balance after deposit
          uint256 newShareRatio = (members[i].balance * BASE) / (totalInitialDeposits + amount);
          memberBalance = (($.vaults[product][vault].balance + amount) * newShareRatio) / BASE;
        } else {
          // Calculate current balance
          uint256 userShareRatio = (members[i].balance * BASE) / totalInitialDeposits;
          uint256 currentBalance = ($.vaults[product][vault].balance * userShareRatio) / BASE;

          if (currentBalance < amount) revert InsufficientBalance();

          // Calculate proportional reduction of initialDeposit
          uint256 reductionRatio = (amount * BASE) / currentBalance;
          initialDepositReduction = (members[i].balance * reductionRatio) / BASE;
          members[i].balance -= initialDepositReduction;

          // Calculate balance after withdrawal
          uint256 newShareRatio = (members[i].balance * BASE) /
            (totalInitialDeposits - initialDepositReduction);
          memberBalance = (($.vaults[product][vault].balance - amount) * newShareRatio) / BASE;
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
      uint256 newShareRatio = (amount * BASE) / (totalInitialDeposits + amount);
      memberBalance = (($.vaults[product][vault].balance + amount) * newShareRatio) / BASE;
    }
    return memberBalance;
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
    return (balance * BASE) / totalBalance;
  }

  function _calculateMemberBalance(
    uint256 shareRatio,
    uint256 vaultBalance
  ) internal pure returns (uint256) {
    return (vaultBalance * shareRatio) / BASE;
  }

  function _calculateLeaderShare(
    uint256 amount,
    uint256 profitShare
  ) internal pure returns (uint256) {
    return (amount * profitShare) / BASE;
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
