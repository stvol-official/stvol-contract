// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IVault.sol";
import { ClearingHouseStorage } from "./storage/ClearingHouseStorage.sol";
import { WithdrawalRequest, Coupon } from "./Types.sol";

contract ClearingHouse is
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable
{
  using SafeERC20 for IERC20;

  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant WITHDRAWAL_FEE = PRICE_UNIT / 10; // 0.1

  event Deposit(address indexed to, address from, uint256 amount, uint256 result);
  event Withdraw(address indexed to, uint256 amount, uint256 result);
  event WithdrawalRequested(address indexed user, uint256 amount);
  event WithdrawalApproved(address indexed user, uint256 amount);
  event WithdrawalRejected(address indexed user, uint256 amount);
  event DepositCoupon(
    address indexed to,
    address from,
    uint256 amount,
    uint256 expirationEpoch,
    uint256 result
  );

  modifier onlyOperator() {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    require(msg.sender == $.operatorAddress, "onlyOperator");
    _;
  }

  modifier validWithdrawal(address user, uint256 amount) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    require(!$.vault.isVault(user), "Vault cannot withdraw");
    require(amount > 0, "Amount must be greater than 0");
    require($.userBalances[user] >= amount + WITHDRAWAL_FEE, "Insufficient balance");
    _;
  }

  function initialize(
    address _operatorAddress,
    address _vaultAddress
  ) public initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);
    __Pausable_init();
    __ReentrancyGuard_init();

    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.token = IERC20(0x770D5DE8dd09660F1141CF887D6B50976FBb12A0); // minato usdc
    $.vault = IVault(_vaultAddress);
    $.operatorAddress = _operatorAddress;
  }

  function deposit(address user, uint256 amount) external nonReentrant {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    require(!$.vault.isVault(user), "vault cannot deposit");

    $.token.safeTransferFrom(user, address(this), amount);
    $.userBalances[user] += amount;
    emit Deposit(user, user, amount, $.userBalances[user]);
  }

  function depositTo(address from, address to, uint256 amount) external nonReentrant {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    require(!$.vault.isVault(to), "vault cannot deposit");

    $.token.safeTransferFrom(from, address(this), amount);
    $.userBalances[to] += amount;
    emit Deposit(to, from, amount, $.userBalances[to]);
  }

  function withdraw(address user, uint256 amount) external nonReentrant onlyOperator validWithdrawal(user, amount) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    require(!$.vault.isVault(user), "Vault cannot withdraw");
    require(amount > 0, "Amount must be greater than 0");
    require($.userBalances[user] >= amount + WITHDRAWAL_FEE, "Insufficient user balance");
    $.userBalances[user] -= amount + WITHDRAWAL_FEE;
    $.treasuryAmount += WITHDRAWAL_FEE;
    $.token.safeTransfer(user, amount);
    emit Withdraw(user, amount, $.userBalances[user]);
  }

  function requestWithdrawal(
    address user,
    uint256 amount
  ) external returns (WithdrawalRequest memory) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    require(!$.vault.isVault(user), "Vault cannot withdraw");
    require(amount > 0, "Amount must be greater than 0");
    require($.userBalances[user] >= amount + WITHDRAWAL_FEE, "Insufficient user balance");

    WithdrawalRequest memory request = WithdrawalRequest({
      idx: $.withdrawalRequests.length,
      user: user,
      amount: amount,
      processed: false,
      message: "",
      created: block.timestamp
    });

    $.withdrawalRequests.push(request);

    emit WithdrawalRequested(user, amount);
    return request;
  }

  function getWithdrawalRequests(uint256 from) public view returns (WithdrawalRequest[] memory) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    uint256 totalRequests = $.withdrawalRequests.length;

    if (totalRequests < 100) {
      return $.withdrawalRequests;
    } else {
      uint256 startFrom = from < totalRequests - 100 ? from : totalRequests - 100;

      WithdrawalRequest[] memory recentRequests = new WithdrawalRequest[](100);
      for (uint256 i = 0; i < 100; i++) {
        recentRequests[i] = $.withdrawalRequests[startFrom + i];
      }

      return recentRequests;
    }
  }

  function approveWithdrawal(uint256 idx) external onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    require(idx < $.withdrawalRequests.length, "Invalid idx");
    WithdrawalRequest storage request = $.withdrawalRequests[idx];
    require(!request.processed, "Request already processed");
    require(
      $.userBalances[request.user] >= request.amount + WITHDRAWAL_FEE,
      "Insufficient user balance"
    );
    request.processed = true;
    $.userBalances[request.user] -= request.amount + WITHDRAWAL_FEE;
    $.treasuryAmount += WITHDRAWAL_FEE;
    $.token.safeTransfer(request.user, request.amount);
    emit WithdrawalApproved(request.user, request.amount);
  }

  function rejectWithdrawal(uint256 idx, string calldata reason) external onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    require(idx < $.withdrawalRequests.length, "Invalid idx");
    WithdrawalRequest storage request = $.withdrawalRequests[idx];
    require(!request.processed, "Request already processed");

    request.processed = true;
    request.message = reason;

    emit WithdrawalRejected(request.user, request.amount);
  }

  function forceWithdrawAll(address user) external nonReentrant {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    require(block.timestamp >= $.lastSubmissionTime + 1 hours, "invalid time");

    uint256 balance = $.userBalances[user];
    require(balance >= WITHDRAWAL_FEE, "insufficient user balance");
    $.userBalances[user] = 0;
    $.treasuryAmount += WITHDRAWAL_FEE;
    $.token.safeTransfer(user, balance - WITHDRAWAL_FEE);
    emit Withdraw(user, balance, 0);
  }

  function claimTreasury(address operatorVaultAddress) external onlyOwner {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    uint256 currentTreasuryAmount = $.treasuryAmount;
    $.treasuryAmount = 0;
    $.token.safeTransfer(operatorVaultAddress, currentTreasuryAmount);
  }

  function depositCouponTo(
    address user,
    uint256 amount,
    uint256 expirationEpoch
  ) external nonReentrant {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    $.token.safeTransferFrom(msg.sender, address(this), amount);
    $.couponAmount += amount;

    Coupon[] storage coupons = $.couponBalances[user];

    Coupon memory newCoupon = Coupon({
      user: user,
      amount: amount,
      usedAmount: 0,
      expirationEpoch: expirationEpoch,
      created: block.timestamp,
      issuer: msg.sender
    });

    uint i = coupons.length;
    coupons.push(newCoupon);

    if (i == 0) {
      // add user to couponHolders array
      $.couponHolders.push(user);
    }

    while (i > 0 && coupons[i - 1].expirationEpoch > newCoupon.expirationEpoch) {
      coupons[i] = coupons[i - 1];
      i--;
    }
    coupons[i] = newCoupon;

    emit DepositCoupon(user, msg.sender, amount, expirationEpoch, couponBalanceOf(user));
  }

  function couponBalanceOf(address user) public view returns (uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    uint256 total = 0;
    uint256 epoch = _epochAt(block.timestamp);
    for (uint i = 0; i < $.couponBalances[user].length; i++) {
      if ($.couponBalances[user][i].expirationEpoch >= epoch) {
        total += $.couponBalances[user][i].amount - $.couponBalances[user][i].usedAmount;
      }
    }
    return total;
  }

  function couponHolders() public view returns (address[] memory) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.couponHolders;
  }

  function userCoupons(address user) public view returns (Coupon[] memory) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.couponBalances[user];
  }

  function _epochAt(uint256 timestamp) internal pure returns (uint256) {
    uint256 START_TIMESTAMP = 1732838400;
    require(timestamp >= START_TIMESTAMP, "Epoch has not started yet");
    uint256 elapsedSeconds = timestamp - START_TIMESTAMP;
    uint256 elapsedHours = elapsedSeconds / 3600;
    return elapsedHours;
  }

  function _authorizeUpgrade(address) internal override onlyOwner {}

  function userBalances(address user) external view returns (uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.userBalances[user];
  }

  function treasuryAmount() external view returns (uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.treasuryAmount;
  }
} 