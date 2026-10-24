// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title InsuranceFund
/// @notice Holds trading fees and covers shortfalls from underwater liquidations.
contract InsuranceFund is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateral;
    address public clearingHouse;

    event ClearingHouseUpdated(address indexed house);
    event Covered(address indexed account, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    error Unauthorized();
    error ZeroAddress();

    modifier onlyHouse() {
        if (msg.sender != clearingHouse) revert Unauthorized();
        _;
    }

    constructor(IERC20 collateral_, address owner_) Ownable(owner_) {
        collateral = collateral_;
    }

    function setClearingHouse(address house) external onlyOwner {
        if (house == address(0)) revert ZeroAddress();
        clearingHouse = house;
        emit ClearingHouseUpdated(house);
    }

    function balance() public view returns (uint256) {
        return collateral.balanceOf(address(this));
    }

    /// @notice ClearingHouse pulls coverage for bad debt (up to available balance).
    function cover(address to, uint256 amount) external onlyHouse returns (uint256 paid) {
        uint256 bal = balance();
        paid = amount > bal ? bal : amount;
        if (paid > 0) {
            collateral.safeTransfer(to, paid);
            emit Covered(to, paid);
        }
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
        collateral.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }
}
