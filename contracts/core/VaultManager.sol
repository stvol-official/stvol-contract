// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { VaultManagerStorage } from "../storage/VaultManagerStorage.sol";
import { IVaultErrors } from "../errors/VaultErrors.sol";
import "../types/Types.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract VaultManager is
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
    uint256 balance
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
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    if (msg.sender != $.adminAddress) revert OnlyAdmin();
    _;
  }

  modifier onlyOperator() {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
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

    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
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

    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
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
      VaultMember({ vault: vault, user: leader, balance: 0, shares: 0, created: block.timestamp })
    );

    emit VaultCreated(product, vault, leader, sharePercentage);
    return vault;
  }

  function closeVault(
    address product,
    address vault,
    address leader
  ) external nonReentrant onlyOperator {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    VaultInfo storage vaultInfo = $.vaults[product][vault];

    if (vaultInfo.vault == address(0)) revert VaultNotFound();
    if (vaultInfo.leader != leader) revert Unauthorized();
    if (vaultInfo.closed) revert VaultAlreadyClosed();

    vaultInfo.closed = true;
    for (uint i = 0; i < $.vaultList[product].length; i++) {
      if ($.vaultList[product][i] == vault) {
        $.vaultList[product][i] = $.vaultList[product][$.vaultList[product].length - 1];
        $.vaultList[product].pop();
        break;
      }
    }
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

    uint256 depositBalance = _depositToVaultMemberBalance(product, vault, user, amount);

    emit VaultTransaction(product, vault, user, amount, true, depositBalance);
    return depositBalance;
  }

  function withdrawFromVault(
    address product,
    address vault,
    address user,
    uint256 amount
  ) external nonReentrant onlyOperator returns (uint256) {
    if (isVault(product, user) || !isVaultMember(product, vault, user)) revert Unauthorized();
    VaultInfo storage vaultInfo = _validateVaultOperation(product, vault, amount, true);

    (VaultMember memory member, bool found) = _findMember(product, vault, user);
    if (!found) revert Unauthorized();

    uint256 currentValue = (member.shares * vaultInfo.balance) / vaultInfo.totalShares;
    uint256 profit = _calculateProfit(currentValue, member.balance);
    uint256 leaderShare = _calculateLeaderFee(
      user,
      vaultInfo.leader,
      profit,
      amount,
      currentValue,
      vaultInfo.profitShare
    );

    if (user != vaultInfo.leader && leaderShare > 0) {
      _depositToVaultMemberBalance(product, vault, vaultInfo.leader, leaderShare);
    }

    uint256 withdrawAmount = _withdrawFromVaultMemberBalance(product, vault, user, amount, profit);

    emit VaultTransaction(product, vault, user, amount, false, withdrawAmount);
    return withdrawAmount;
  }

  function addVaultBalance(
    address product,
    address vault,
    uint256 amount
  ) external nonReentrant onlyOperator {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    $.vaults[product][vault].balance += amount;
  }

  function subtractVaultBalance(
    address product,
    address vault,
    uint256 amount
  ) external nonReentrant onlyOperator {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    $.vaults[product][vault].balance -= amount;
  }

  function pause() external whenNotPaused onlyAdmin {
    _pause();
  }

  function unpause() external whenPaused onlyAdmin {
    _unpause();
  }

  function setAdmin(address _adminAddress) external onlyOwner {
    if (_adminAddress == address(0)) revert InvalidAddress();
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    $.adminAddress = _adminAddress;
  }

  /* public views */
  function isVault(address product, address vault) public view returns (bool) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    for (uint i = 0; i < $.vaultList[product].length; i++) {
      if ($.vaultList[product][i] == vault) {
        return true;
      }
    }
    return false;
  }

  function isVaultMember(address product, address vault, address user) public view returns (bool) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    VaultMember[] storage members = $.vaultMembers[product][vault];
    for (uint i = 0; i < members.length; i++) {
      if (members[i].user == user) {
        return true;
      }
    }
    return false;
  }

  function addresses() public view returns (address) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    return ($.adminAddress);
  }

  function getOperators() public view returns (address[] memory) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    return $.operatorList;
  }

  function getVaultInfo(address product, address vault) public view returns (VaultInfo memory) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    return $.vaults[product][vault];
  }

  function getVaultBalancesByProduct(address product) public view returns (VaultBalance[] memory) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    VaultBalance[] memory balances = new VaultBalance[]($.vaultList[product].length);

    for (uint i = 0; i < $.vaultList[product].length; i++) {
      address vault = $.vaultList[product][i];
      balances[i] = VaultBalance({ vault: vault, balance: $.vaults[product][vault].balance });
    }
    return balances;
  }

  function getVaultMembers(
    address product,
    address vault
  ) external view returns (VaultMember[] memory) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    return $.vaultMembers[product][vault];
  }

  function addOperator(address operator) external onlyAdmin {
    if (operator == address(0)) revert InvalidAddress();
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    $.operators[operator] = true;
    $.operatorList.push(operator);
  }

  function removeOperator(address operator) external onlyAdmin {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    $.operators[operator] = false;
    for (uint i = 0; i < $.operatorList.length; i++) {
      if ($.operatorList[i] == operator) {
        $.operatorList[i] = $.operatorList[$.operatorList.length - 1];
        $.operatorList.pop();
        break;
      }
    }
  }

  function vaultsByProduct(address product) public view returns (address[] memory) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    return $.vaultList[product];
  }

  function getWithdrawableAmount(
    address product,
    address vault,
    address user
  )
    public
    view
    returns (uint256 withdrawableAmount, uint256 userShares, uint256 estimatedLeaderFee)
  {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    VaultInfo storage vaultInfo = $.vaults[product][vault];

    (VaultMember memory member, bool found) = _findMember(product, vault, user);
    if (!found) return (0, 0, 0);

    userShares = member.shares;
    uint256 totalShares = vaultInfo.totalShares;
    uint256 totalVaultValue = vaultInfo.balance;
    if (totalShares == 0) return (0, 0, 0);

    // calculate withdrawable amount
    withdrawableAmount = (userShares * totalVaultValue) / totalShares;

    // calculate profit and leader fee
    uint256 profit = _calculateProfit(withdrawableAmount, member.balance);
    estimatedLeaderFee = _calculateLeaderFee(
      user,
      vaultInfo.leader,
      profit,
      withdrawableAmount,
      withdrawableAmount,
      vaultInfo.profitShare
    );
    withdrawableAmount -= estimatedLeaderFee;
  }

  function userBalances(
    address product,
    address vault,
    address user
  ) public view returns (uint256 depositBalance, uint256 currentValue, uint256 sharePercentage) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    VaultInfo storage vaultInfo = $.vaults[product][vault];

    (VaultMember memory member, bool found) = _findMember(product, vault, user);
    if (!found) return (0, 0, 0);

    depositBalance = member.balance;
    uint256 totalShares = vaultInfo.totalShares;

    // Return early if totalShares is 0
    if (totalShares == 0) return (depositBalance, 0, 0);

    // Calculate current share percentage
    sharePercentage = (member.shares * BASE) / totalShares;

    // Calculate current value before leader fee
    uint256 totalValue = (member.shares * vaultInfo.balance) / totalShares;
    uint256 profit = _calculateProfit(totalValue, depositBalance);
    uint256 leaderFee = _calculateLeaderFee(
      user,
      vaultInfo.leader,
      profit,
      totalValue,
      totalValue,
      vaultInfo.profitShare
    );
    currentValue = totalValue - leaderFee;
  }

  function withdrawAllFromVault(
    address product,
    address vault
  ) external nonReentrant onlyOperator returns (WithdrawalInfo[] memory) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    VaultInfo storage vaultInfo = $.vaults[product][vault];
    if (vaultInfo.vault == address(0)) revert VaultNotFound();

    VaultMember[] storage members = $.vaultMembers[product][vault];
    uint256 vaultBalance = vaultInfo.balance;
    uint256 totalShares = vaultInfo.totalShares;
    if (totalShares == 0 || vaultBalance == 0) revert VaultBalanceIsZero();

    // Count valid withdrawals
    uint256 validCount = 0;
    for (uint i = 0; i < members.length; i++) {
      if (members[i].shares > 0) {
        validCount++;
      }
    }

    WithdrawalInfo[] memory withdrawals = new WithdrawalInfo[](validCount);
    uint256 withdrawalIndex = 0;

    for (uint i = 0; i < members.length; i++) {
      if (members[i].shares == 0) continue;

      address user = members[i].user;
      uint256 memberShares = members[i].shares;

      uint256 currentValue = (memberShares * vaultInfo.balance) / vaultInfo.totalShares;
      uint256 profit = _calculateProfit(currentValue, members[i].balance);

      uint256 leaderShare = _calculateLeaderFee(
        user,
        vaultInfo.leader,
        profit,
        currentValue,
        currentValue,
        vaultInfo.profitShare
      );

      if (user != vaultInfo.leader && leaderShare > 0) {
        _depositToVaultMemberBalance(product, vault, vaultInfo.leader, leaderShare);
      }

      uint256 withdrawAmount = _withdrawFromVaultMemberBalance(
        product,
        vault,
        user,
        currentValue,
        profit
      );

      withdrawals[withdrawalIndex] = WithdrawalInfo({ user: user, amount: withdrawAmount });
      withdrawalIndex++;
    }

    return withdrawals;
  }

  /* internal functions */
  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  function _depositToVaultMemberBalance(
    address product,
    address vault,
    address user,
    uint256 amount
  ) internal returns (uint256 balance) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    VaultMember[] storage members = $.vaultMembers[product][vault];
    bool found = false;

    uint256 totalVaultValue = $.vaults[product][vault].balance;
    uint256 totalShares = $.vaults[product][vault].totalShares;
    uint256 newShares = totalShares == 0 ? amount : (amount * totalShares) / totalVaultValue;

    for (uint i = 0; i < members.length; i++) {
      if (members[i].user == user) {
        members[i].balance += amount;
        members[i].shares += newShares;
        $.vaults[product][vault].balance += amount;
        $.vaults[product][vault].totalShares += newShares;
        balance = members[i].balance;
        found = true;
        break;
      }
    }
    if (!found) {
      $.vaultMembers[product][vault].push(
        VaultMember({
          vault: vault,
          user: user,
          balance: amount,
          shares: newShares,
          created: block.timestamp
        })
      );
      $.vaults[product][vault].balance += amount;
      $.vaults[product][vault].totalShares += newShares;
      balance = amount;
    }
  }

  function _withdrawFromVaultMemberBalance(
    address product,
    address vault,
    address user,
    uint256 amount,
    uint256 profit
  ) internal returns (uint256 netWithdrawAmount) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    VaultMember[] storage members = $.vaultMembers[product][vault];
    bool found = false;

    uint256 vaultBalance = $.vaults[product][vault].balance;
    uint256 totalShares = $.vaults[product][vault].totalShares;

    for (uint i = 0; i < members.length; i++) {
      if (members[i].user == user) {
        uint256 userVaultValue = (members[i].shares * vaultBalance) / totalShares;
        uint256 withdrawValue = amount > userVaultValue ? userVaultValue : amount;
        uint256 sharesToWithdraw = (withdrawValue * totalShares) / vaultBalance;

        if (members[i].shares < sharesToWithdraw) revert InsufficientShares();

        uint256 leaderFee = _calculateLeaderFee(
          user,
          $.vaults[product][vault].leader,
          profit,
          withdrawValue,
          withdrawValue,
          $.vaults[product][vault].profitShare
        );

        if (members[i].balance != 0) {
          uint256 originalDepositRatio = (members[i].balance * (userVaultValue - withdrawValue)) /
            userVaultValue;
          members[i].balance -= originalDepositRatio;
        }

        members[i].shares -= sharesToWithdraw;
        $.vaults[product][vault].balance -= withdrawValue;
        $.vaults[product][vault].totalShares -= sharesToWithdraw;

        netWithdrawAmount = withdrawValue - leaderFee;
        found = true;
        break;
      }
    }
    if (!found) {
      revert CannotWithdrawFromNonExistentMember();
    }
  }

  function _validateVaultOperation(
    address product,
    address vault,
    uint256 amount,
    bool checkBalance
  ) internal view returns (VaultInfo storage vaultInfo) {
    if (amount == 0) revert InvalidAmount();

    vaultInfo = VaultManagerStorage.layout().vaults[product][vault];
    if (vaultInfo.vault == address(0)) revert VaultNotFound();
    if (vaultInfo.closed) revert VaultAlreadyClosed();
    if (checkBalance && vaultInfo.balance < amount) revert InsufficientBalance();
  }

  function _findMember(
    address product,
    address vault,
    address user
  ) internal view returns (VaultMember storage, bool) {
    VaultManagerStorage.Layout storage $ = VaultManagerStorage.layout();
    VaultMember[] storage members = $.vaultMembers[product][vault];
    for (uint i = 0; i < members.length; i++) {
      if (members[i].user == user) {
        return (members[i], true);
      }
    }
    return (members[0], false);
  }

  function _calculateProfit(
    uint256 currentValue,
    uint256 originalDeposit
  ) internal pure returns (uint256 profit) {
    return currentValue > originalDeposit ? currentValue - originalDeposit : 0;
  }

  function _calculateLeaderFee(
    address user,
    address leader,
    uint256 profit,
    uint256 amount,
    uint256 currentValue,
    uint256 profitShare
  ) internal pure returns (uint256 leaderFee) {
    if (user == leader || profit == 0) return 0;

    uint256 profitPortion = currentValue > 0 ? (amount * profit) / currentValue : 0;
    return (profitPortion * profitShare) / BASE;
  }
}
