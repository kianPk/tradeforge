// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ClearingHouse } from "../src/ClearingHouse.sol";
import { InsuranceFund } from "../src/InsuranceFund.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockOracle } from "../src/mocks/MockOracle.sol";
import { BoundOracle } from "../src/oracles/BoundOracle.sol";
import { PositionLib } from "../src/libraries/PositionLib.sol";
import { FundingLib } from "../src/libraries/FundingLib.sol";
import { RiskLib } from "../src/libraries/RiskLib.sol";
import { IOracle } from "../src/interfaces/IOracle.sol";
import { MarketParams } from "../src/interfaces/IMarket.sol";

contract TradeForgeTest is Test {
    MockERC20 usdc;
    MockOracle ethOracle;
    MockOracle btcOracle;
    InsuranceFund insurance;
    ClearingHouse house;

    address admin = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper;

    uint256 constant ETH_PRICE = 2000e18;
    uint256 constant BTC_PRICE = 60_000e18;
    uint256 ethId;
    uint256 btcId;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");
        ethOracle = new MockOracle(ETH_PRICE);
        btcOracle = new MockOracle(BTC_PRICE);
        insurance = new InsuranceFund(usdc, admin);
        house = new ClearingHouse(usdc, insurance, admin);
        insurance.setClearingHouse(address(house));
        keeper = admin;

        ethId = _list(
            "ETH-PERP", ethOracle, 20, 500, 250, 10, 1000, 0, 10e18, 1 hours, 0.001e18, 0.5e18
        );
        btcId = _list(
            "BTC-PERP", btcOracle, 10, 500, 250, 10, 1000, 0, 50e18, 1 hours, 0.001e18, 0.5e18
        );

        usdc.mint(alice, 1_000_000e18);
        usdc.mint(bob, 1_000_000e18);
        usdc.mint(address(this), 100_000e18);

        vm.prank(alice);
        usdc.approve(address(house), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(house), type(uint256).max);
    }

    function _list(
        string memory symbol,
        IOracle oracle,
        uint16 maxLev,
        uint16 mmr,
        uint16 liqPen,
        uint16 fee,
        uint16 keeperBps,
        uint256 maxOi,
        uint256 minMargin,
        uint256 interval,
        uint256 maxRate,
        uint256 sens
    ) internal returns (uint256) {
        return house.listMarket(
            symbol,
            MarketParams({
                oracle: oracle,
                maxLeverage: maxLev,
                maintenanceMarginBps: mmr,
                liquidationPenaltyBps: liqPen,
                tradingFeeBps: fee,
                keeperIncentiveBps: keeperBps,
                maxOpenInterest: maxOi,
                minMargin: minMargin,
                fundingInterval: interval,
                maxFundingRateWad: maxRate,
                fundingSensitivityWad: sens
            })
        );
    }

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        house.deposit(amount);
    }

    function test_depositWithdraw() public {
        _deposit(alice, 1000e18);
        assertEq(house.freeCollateral(alice), 1000e18);
        vm.prank(alice);
        house.withdraw(400e18);
        assertEq(house.freeCollateral(alice), 600e18);
    }

    function test_openLongAndCloseProfit() public {
        _deposit(alice, 10_000e18);
        vm.prank(alice);
        house.openPosition(ethId, 1e18, 2500e18);

        ClearingHouse.Position memory pos = house.positionOf(alice, ethId);
        assertEq(pos.size, 1e18);
        assertEq(pos.entryPrice, ETH_PRICE);
        assertGt(pos.margin, 0);

        ethOracle.setPrice(2200e18);
        uint256 freeBefore = house.freeCollateral(alice);
        vm.prank(alice);
        house.closePosition(ethId, 1e18);

        assertEq(house.positionOf(alice, ethId).size, 0);
        assertGt(house.freeCollateral(alice), freeBefore);
    }

    function test_openShortAndCloseProfit() public {
        _deposit(alice, 10_000e18);
        vm.prank(alice);
        house.openPosition(ethId, -1e18, 2500e18);

        ethOracle.setPrice(1800e18);
        uint256 freeBefore = house.freeCollateral(alice);
        vm.prank(alice);
        house.closePosition(ethId, 1e18);
        assertGt(house.freeCollateral(alice), freeBefore);
    }

    function test_multiMarketIndependentPositions() public {
        _deposit(alice, 100_000e18);
        vm.prank(alice);
        house.openPosition(ethId, 1e18, 5000e18);
        vm.prank(alice);
        house.openPosition(btcId, 1e18, 20_000e18); // 1 BTC notional 60k needs margin

        assertEq(house.positionOf(alice, ethId).size, 1e18);
        assertEq(house.positionOf(alice, btcId).size, 1e18);
        assertEq(house.marketCount(), 2);
    }

    function test_duplicateSymbolReverts() public {
        vm.expectRevert(ClearingHouse.SymbolTaken.selector);
        _list("ETH-PERP", ethOracle, 20, 500, 250, 10, 1000, 0, 10e18, 1 hours, 0.001e18, 0.5e18);
    }

    function test_leverageCapReverts() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(RiskLib.InvalidLeverage.selector);
        house.openPosition(ethId, 5e18, 100e18);
    }

    function test_increasePositionBlendsEntry() public {
        _deposit(alice, 50_000e18);
        vm.prank(alice);
        house.openPosition(ethId, 1e18, 5000e18);

        ethOracle.setPrice(2100e18);
        vm.prank(alice);
        house.openPosition(ethId, 1e18, 5000e18);

        ClearingHouse.Position memory pos = house.positionOf(alice, ethId);
        assertEq(pos.size, 2e18);
        assertGt(pos.entryPrice, 2000e18);
        assertLt(pos.entryPrice, 2100e18);
    }

    function test_oppositeDirectionReverts() public {
        _deposit(alice, 10_000e18);
        vm.prank(alice);
        house.openPosition(ethId, 1e18, 3000e18);
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.OppositePosition.selector);
        house.openPosition(ethId, -0.5e18, 3000e18);
    }

    function test_liquidationWhenPriceCrashes() public {
        _deposit(alice, 5_000e18);
        vm.prank(alice);
        house.openPosition(ethId, 2e18, 2500e18);

        usdc.approve(address(insurance), type(uint256).max);
        usdc.transfer(address(insurance), 50_000e18);

        ethOracle.setPrice(500e18);
        assertTrue(house.isLiquidatable(alice, ethId));

        house.liquidate(ethId, alice, 0);
        assertEq(house.positionOf(alice, ethId).size, 0);
    }

    function test_partialLiquidation() public {
        _deposit(alice, 5_000e18);
        vm.prank(alice);
        house.openPosition(ethId, 2e18, 2500e18);

        usdc.approve(address(insurance), type(uint256).max);
        usdc.transfer(address(insurance), 50_000e18);

        ethOracle.setPrice(500e18);
        house.liquidate(ethId, alice, 1e18);
        assertEq(PositionLib.abs(house.positionOf(alice, ethId).size), 1e18);
    }

    function test_keeperReceivesIncentive() public {
        address liqKeeper = makeAddr("liqKeeper");
        house.grantRole(house.KEEPER_ROLE(), liqKeeper);

        _deposit(alice, 5_000e18);
        vm.prank(alice);
        house.openPosition(ethId, 2e18, 2500e18);

        // mild dump so equity still covers penalty (keeper tip from penalty)
        ethOracle.setPrice(780e18);
        assertTrue(house.isLiquidatable(alice, ethId));

        uint256 before = house.freeCollateral(liqKeeper);
        vm.prank(liqKeeper);
        house.liquidate(ethId, alice, 0);
        assertGt(house.freeCollateral(liqKeeper), before);
    }

    function test_skewFundingSettlement() public {
        _deposit(alice, 50_000e18);
        _deposit(bob, 50_000e18);

        // heavy long skew
        vm.prank(alice);
        house.openPosition(ethId, 3e18, 10_000e18);
        vm.prank(bob);
        house.openPosition(ethId, 1e18, 5_000e18);

        int256 preview = house.previewFundingRate(ethId);
        assertGt(preview, 0); // longs pay when long-skewed

        vm.warp(block.timestamp + 1 hours + 1);
        house.settleFunding(ethId);

        uint256 marginBefore = house.positionOf(alice, ethId).margin;
        _deposit(alice, 1e18);
        vm.prank(alice);
        house.addMargin(ethId, 1e18);
        vm.prank(alice);
        house.closePosition(ethId, 0.01e18);
        assertLt(house.positionOf(alice, ethId).margin, marginBefore + 1e18);
    }

    function test_manualFundingWhenSensitivityZero() public {
        MockOracle o = new MockOracle(ETH_PRICE);
        uint256 id = _list("SOL-PERP", o, 20, 500, 250, 10, 1000, 0, 10e18, 1 hours, 0.001e18, 0);
        house.setFundingRate(id, 0.001e18);

        _deposit(alice, 10_000e18);
        vm.prank(alice);
        house.openPosition(id, 1e18, 3000e18);

        vm.warp(block.timestamp + 1 hours + 1);
        house.settleFunding(id);
        assertEq(house.previewFundingRate(id), 0.001e18);
    }

    function test_feesAccrueToInsurance() public {
        _deposit(alice, 10_000e18);
        uint256 before = insurance.balance();
        vm.prank(alice);
        house.openPosition(ethId, 1e18, 3000e18);
        assertGt(insurance.balance(), before);
    }

    function test_pauseBlocksTrading() public {
        _deposit(alice, 10_000e18);
        house.setMarketPaused(ethId, true);
        vm.prank(alice);
        vm.expectRevert(ClearingHouse.MarketPaused.selector);
        house.openPosition(ethId, 1e18, 3000e18);
        house.setMarketPaused(ethId, false);
        vm.prank(alice);
        house.openPosition(ethId, 1e18, 3000e18);
    }

    function test_addRemoveMargin() public {
        _deposit(alice, 20_000e18);
        vm.prank(alice);
        house.openPosition(ethId, 1e18, 5000e18);
        vm.prank(alice);
        house.addMargin(ethId, 1000e18);
        assertEq(house.positionOf(alice, ethId).margin, house.positionOf(alice, ethId).margin);
        uint256 m = house.positionOf(alice, ethId).margin;
        vm.prank(alice);
        house.removeMargin(ethId, 500e18);
        assertEq(house.positionOf(alice, ethId).margin, m - 500e18);
    }

    function test_boundOracleDeviationAndHeartbeat() public {
        BoundOracle bound = new BoundOracle(2000e18, admin);
        bound.setBounds(500, 1 hours); // 5%
        bound.setPrice(2050e18); // ok
        vm.expectRevert(BoundOracle.DeviationTooHigh.selector);
        bound.setPrice(2300e18); // >5%

        // heartbeat
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(BoundOracle.StalePrice.selector);
        bound.price();
        assertEq(bound.rawPrice(), 2050e18);
    }

    function test_positionLibMath() public pure {
        int256 pnl = PositionLib.unrealizedPnl(1e18, 2000e18, 2200e18);
        assertEq(pnl, 200e18);
        pnl = PositionLib.unrealizedPnl(-1e18, 2000e18, 1800e18);
        assertEq(pnl, 200e18);
        uint256 n = PositionLib.notional(2e18, 2000e18);
        assertEq(n, 4000e18);
    }

    function test_fundingLibSkew() public pure {
        int256 prem = FundingLib.skewPremium(3e18, 1e18);
        assertEq(prem, 0.5e18);
        int256 rate = FundingLib.cappedRate(prem, 0.5e18, 0.001e18);
        assertEq(rate, 0.001e18); // capped
    }

    function testFuzz_depositWithdraw(uint256 amount) public {
        amount = bound(amount, 1e18, 100_000e18);
        usdc.mint(alice, amount);
        _deposit(alice, amount);
        vm.prank(alice);
        house.withdraw(amount);
        assertEq(house.freeCollateral(alice), 0);
    }

    function testFuzz_openCloseRoundTrip(uint256 margin) public {
        margin = bound(margin, 2500e18, 50_000e18);
        _deposit(alice, margin + 1000e18);
        vm.prank(alice);
        house.openPosition(ethId, 1e18, margin);
        vm.prank(alice);
        house.closePosition(ethId, 1e18);
        assertEq(house.positionOf(alice, ethId).size, 0);
    }
}
