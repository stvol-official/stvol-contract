// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

enum WinPosition {
  Over,
  Under,
  Tie,
  Invalid
}

struct Round {
  uint256 epoch;
  uint256 startTimestamp;
  uint256 endTimestamp;
  bool isSettled; // true when endPrice is set
  mapping(uint256 => uint256) startPrice; // key: productId
  mapping(uint256 => uint256) endPrice; // key: productId
  bool isStarted;
}

struct ProductRound {
  uint256 epoch;
  uint256 startTimestamp;
  uint256 endTimestamp;
  bool isSettled;
  uint256 startPrice;
  uint256 endPrice;
  bool isStarted;
}

struct FilledOrder {
  uint256 idx;
  uint256 epoch;
  uint256 productId;
  uint256 strike;
  address overUser;
  address underUser;
  uint256 overPrice;
  uint256 underPrice; // over_price + under_price = 100 * decimal
  uint256 unit;
  bool isSettled; // default: false
}

struct SettlementResult {
  uint256 idx; // filled order idx
  WinPosition winPosition;
  uint256 winAmount;
  uint256 feeRate;
  uint256 fee;
}

struct WithdrawalRequest {
  uint256 idx;
  address user;
  uint256 amount;
  bool processed;
  string message;
  uint256 created;
}

struct ForceWithdrawalRequest {
  uint256 idx;
  address user;
  uint256 amount;
  bool processed;
  uint256 created;
}

struct Coupon {
  address user;
  uint256 amount;
  uint256 usedAmount;
  uint256 expirationEpoch;
  uint256 created;
  address issuer;
}

struct VaultInfo {
  address vault;
  address leader;
  uint256 balance;
  uint256 profitShare;
  uint256 totalShares;
  bool closed;
  uint256 created;
}

struct VaultMember {
  address vault;
  address user;
  uint256 balance;
  uint256 shares;
  uint256 created;
}

struct VaultBalance {
  address vault;
  uint256 balance;
}

// One min
enum Position {
  Over,
  Under
}

struct OneMinOrder {
  uint256 idx;
  uint256 epoch;
  address user;
  uint256 productId;
  Position position;
  uint256 amount;
  uint256 collateralAmount;
  uint256 entryPrice;
  uint256 entryTime;
  uint256 closingPrice;
  uint256 closingTime;
  uint256 settleAmount;
  bool isSettled;
}

struct ClosingOneMinOrder {
  uint256 idx;
  uint256 closingPrice;
  uint256 closingTime;
  uint256 settleAmount;
}

struct BatchWithdrawRequest {
  address user;
  uint256 amount;
  uint256 requestId;
}

struct CouponUsageDetail {
  uint256 amountUsed;
  uint256 usedAt;
  address issuer;
  uint256 expirationEpoch;
}

struct WithdrawalInfo {
  address user;
  uint256 amount;
}

enum TimeUnit {
  MINUTE,
  HOUR,
  DAY
}

struct Product {
  uint256 startTimestamp;
  TimeUnit timeUnit;
  bool isActive;
}

struct ProductInfo {
  address productAddress;
  uint256 startTimestamp;
  TimeUnit timeUnit;
  bool isActive;
}

struct PriceInfo {
  bytes32 priceId; // pyth price id
  uint256 productId; // product id
  string symbol; // symbol(ex: "BTC/USD")
}

struct PriceUpdateData {
  bytes priceData; // pyth price data
  uint256 productId; // product id
}

struct ManualPriceData {
  uint64 price;
  uint256 productId;
}

struct PriceFeedMapping {
  uint256 priceFeedId;
  uint256 productId;
}

struct PriceLazerData {
  bytes priceData;
  PriceFeedMapping[] mappings;
}
