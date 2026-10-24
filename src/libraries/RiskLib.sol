// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PositionLib } from "./PositionLib.sol";

/// @notice Leverage / maintenance / liquidation checks.
library RiskLib {
    uint256 internal constant BPS = 10_000;

    error InvalidLeverage();

    function assertLeverage(
        int256 size,
        uint256 margin,
        uint256 entryPrice,
        uint256 mark,
        uint16 maxLeverage
    ) internal pure {
        int256 pnl = PositionLib.unrealizedPnl(size, entryPrice, mark);
        int256 eq = PositionLib.equity(margin, pnl, 0);
        if (eq <= 0) revert InvalidLeverage();
        uint256 notionalUsd = PositionLib.notional(size, mark);
        if (notionalUsd > uint256(eq) * uint256(maxLeverage)) revert InvalidLeverage();
    }

    function liquidatable(
        int256 size,
        uint256 margin,
        uint256 entryPrice,
        uint256 mark,
        int256 fundingDebt,
        uint16 maintenanceMarginBps
    ) internal pure returns (bool) {
        if (size == 0) return false;
        int256 pnl = PositionLib.unrealizedPnl(size, entryPrice, mark);
        int256 eq = PositionLib.equity(margin, pnl, fundingDebt);
        if (eq <= 0) return true;
        uint256 maint =
            PositionLib.maintenanceMargin(PositionLib.notional(size, mark), maintenanceMarginBps);
        return uint256(eq) < maint;
    }

    function liquidationPenalty(uint256 notionalUsd, uint16 penaltyBps)
        internal
        pure
        returns (uint256)
    {
        return (notionalUsd * uint256(penaltyBps)) / BPS;
    }

    function keeperShare(uint256 penalty, uint16 keeperBps) internal pure returns (uint256) {
        return (penalty * uint256(keeperBps)) / BPS;
    }
}
