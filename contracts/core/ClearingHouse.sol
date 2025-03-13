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
import { WithdrawalRequest, ForceWithdrawalRequest, Coupon, BatchWithdrawRequest, CouponUsageDetail, WinPosition, WithdrawalInfo } from "../types/Types.sol";
import { IClearingHouseErrors } from "../errors/ClearingHouseErrors.sol";
import { IVault } from "../interfaces/IVault.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract ClearingHouse is
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ReentrancyGuardUpgradeable,
  IClearingHouseErrors
{
  using SafeERC20 for IERC20;

  uint256 private constant PRICE_UNIT = 1e6;
  uint256 private constant WITHDRAWAL_FEE = PRICE_UNIT / 10; // $0.1
  uint256 private constant MAX_WITHDRAWAL_FEE = 10 * PRICE_UNIT; // $10
  uint256 private constant DEFAULT_FORCE_WITHDRAWAL_DELAY = 24 hours;
  uint256 private constant START_TIMESTAMP = 1736294400; // for epoch

  event Deposit(address indexed to, address from, uint256 amount, uint256 result);
  event Withdraw(address indexed to, uint256 amount, uint256 result);
  event WithdrawalRequested(address indexed user, uint256 amount);
  event WithdrawalApproved(address indexed user, uint256 amount);
  event WithdrawalRejected(address indexed user, uint256 amount);
  event BalanceTransferred(address indexed from, address indexed to, uint256 amount);
  event ForceWithdrawalRequested(address indexed user, uint256 amount);
  event ForceWithdrawalExecuted(address indexed user, uint256 amount);
  event DepositCoupon(
    address indexed to,
    address from,
    uint256 amount,
    uint256 expirationEpoch,
    uint256 result
  );
  event LockInEscrow(
    address indexed product,
    address indexed user,
    uint256 indexed epoch,
    uint256 idx,
    uint256 totalAmount,
    uint256 couponAmount,
    uint256 balanceAmount
  );

  event BatchWithdrawRequested(uint256 indexed batchId, uint256 totalAmount, uint256 requestCount);
  event BatchWithdrawProcessed(
    uint256 indexed batchId,
    uint256 indexed requestId,
    address indexed user,
    uint256 amount,
    uint256 fee
  );
  event DebugLog(string message);

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
    if ($.userBalances[user] < amount + $.withdrawalFee) revert InsufficientBalance();
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
    $.forceWithdrawalDelay = DEFAULT_FORCE_WITHDRAWAL_DELAY;
    $.withdrawalFee = WITHDRAWAL_FEE;
  }

  function deposit(uint256 amount) external nonReentrant {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.token.safeTransferFrom(msg.sender, address(this), amount);
    $.userBalances[msg.sender] += amount;
    emit Deposit(msg.sender, msg.sender, amount, $.userBalances[msg.sender]);
  }

  function depositTo(address user, uint256 amount) external nonReentrant {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    $.token.safeTransferFrom(msg.sender, address(this), amount);
    $.userBalances[user] += amount;
    emit Deposit(user, msg.sender, amount, $.userBalances[user]);
  }

  function depositToVault(
    address product,
    address vaultAddress,
    address user,
    uint256 amount
  ) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    if ($.userBalances[user] < amount) revert InsufficientBalance();
    uint256 balance = $.vault.depositToVault(product, vaultAddress, user, amount);

    // user -> vaultAddress
    _transferBalance(user, vaultAddress, balance);
  }

  function withdrawFromVault(
    address product,
    address vaultAddress,
    address user,
    uint256 amount
  ) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    uint256 balance = $.vault.withdrawFromVault(product, vaultAddress, user, amount);

    // vaultAddress -> user
    _transferBalance(vaultAddress, user, balance);
  }

  function withdrawAllFromVault(
    address product,
    address vaultAddress
  ) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    WithdrawalInfo[] memory withdrawals = $.vault.withdrawAllFromVault(product, vaultAddress);
    for (uint256 i = 0; i < withdrawals.length; i++) {
      WithdrawalInfo memory withdrawal = withdrawals[i];
      // vaultAddress -> user
      _transferBalance(vaultAddress, withdrawal.user, withdrawal.amount);
    }
  }

  function withdraw(
    address user,
    uint256 amount
  ) external nonReentrant onlyOperator validWithdrawal(user, amount) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.userBalances[user] -= amount + $.withdrawalFee;
    $.treasuryAmount += $.withdrawalFee;
    $.token.safeTransfer(user, amount);
    emit Withdraw(user, amount, $.userBalances[user]);
  }

  function requestWithdrawal(
    uint256 amount
  ) external nonReentrant validWithdrawal(msg.sender, amount) returns (WithdrawalRequest memory) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    WithdrawalRequest memory request = WithdrawalRequest({
      idx: $.withdrawalRequests.length,
      user: msg.sender,
      amount: amount,
      processed: false,
      message: "",
      created: block.timestamp
    });

    $.withdrawalRequests.push(request);

    emit WithdrawalRequested(msg.sender, amount);
    return request;
  }

  function approveWithdrawal(uint256 idx) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    if (idx >= $.withdrawalRequests.length) revert InvalidIdx();
    WithdrawalRequest storage request = $.withdrawalRequests[idx];
    if (request.processed) revert RequestAlreadyProcessed();
    if ($.userBalances[request.user] < request.amount + $.withdrawalFee)
      revert InsufficientBalance();
    request.processed = true;
    $.userBalances[request.user] -= request.amount + $.withdrawalFee;
    $.treasuryAmount += $.withdrawalFee;
    $.token.safeTransfer(request.user, request.amount);
    emit WithdrawalApproved(request.user, request.amount);
  }

  function rejectWithdrawal(
    uint256 idx,
    string calldata reason
  ) external nonReentrant onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    if (idx >= $.withdrawalRequests.length) revert InvalidIdx();
    WithdrawalRequest storage request = $.withdrawalRequests[idx];
    if (request.processed) revert RequestAlreadyProcessed();

    request.processed = true;
    request.message = reason;

    emit WithdrawalRejected(request.user, request.amount);
  }

  function requestForceWithdraw() external nonReentrant {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    uint256 balance = $.userBalances[msg.sender];
    if (balance < $.withdrawalFee) revert InsufficientBalance();

    // check if there is an existing force withdrawal request
    for (uint256 i = $.forceWithdrawalRequests.length; i > 0; i--) {
      if (
        $.forceWithdrawalRequests[i - 1].user == msg.sender &&
        !$.forceWithdrawalRequests[i - 1].processed
      ) {
        revert ExistingForceWithdrawalRequest();
      }
    }

    ForceWithdrawalRequest memory request = ForceWithdrawalRequest({
      idx: $.forceWithdrawalRequests.length,
      user: msg.sender,
      amount: balance - $.withdrawalFee,
      processed: false,
      created: block.timestamp
    });

    $.forceWithdrawalRequests.push(request);
    emit ForceWithdrawalRequested(msg.sender, balance - $.withdrawalFee);
  }

  function executeForceWithdraw() external nonReentrant {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    uint256 requestIdx;
    bool found = false;

    for (uint256 i = $.forceWithdrawalRequests.length; i > 0; i--) {
      if (
        $.forceWithdrawalRequests[i - 1].user == msg.sender &&
        !$.forceWithdrawalRequests[i - 1].processed
      ) {
        requestIdx = i - 1;
        found = true;
        break;
      }
    }

    if (!found) revert ForceWithdrawalRequestNotFound();

    ForceWithdrawalRequest storage request = $.forceWithdrawalRequests[requestIdx];

    if (block.timestamp < request.created + $.forceWithdrawalDelay)
      revert ForceWithdrawalTooEarly();
    if ($.userBalances[msg.sender] < request.amount + $.withdrawalFee) revert InsufficientBalance();

    request.processed = true;
    $.userBalances[msg.sender] = 0;
    $.treasuryAmount += $.withdrawalFee;
    $.token.safeTransfer(msg.sender, request.amount);

    emit ForceWithdrawalExecuted(msg.sender, request.amount);
  }

  function withdrawBatch(
    BatchWithdrawRequest[] calldata requests,
    uint256 batchId
  ) external nonReentrant onlyOperator whenNotPaused {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    // Check if batch has already been processed
    if ($.processedBatchIds[batchId]) revert BatchAlreadyProcessed();
    if (batchId == 0) revert InvalidBatchId();
    if (requests.length == 0 || requests.length > 100) revert InvalidAmount();

    uint256 totalAmount = 0;
    uint256 totalFees = 0;

    // First pass: Validation and total calculation
    for (uint256 i = 0; i < requests.length; i++) {
      BatchWithdrawRequest calldata request = requests[i];

      if (request.user == address(0)) revert InvalidAddress();
      if (request.amount == 0) revert InvalidAmount();
      if (request.requestId == 0) revert InvalidRequestId();

      uint256 requiredAmount = request.amount + $.withdrawalFee;
      if ($.userBalances[request.user] < requiredAmount) {
        revert InsufficientBalance();
      }

      totalAmount += request.amount;
      totalFees += $.withdrawalFee;
    }

    // Check total contract balance including fees
    if ($.token.balanceOf(address(this)) < totalAmount + totalFees) {
      revert InsufficientBalance();
    }

    // Mark batch as processed
    $.processedBatchIds[batchId] = true;

    emit BatchWithdrawRequested(batchId, totalAmount, requests.length);

    for (uint256 i = 0; i < requests.length; i++) {
      BatchWithdrawRequest calldata request = requests[i];
      $.userBalances[request.user] -= (request.amount + $.withdrawalFee);
      $.treasuryAmount += $.withdrawalFee;
    }

    for (uint256 i = 0; i < requests.length; i++) {
      BatchWithdrawRequest calldata request = requests[i];
      $.token.safeTransfer(request.user, request.amount);

      emit BatchWithdrawProcessed(
        batchId,
        request.requestId,
        request.user,
        request.amount,
        $.withdrawalFee
      );
      emit Withdraw(request.user, request.amount, $.userBalances[request.user]);
    }
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

  function setAdmin(address _adminAddress) external onlyOwner {
    if (_adminAddress == address(0)) revert InvalidAddress();
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.adminAddress = _adminAddress;
  }

  function setToken(address _token) external onlyAdmin {
    if (_token == address(0)) revert InvalidAddress();
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.token = IERC20(_token);
  }

  function setOperatorVault(address _operatorVaultAddress) external onlyAdmin {
    if (_operatorVaultAddress == address(0)) revert InvalidAddress();
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.operatorVaultAddress = _operatorVaultAddress;
  }

  function setForceWithdrawalDelay(uint256 newDelay) external onlyAdmin {
    if (newDelay == 0) revert InvalidAmount();
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.forceWithdrawalDelay = newDelay;
  }

  function setVault(address _vault) external onlyAdmin {
    if (_vault == address(0)) revert InvalidAddress();
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.vault = IVault(_vault);
  }

  function setWithdrawalFee(uint256 newFee) external onlyAdmin {
    if (newFee > MAX_WITHDRAWAL_FEE) revert InvalidAmount();
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.withdrawalFee = newFee;
  }

  function _transferBalance(address from, address to, uint256 amount) internal {
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
    $.operatorList.push(operator);
  }

  function removeOperator(address operator) external onlyAdmin {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    $.operators[operator] = false;
    for (uint i = 0; i < $.operatorList.length; i++) {
      if ($.operatorList[i] == operator) {
        $.operatorList[i] = $.operatorList[$.operatorList.length - 1];
        $.operatorList.pop();
        break;
      }
    }
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
    emit DepositCoupon(user, msg.sender, amount, expirationEpoch, couponBalanceOf(user)); // 전체 쿠폰 잔액 계산
  }

  function pause() external whenNotPaused onlyAdmin {
    _pause();
  }

  function unpause() external whenPaused onlyAdmin {
    _unpause();
  }

  /* public views */
  function addresses() public view returns (address, address, address, address) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return ($.adminAddress, $.operatorVaultAddress, address($.token), address($.vault));
  }

  function balances(address user) public view returns (uint256, uint256, uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    uint256 depositBalance = $.userBalances[user];
    uint256 couponBalance = this.couponBalanceOf(user);
    uint256 totalBalance = depositBalance + couponBalance;
    return (depositBalance, couponBalance, totalBalance);
  }

  function getToken() external view returns (address) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return address($.token);
  }

  function getOperators() public view returns (address[] memory) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.operatorList;
  }

  function getForceWithdrawalDelay() external view returns (uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.forceWithdrawalDelay;
  }

  function getForceWithdrawStatus(
    address user
  ) external view returns (bool hasRequest, uint256 requestTime, uint256 amount, bool canWithdraw) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    for (uint256 i = $.forceWithdrawalRequests.length; i > 0; i--) {
      ForceWithdrawalRequest storage request = $.forceWithdrawalRequests[i - 1];
      if (request.user == user && !request.processed) {
        return (
          true,
          request.created,
          request.amount,
          block.timestamp >= request.created + $.forceWithdrawalDelay
        );
      }
    }

    return (false, 0, 0, false);
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

  function couponHolders() public view returns (address[] memory) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.couponHolders;
  }

  function getCouponHoldersPaged(
    uint256 offset,
    uint256 size
  ) public view returns (address[] memory) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    uint256 length = $.couponHolders.length;

    if (offset >= length || size == 0) return new address[](0);

    uint256 endIndex = offset + size;
    if (endIndex > length) endIndex = length;

    address[] memory pagedHolders = new address[](endIndex - offset);
    for (uint256 i = offset; i < endIndex; i++) {
      pagedHolders[i - offset] = $.couponHolders[i];
    }
    return pagedHolders;
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

  function userCoupons(address user) public view returns (Coupon[] memory) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.couponBalances[user];
  }

  function getCouponHoldersLength() external view returns (uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.couponHolders.length;
  }

  function reclaimExpiredCouponsByChunk(
    uint256 startIndex,
    uint256 size
  ) external nonReentrant returns (uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    if (startIndex >= $.couponHolders.length) revert InvalidIndex();

    uint256 currentIndex = startIndex;
    uint256 processedCount = 0;

    while (processedCount < size && currentIndex < $.couponHolders.length) {
      address holder = $.couponHolders[currentIndex];
      if (holder != address(0)) {
        uint256 preLength = $.couponHolders.length;
        _reclaimExpiredCoupons(holder);

        if (preLength == $.couponHolders.length) {
          currentIndex++;
        }
        processedCount++;
      } else {
        currentIndex++;
      }
    }

    return currentIndex;
  }

  function reclaimExpiredCoupons(address user) external nonReentrant {
    _reclaimExpiredCoupons(user);
  }

  function getWithdrawalFee() external view returns (uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.withdrawalFee;
  }

  /* internal functions */
  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  function _epochAt(uint256 timestamp) internal pure returns (uint256) {
    if (timestamp < START_TIMESTAMP) revert EpochHasNotStartedYet();
    uint256 elapsedSeconds = timestamp - START_TIMESTAMP;
    uint256 elapsedHours = elapsedSeconds / 3600;
    return elapsedHours;
  }

  function useCoupon(
    address user,
    uint256 amount,
    uint256 epoch
  ) external nonReentrant onlyOperator returns (uint256) {
    return _useCoupon(user, amount, epoch);
  }

  function _useCoupon(address user, uint256 amount, uint256 epoch) internal returns (uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    uint256 remainingAmount = amount;

    for (uint i = 0; i < $.couponBalances[user].length && remainingAmount > 0; i++) {
      if ($.couponBalances[user][i].expirationEpoch >= epoch) {
        uint256 availableAmount = $.couponBalances[user][i].amount -
          $.couponBalances[user][i].usedAmount;

        if (availableAmount >= remainingAmount) {
          $.couponBalances[user][i].usedAmount += remainingAmount;
          remainingAmount = 0;
        } else {
          $.couponBalances[user][i].usedAmount += availableAmount;
          remainingAmount -= availableAmount;
        }

        $.couponUsageHistory[user][epoch].push(
          CouponUsageDetail({
            amountUsed: amount - remainingAmount,
            usedAt: block.timestamp,
            issuer: $.couponBalances[user][i].issuer,
            expirationEpoch: $.couponBalances[user][i].expirationEpoch
          })
        );
      }
    }
    $.usedCouponAmount += amount - remainingAmount;
    return remainingAmount;
  }

  function _reclaimExpiredCoupons(address user) internal {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    uint256 epoch = _epochAt(block.timestamp);

    Coupon[] storage coupons = $.couponBalances[user];

    uint256 validCount = 0;
    for (uint i = 0; i < coupons.length; i++) {
      Coupon storage coupon = coupons[i];
      if (coupon.expirationEpoch < epoch) {
        uint256 availableAmount = coupon.amount - coupon.usedAmount;
        if (availableAmount > 0) {
          $.token.safeTransfer(coupon.issuer, availableAmount);
          $.couponAmount -= availableAmount;
          coupon.usedAmount = coupon.amount;
        }
      } else {
        // move valid coupons to the front of the array
        coupons[validCount] = coupon;
        validCount++;
      }
    }

    // remove expired coupons from the array
    while (coupons.length > validCount) {
      coupons.pop();
    }

    if (validCount == 0) {
      // remove user from couponHolders array
      uint length = $.couponHolders.length;
      for (uint i = 0; i < length; i++) {
        if ($.couponHolders[i] == user) {
          $.couponHolders[i] = $.couponHolders[length - 1];
          $.couponHolders.pop();
          break;
        }
      }
    }
  }

  function lockInEscrow(
    address product,
    address user,
    uint256 amount,
    uint256 epoch,
    uint256 idx,
    bool applyCoupon
  ) external onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    uint256 remainingAmount = applyCoupon ? _useCoupon(user, amount, epoch) : amount;
    $.productEscrowCoupons[product][epoch][user][idx] += amount - remainingAmount;

    if (remainingAmount > 0) {
      if ($.userBalances[user] < remainingAmount) {
        revert InsufficientBalance();
      }

      $.userBalances[user] -= remainingAmount;
      $.productEscrowBalances[product][epoch][user][idx] += remainingAmount;
    }
    emit DebugLog(
      string.concat(
        "Product: ",
        Strings.toHexString(product),
        " Order ",
        Strings.toString(idx),
        ": Lock in escrow for ",
        Strings.toHexString(user),
        " total amount: ",
        Strings.toString(amount),
        " coupon: ",
        Strings.toString(amount - remainingAmount),
        " balance: ",
        Strings.toString(remainingAmount)
      )
    );
    emit LockInEscrow(product, user, epoch, idx, amount, amount - remainingAmount, remainingAmount);
  }

  function releaseFromEscrow(
    address product,
    address user,
    uint256 epoch,
    uint256 idx,
    uint256 amount,
    uint256 fee
  ) external onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    // Validate total escrowed amount
    uint256 totalEscrowed = $.productEscrowCoupons[product][epoch][user][idx] +
      $.productEscrowBalances[product][epoch][user][idx];
    emit DebugLog(
      string.concat(
        "Product: ",
        Strings.toHexString(product),
        " Order ",
        Strings.toString(idx),
        ": Release from escrow for ",
        Strings.toHexString(user),
        " total escrowed: ",
        Strings.toString(totalEscrowed),
        " amount: ",
        Strings.toString(amount),
        " fee: ",
        Strings.toString(fee)
      )
    );
    if (totalEscrowed < amount) revert InsufficientBalance();
    uint256 amountAfterFee = amount - fee;

    // Release coupon escrow first
    uint256 couponAmount = $.productEscrowCoupons[product][epoch][user][idx];
    if (couponAmount > 0) {
      // Find original coupon issuer
      address originalIssuer = address(0);
      Coupon[] storage coupons = $.couponBalances[user];
      CouponUsageDetail[] storage usageDetails = $.couponUsageHistory[user][epoch];

      if (usageDetails.length > 0) {
        originalIssuer = usageDetails[usageDetails.length - 1].issuer;
      } else {
        // If original issuer is not found, use operator vault address
        originalIssuer = $.operatorVaultAddress;
      }

      // Create new coupon entry with original issuer
      Coupon memory newCoupon = Coupon({
        user: user,
        amount: couponAmount,
        usedAmount: 0,
        expirationEpoch: usageDetails[usageDetails.length - 1].expirationEpoch,
        created: block.timestamp,
        issuer: originalIssuer
      });

      if (coupons.length == 0) {
        $.couponHolders.push(user);
      }
      coupons.push(newCoupon);
      $.productEscrowCoupons[product][epoch][user][idx] = 0;
    }

    uint256 balanceAmount = $.productEscrowBalances[product][epoch][user][idx];
    if (balanceAmount > 0) {
      $.userBalances[user] += amountAfterFee;
      if (fee > 0) {
        $.treasuryAmount += fee;
      }
      $.productEscrowBalances[product][epoch][user][idx] = 0;
    }
  }

  function settleEscrowWithFee(
    address product,
    address loser,
    address winner,
    uint256 epoch,
    uint256 amount,
    uint256 idx,
    uint256 fee
  ) external onlyOperator {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();

    // Validate total escrowed amount
    uint256 totalEscrowed = $.productEscrowCoupons[product][epoch][loser][idx] +
      $.productEscrowBalances[product][epoch][loser][idx];
    if (totalEscrowed < amount) revert InsufficientBalance();

    uint256 amountAfterFee = amount - fee;

    // First try to convert from coupon escrow
    uint256 fromCouponEscrow = $.productEscrowCoupons[product][epoch][loser][idx];
    uint256 remainingAmount = amount;
    if (fromCouponEscrow > 0) {
      uint256 couponToUse = fromCouponEscrow > remainingAmount ? remainingAmount : fromCouponEscrow;
      $.productEscrowCoupons[product][epoch][loser][idx] -= couponToUse;
      remainingAmount -= couponToUse;
    }

    // If there's remaining amount, convert from balance escrow
    if (remainingAmount > 0) {
      if ($.productEscrowBalances[product][epoch][loser][idx] < remainingAmount)
        revert InsufficientBalance();
      $.productEscrowBalances[product][epoch][loser][idx] -= remainingAmount;
    }

    // Transfer amount after fee to winner
    if (amountAfterFee > 0) {
      $.userBalances[winner] += amountAfterFee;
    }

    // Transfer fee to treasury
    if (fee > 0) {
      $.treasuryAmount += fee;
    }
  }

  function escrowBalances(
    address product,
    uint256 epoch,
    address user,
    uint256 idx
  ) external view returns (uint256, uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return (
      $.productEscrowBalances[product][epoch][user][idx],
      $.productEscrowCoupons[product][epoch][user][idx]
    );
  }

  function escrowCoupons(
    address product,
    uint256 epoch,
    address user,
    uint256 idx
  ) external view returns (uint256) {
    ClearingHouseStorage.Layout storage $ = ClearingHouseStorage.layout();
    return $.productEscrowCoupons[product][epoch][user][idx];
  }
}
