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
  event VaultTransactionProcessedBatch(
    address indexed product,
    address indexed vault,
    uint256 indexed orderIdx,
    uint256 vaultBalance,
    address[] users,
    uint256[] balances,
    uint256[] shares,
    bool isWin
  );

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
    if (isVault(product, user) || !isVaultMember(product, vault, user)) revert Unauthorized();
    VaultInfo storage vaultInfo = _validateVaultOperation(product, vault, amount, true);

    uint256 memberShare;
    uint256 leaderShare;

    if (user == vaultInfo.leader) {
      memberShare = amount;
    } else {
      leaderShare = (amount * vaultInfo.profitShare) / BASE;
      memberShare = amount - leaderShare;
    }

    vaultInfo.balance -= memberShare;

    uint256 memberBalance;
    if (user != vaultInfo.leader) {
      // update leader balance
      _updateVaultMemberBalance(product, vault, vaultInfo.leader, leaderShare, true);
    }
    memberBalance = _updateVaultMemberBalance(product, vault, user, memberShare, false);

    emit VaultTransaction(product, vault, user, amount, false, memberBalance);
    return memberShare;
  }

  function processVaultTransaction(
    address product,
    address vault,
    uint256 orderIdx,
    uint256 amount,
    bool isWin
  ) external nonReentrant onlyOperator {
    VaultStorage.Layout storage $ = VaultStorage.layout();
    VaultInfo storage vaultInfo = $.vaults[product][vault];
    if (vaultInfo.balance == 0) revert VaultBalanceIsZero();

    VaultSnapshot storage snapshot = $.orderVaultSnapshots[product][orderIdx];
    VaultMember[] storage members = $.vaultMembers[product][vault];

    // Prepare arrays to store batch data
    address[] memory users = new address[](members.length);
    uint256[] memory balances = new uint256[](members.length);
    uint256[] memory shares = new uint256[](members.length);

    // Calculate each member's share from the total vault balance and distribute the amount
    for (uint i = 0; i < members.length; i++) {
      VaultMember storage member = members[i];
      uint256 memberShare = (member.balance * amount) / vaultInfo.balance;
      member.balance = isWin ? member.balance + memberShare : member.balance - memberShare;
      snapshot.members.push(
        VaultMember({
          vault: vault,
          user: member.user,
          balance: member.balance,
          created: member.created
        })
      );

      // Store data for batch event
      users[i] = member.user;
      balances[i] = member.balance;
      shares[i] = memberShare;
    }
    vaultInfo.balance = isWin ? vaultInfo.balance + amount : vaultInfo.balance - amount;

    // Emit a single event with batch data
    emit VaultTransactionProcessedBatch(
      product,
      vault,
      orderIdx,
      vaultInfo.balance,
      users,
      balances,
      shares,
      isWin
    );
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
    for (uint i = 0; i < members.length; i++) {
      if (members[i].user == user) {
        if (isDeposit) {
          members[i].balance += amount;
        } else {
          if (members[i].balance < amount) revert InsufficientBalance();
          members[i].balance -= amount;
        }
        memberBalance = members[i].balance;
        found = true;
        break;
      }
    }
    if (!found) {
      if (!isDeposit) revert CannotWithdrawFromNonExistentMember();
      $.vaultMembers[product][vault].push(
        VaultMember({ vault: vault, user: user, balance: amount, created: block.timestamp })
      );
      memberBalance = amount;
    }
    return memberBalance;
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
    return $.vaults[product][vault].vault != address(0);
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
    if (!isVault(product, vault)) revert VaultNotFound();

    VaultStorage.Layout storage $ = VaultStorage.layout();
    VaultMember[] storage members = $.vaultMembers[product][vault];
    for (uint i = 0; i < members.length; i++) {
      if (members[i].user == user) {
        return members[i].balance;
      }
    }
    return 0;
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

  /* internal functions */
  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

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
}
