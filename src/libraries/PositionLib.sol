// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pure helpers for perpetual position math (1e18 fixed-point).
library PositionLib {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    error ZeroPrice();
    error InvalidSize();

    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    /// @dev Unrealized PnL = size * (mark - entry) / 1e18
    function unrealizedPnl(int256 size, uint256 entryPrice, uint256 markPrice)
        internal
        pure
        returns (int256)
    {
        if (entryPrice == 0 || markPrice == 0) revert ZeroPrice();
        return (size * (int256(markPrice) - int256(entryPrice))) / int256(WAD);
    }

    /// @dev Notional exposure at mark: |size| * mark / 1e18
    function notional(int256 size, uint256 markPrice) internal pure returns (uint256) {
        if (markPrice == 0) revert ZeroPrice();
        return (abs(size) * markPrice) / WAD;
    }

    /// @dev Equity = margin + pnl - pendingFunding (funding already signed)
    function equity(uint256 margin, int256 pnl, int256 fundingDebt) internal pure returns (int256) {
        return int256(margin) + pnl - fundingDebt;
    }

    function maintenanceMargin(uint256 notionalUsd, uint16 mmrBps) internal pure returns (uint256) {
        return (notionalUsd * uint256(mmrBps)) / BPS;
    }

    /// @dev Blend entry price when increasing a position in the same direction.
    function blendEntry(int256 oldSize, uint256 oldEntry, int256 addSize, uint256 fillPrice)
        internal
        pure
        returns (uint256)
    {
        if (addSize == 0) revert InvalidSize();
        if (oldSize == 0) return fillPrice;
        // same sign increase
        uint256 oldAbs = abs(oldSize);
        uint256 addAbs = abs(addSize);
        return ((oldAbs * oldEntry) + (addAbs * fillPrice)) / (oldAbs + addAbs);
    }
}
