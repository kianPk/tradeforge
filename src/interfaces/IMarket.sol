// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IOracle } from "./IOracle.sol";

/// @notice Per-market risk + funding configuration.
struct MarketConfig {
    IOracle oracle;
    uint16 maxLeverage;
    uint16 maintenanceMarginBps;
    uint16 liquidationPenaltyBps;
    uint16 tradingFeeBps;
    uint16 keeperIncentiveBps; // share of penalty paid to liquidator
    uint256 maxOpenInterest; // USD notional 1e18, 0 = uncapped
    uint256 minMargin;
    uint256 fundingInterval;
    uint256 maxFundingRateWad;
    uint256 fundingSensitivityWad; // maps skew premium → rate
    bool listed;
    bool paused;
}

/// @notice Input params for listing / updating a market (no listed/paused flags).
struct MarketParams {
    IOracle oracle;
    uint16 maxLeverage;
    uint16 maintenanceMarginBps;
    uint16 liquidationPenaltyBps;
    uint16 tradingFeeBps;
    uint16 keeperIncentiveBps;
    uint256 maxOpenInterest;
    uint256 minMargin;
    uint256 fundingInterval;
    uint256 maxFundingRateWad;
    uint256 fundingSensitivityWad;
}

struct MarketState {
    uint256 longOpenInterest;
    uint256 shortOpenInterest;
    int256 cumulativeFunding;
    uint256 lastFundingTime;
    int256 fundingRateWad;
}
