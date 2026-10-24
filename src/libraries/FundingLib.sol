// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Skew-based perpetual funding helpers (1e18 fixed-point).
library FundingLib {
    uint256 internal constant WAD = 1e18;

    /// @dev Premium = (longOI - shortOI) / (longOI + shortOI), clamped to [-1, 1] in WAD.
    function skewPremium(uint256 longOI, uint256 shortOI) internal pure returns (int256) {
        uint256 total = longOI + shortOI;
        if (total == 0) return 0;
        int256 diff = int256(longOI) - int256(shortOI);
        return (diff * int256(WAD)) / int256(total);
    }

    /// @dev Rate = clamp(premium * sensitivity, -maxRate, +maxRate).
    function cappedRate(int256 premiumWad, uint256 sensitivityWad, uint256 maxRateWad)
        internal
        pure
        returns (int256 rate)
    {
        rate = (premiumWad * int256(sensitivityWad)) / int256(WAD);
        int256 maxR = int256(maxRateWad);
        if (rate > maxR) rate = maxR;
        else if (rate < -maxR) rate = -maxR;
    }

    /// @dev Funding payment owed by position: size * rateDelta / WAD (positive = trader pays).
    function payment(int256 size, int256 cumulativeDelta) internal pure returns (int256) {
        return (size * cumulativeDelta) / int256(WAD);
    }
}
