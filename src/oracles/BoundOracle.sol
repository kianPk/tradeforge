// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IOracle } from "../interfaces/IOracle.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title BoundOracle
/// @notice Mark price oracle with max deviation + heartbeat staleness guards.
contract BoundOracle is IOracle, AccessControl {
    bytes32 public constant FEEDER_ROLE = keccak256("FEEDER_ROLE");

    uint256 private _price;
    uint256 public lastUpdate;
    uint256 public maxDeviationBps = 500; // 5% per tick
    uint256 public heartbeat = 1 hours;
    uint256 public constant BPS = 10_000;

    event PriceUpdated(uint256 price, uint256 timestamp);
    event BoundsUpdated(uint256 maxDeviationBps, uint256 heartbeat);

    error ZeroPrice();
    error DeviationTooHigh();
    error StalePrice();

    constructor(uint256 initialPrice, address admin) {
        if (initialPrice == 0) revert ZeroPrice();
        _price = initialPrice;
        lastUpdate = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEEDER_ROLE, admin);
    }

    function setBounds(uint256 maxDeviationBps_, uint256 heartbeat_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        maxDeviationBps = maxDeviationBps_;
        heartbeat = heartbeat_;
        emit BoundsUpdated(maxDeviationBps_, heartbeat_);
    }

    function setPrice(uint256 next) external onlyRole(FEEDER_ROLE) {
        if (next == 0) revert ZeroPrice();
        uint256 cur = _price;
        if (cur != 0) {
            uint256 hi = cur > next ? cur : next;
            uint256 lo = cur > next ? next : cur;
            uint256 dev = ((hi - lo) * BPS) / cur;
            if (dev > maxDeviationBps) revert DeviationTooHigh();
        }
        _price = next;
        lastUpdate = block.timestamp;
        emit PriceUpdated(next, block.timestamp);
    }

    /// @inheritdoc IOracle
    function price() external view override returns (uint256) {
        if (block.timestamp > lastUpdate + heartbeat) revert StalePrice();
        return _price;
    }

    /// @notice Unchecked read for admin tooling (ignores heartbeat).
    function rawPrice() external view returns (uint256) {
        return _price;
    }
}
