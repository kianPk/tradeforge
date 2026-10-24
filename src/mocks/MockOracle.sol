// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IOracle } from "../interfaces/IOracle.sol";

contract MockOracle is IOracle {
    uint256 private _price;
    address public setter;

    error Unauthorized();

    constructor(uint256 initialPrice) {
        _price = initialPrice;
        setter = msg.sender;
    }

    function price() external view returns (uint256) {
        return _price;
    }

    function setPrice(uint256 next) external {
        if (msg.sender != setter) revert Unauthorized();
        _price = next;
    }
}
