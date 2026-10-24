// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { ClearingHouse } from "../src/ClearingHouse.sol";
import { InsuranceFund } from "../src/InsuranceFund.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockOracle } from "../src/mocks/MockOracle.sol";
import { BoundOracle } from "../src/oracles/BoundOracle.sol";
import { MarketParams } from "../src/interfaces/IMarket.sol";
import { IOracle } from "../src/interfaces/IOracle.sol";

contract DeployTradeForge is Script {
    function run() external {
        uint256 pk = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address admin = vm.addr(pk);

        vm.startBroadcast(pk);

        MockERC20 usdc = new MockERC20("TradeForge USD", "tfUSD");
        MockOracle ethFeed = new MockOracle(2000e18);
        BoundOracle btcFeed = new BoundOracle(60_000e18, admin);
        InsuranceFund insurance = new InsuranceFund(usdc, admin);
        ClearingHouse house = new ClearingHouse(usdc, insurance, admin);
        insurance.setClearingHouse(address(house));

        uint256 ethId = house.listMarket(
            "ETH-PERP",
            MarketParams({
                oracle: IOracle(address(ethFeed)),
                maxLeverage: 20,
                maintenanceMarginBps: 500,
                liquidationPenaltyBps: 250,
                tradingFeeBps: 10,
                keeperIncentiveBps: 1000,
                maxOpenInterest: 0,
                minMargin: 10e18,
                fundingInterval: 1 hours,
                maxFundingRateWad: 0.001e18,
                fundingSensitivityWad: 0.5e18
            })
        );
        uint256 btcId = house.listMarket(
            "BTC-PERP",
            MarketParams({
                oracle: IOracle(address(btcFeed)),
                maxLeverage: 10,
                maintenanceMarginBps: 500,
                liquidationPenaltyBps: 250,
                tradingFeeBps: 10,
                keeperIncentiveBps: 1000,
                maxOpenInterest: 0,
                minMargin: 50e18,
                fundingInterval: 1 hours,
                maxFundingRateWad: 0.001e18,
                fundingSensitivityWad: 0.5e18
            })
        );

        usdc.mint(admin, 1_000_000e18);

        console2.log("tfUSD", address(usdc));
        console2.log("EthOracle", address(ethFeed));
        console2.log("BtcBoundOracle", address(btcFeed));
        console2.log("InsuranceFund", address(insurance));
        console2.log("ClearingHouse", address(house));
        console2.log("ETH-PERP id", ethId);
        console2.log("BTC-PERP id", btcId);

        vm.stopBroadcast();
    }
}
