// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ClearingHouseStorage } from "../storage/ClearingHouseStorage.sol";
import { ICommonErrors } from "../errors/CommonErrors.sol";
import { WithdrawalRequest } from "../types/Types.sol";

contract ClearingHouse is
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  ICommonErrors
{
  using SafeERC20 for IERC20;

  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant WITHDRAWAL_FEE = PRICE_UNIT / 10; // 0.1

  event Deposit(address indexed to, address from, uint256 amount, uint256 result);
  event Withdraw(address indexed to, uint256 amount, uint256 result);
  event WithdrawalRequested(address indexed user, uint256 amount);
  event WithdrawalApproved(address indexed user, uint256 amount);
  event WithdrawalRejected(address indexed user, uint256 amount);
  event BalanceTransferred(address indexed from, address indexed to, uint256 amount);

  modifier onlyAdmin() {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    if (msg.sender != $.adminAddress) revert OnlyAdmin();
    _;
  }

  modifier onlyOperator() {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    if (!$.operators[msg.sender]) revert OnlyOperator();
    _;
  }

  modifier validWithdrawal(address user, uint256 amount) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    if (amount == 0) revert InvalidAmount();
    if ($.userBalances[user] < amount + WITHDRAWAL_FEE) revert InsufficientBalance();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(
    address _usdcAddress,
    address _adminAddress,
    address _operatorVaultAddress
  ) public initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);
    __Pausable_init();
    __ReentrancyGuard_init();

    if (_usdcAddress == address(0)) revert InvalidAddress();
    if (_adminAddress == address(0)) revert InvalidAddress();

    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.token = IERC20(_usdcAddress);
    $.adminAddress = _adminAddress;
    $.operatorVaultAddress = _operatorVaultAddress;
  }

  function deposit(address user, uint256 amount) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    $.token.safeTransferFrom(user, address(this), amount);
    $.userBalances[user] += amount;
    emit Deposit(user, user, amount, $.userBalances[user]);
  }

  function depositTo(address from, address to, uint256 amount) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    $.token.safeTransferFrom(from, address(this), amount);
    $.userBalances[to] += amount;
    emit Deposit(to, from, amount, $.userBalances[to]);
  }

  function withdraw(address user, uint256 amount) external nonReentrant onlyOperator validWithdrawal(user, amount) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.userBalances[user] -= amount + WITHDRAWAL_FEE;
    $.treasuryAmount += WITHDRAWAL_FEE;
    $.token.safeTransfer(user, amount);
    emit Withdraw(user, amount, $.userBalances[user]);
  }

  function requestWithdrawal(
    address user,
    uint256 amount
  ) external nonReentrant onlyOperator validWithdrawal(user, amount) returns (WithdrawalRequest memory) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

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

  function approveWithdrawal(uint256 idx) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    if (idx >= $.withdrawalRequests.length) revert InvalidIdx();
    WithdrawalRequest storage request = $.withdrawalRequests[idx];
    if (request.processed) revert RequestAlreadyProcessed();
    if ($.userBalances[request.user] < request.amount + WITHDRAWAL_FEE) revert InsufficientBalance();
    request.processed = true;
    $.userBalances[request.user] -= request.amount + WITHDRAWAL_FEE;
    $.treasuryAmount += WITHDRAWAL_FEE;
    $.token.safeTransfer(request.user, request.amount);
    emit WithdrawalApproved(request.user, request.amount);
  }

  function rejectWithdrawal(uint256 idx, string calldata reason) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    if (idx >= $.withdrawalRequests.length) revert InvalidIdx();
    WithdrawalRequest storage request = $.withdrawalRequests[idx];
    if (request.processed) revert RequestAlreadyProcessed();

    request.processed = true;
    request.message = reason;

    emit WithdrawalRejected(request.user, request.amount);
  }

  function forceWithdrawAll() external nonReentrant {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    uint256 balance = $.userBalances[msg.sender];
    if (balance < WITHDRAWAL_FEE) revert InsufficientBalance();
    $.userBalances[msg.sender] = 0;
    $.treasuryAmount += WITHDRAWAL_FEE;
    $.token.safeTransfer(msg.sender, balance - WITHDRAWAL_FEE);
    emit Withdraw(msg.sender, balance, 0);
  }

  function claimTreasury() external nonReentrant onlyAdmin {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    uint256 currentTreasuryAmount = $.treasuryAmount;
    $.treasuryAmount = 0;
    $.token.safeTransfer($.operatorVaultAddress, currentTreasuryAmount);
  }

  function retrieveMisplacedETH() external onlyAdmin {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    payable($.adminAddress).transfer(address(this).balance);
  }

  function retrieveMisplacedTokens(address _token) external onlyAdmin {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    if (address($.token) != _token) revert InvalidTokenAddress();
    IERC20 token = IERC20(_token);
    token.safeTransfer($.adminAddress, token.balanceOf(address(this)));
  }

  function userBalances(address user) external view returns (uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.userBalances[user];
  }

  function treasuryAmount() external view returns (uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.treasuryAmount;
  }

  function addTreasuryAmount(uint256 amount) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.treasuryAmount += amount;
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

  function setAdmin(address _adminAddress) external onlyOwner {
    if (_adminAddress == address(0)) revert InvalidAddress();
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.adminAddress = _adminAddress;
  }

  function setOperatorVault(address _operatorVaultAddress) external onlyAdmin {
    if (_operatorVaultAddress == address(0)) revert InvalidAddress();
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.operatorVaultAddress = _operatorVaultAddress;
  }

  function transferBalance(
    address from, 
    address to, 
    uint256 amount
  ) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    
    if ($.userBalances[from] < amount) revert InsufficientBalance();
    $.userBalances[from] -= amount;
    $.userBalances[to] += amount;
    
    emit BalanceTransferred(from, to, amount);
  }

  function addUserBalance(address user, uint256 amount) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.userBalances[user] += amount;
  }

  function subtractUserBalance(address user, uint256 amount) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    if ($.userBalances[user] < amount) revert InsufficientBalance();
    $.userBalances[user] -= amount;
  }

  function addOperator(address operator) external onlyAdmin {
    if (operator == address(0)) revert InvalidAddress();
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.operators[operator] = true;
  }

  function removeOperator(address operator) external onlyAdmin {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.operators[operator] = false;
  }  
  
  function pause() external whenNotPaused onlyAdmin {
    _pause();
  }

  function unpause() external whenPaused onlyAdmin {
    _unpause();
  }

  /* internal functions */
  function _authorizeUpgrade(address) internal override onlyOwner {}

} 
