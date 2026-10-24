// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracle {
    /// @notice Mark / index price with 1e18 precision.
    function price() external view returns (uint256);
}
