// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IOracle } from "./interfaces/IOracle.sol";
import { MarketConfig, MarketState, MarketParams } from "./interfaces/IMarket.sol";
import { InsuranceFund } from "./InsuranceFund.sol";
import { PositionLib } from "./libraries/PositionLib.sol";
import { FundingLib } from "./libraries/FundingLib.sol";
import { RiskLib } from "./libraries/RiskLib.sol";

/// @title ClearingHouse
/// @notice Multi-market perpetual clearing: isolated margin long/short, skew funding,
///         trading fees, keeper liquidations with insurance cover.
contract ClearingHouse is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant RISK_ROLE = keccak256("RISK_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;

    IERC20 public immutable collateral;
    InsuranceFund public insuranceFund;

    uint256 public marketCount;
    mapping(uint256 => MarketConfig) public markets;
    mapping(uint256 => MarketState) public marketState;

    mapping(address => uint256) public freeCollateral;

    struct Position {
        int256 size; // +long / -short, base 1e18
        uint256 margin;
        uint256 entryPrice;
        int256 lastCumulativeFunding;
    }

    // account => marketId => position
    mapping(address => mapping(uint256 => Position)) public positions;

    event MarketListed(uint256 indexed marketId, string symbol, address oracle);
    event MarketUpdated(uint256 indexed marketId);
    event MarketPause(uint256 indexed marketId, bool paused);
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event PositionOpened(
        address indexed account,
        uint256 indexed marketId,
        int256 sizeDelta,
        uint256 margin,
        uint256 price,
        uint256 fee
    );
    event PositionClosed(
        address indexed account,
        uint256 indexed marketId,
        int256 sizeClosed,
        int256 pnl,
        uint256 price,
        uint256 fee
    );
    event MarginAdjusted(address indexed account, uint256 indexed marketId, int256 delta);
    event Liquidated(
        address indexed account,
        uint256 indexed marketId,
        address indexed keeper,
        int256 size,
        int256 equityBefore,
        uint256 penalty,
        uint256 keeperReward,
        uint256 covered
    );
    event FundingSettled(
        uint256 indexed marketId, int256 fundingRateWad, int256 cumulativeFunding, uint256 timestamp
    );

    error ZeroAmount();
    error InsufficientCollateral();
    error InvalidParams();
    error OppositePosition();
    error NoPosition();
    error NotLiquidatable();
    error MaxOIExceeded();
    error FundingNotDue();
    error ZeroPrice();
    error CloseTooLarge();
    error MarketUnknown();
    error MarketPaused();
    error SymbolTaken();

    mapping(string => uint256) private _symbolToId;
    mapping(uint256 => string) public idToSymbol;

    constructor(IERC20 collateral_, InsuranceFund insuranceFund_, address admin) {
        collateral = collateral_;
        insuranceFund = insuranceFund_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RISK_ROLE, admin);
        _grantRole(KEEPER_ROLE, admin);
    }

    // -------- market admin --------

    function listMarket(string calldata symbol, MarketParams calldata p)
        external
        onlyRole(RISK_ROLE)
        returns (uint256 marketId)
    {
        if (bytes(symbol).length == 0 || address(p.oracle) == address(0)) {
            revert InvalidParams();
        }
        if (_symbolExists(symbol)) revert SymbolTaken();
        _validateParams(p);

        marketId = marketCount++;
        markets[marketId] = MarketConfig({
            oracle: p.oracle,
            maxLeverage: p.maxLeverage,
            maintenanceMarginBps: p.maintenanceMarginBps,
            liquidationPenaltyBps: p.liquidationPenaltyBps,
            tradingFeeBps: p.tradingFeeBps,
            keeperIncentiveBps: p.keeperIncentiveBps,
            maxOpenInterest: p.maxOpenInterest,
            minMargin: p.minMargin,
            fundingInterval: p.fundingInterval,
            maxFundingRateWad: p.maxFundingRateWad,
            fundingSensitivityWad: p.fundingSensitivityWad,
            listed: true,
            paused: false
        });
        marketState[marketId].lastFundingTime = block.timestamp;
        idToSymbol[marketId] = symbol;
        _symbolToId[symbol] = marketId + 1; // 1-indexed sentinel

        emit MarketListed(marketId, symbol, address(p.oracle));
    }

    function updateMarketParams(uint256 marketId, MarketParams calldata p)
        external
        onlyRole(RISK_ROLE)
    {
        MarketConfig storage cfg = _listed(marketId);
        if (address(p.oracle) == address(0)) revert InvalidParams();
        _validateParams(p);
        cfg.oracle = p.oracle;
        cfg.maxLeverage = p.maxLeverage;
        cfg.maintenanceMarginBps = p.maintenanceMarginBps;
        cfg.liquidationPenaltyBps = p.liquidationPenaltyBps;
        cfg.tradingFeeBps = p.tradingFeeBps;
        cfg.keeperIncentiveBps = p.keeperIncentiveBps;
        cfg.maxOpenInterest = p.maxOpenInterest;
        cfg.minMargin = p.minMargin;
        cfg.fundingInterval = p.fundingInterval;
        cfg.maxFundingRateWad = p.maxFundingRateWad;
        cfg.fundingSensitivityWad = p.fundingSensitivityWad;
        emit MarketUpdated(marketId);
    }

    function setMarketOracle(uint256 marketId, IOracle oracle)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (address(oracle) == address(0)) revert InvalidParams();
        _listed(marketId).oracle = oracle;
        emit MarketUpdated(marketId);
    }

    function setMarketPaused(uint256 marketId, bool paused) external onlyRole(RISK_ROLE) {
        _listed(marketId).paused = paused;
        emit MarketPause(marketId, paused);
    }

    function setFundingRate(uint256 marketId, int256 rateWad) external onlyRole(RISK_ROLE) {
        MarketConfig storage cfg = _listed(marketId);
        int256 maxR = int256(cfg.maxFundingRateWad);
        if (rateWad > maxR || rateWad < -maxR) revert InvalidParams();
        marketState[marketId].fundingRateWad = rateWad;
    }

    // -------- collateral --------

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        freeCollateral[msg.sender] += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (freeCollateral[msg.sender] < amount) revert InsufficientCollateral();
        freeCollateral[msg.sender] -= amount;
        collateral.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // -------- trading --------

    /// @notice Open / increase. `sizeDelta` > 0 long, < 0 short.
    function openPosition(uint256 marketId, int256 sizeDelta, uint256 marginToAdd)
        external
        nonReentrant
    {
        MarketConfig storage cfg = _active(marketId);
        if (sizeDelta == 0 || marginToAdd == 0) revert ZeroAmount();

        _settleFundingOnAccount(marketId, msg.sender);
        Position storage pos = positions[msg.sender][marketId];
        uint256 mark = _mark(cfg);

        if (pos.size != 0 && (pos.size > 0) != (sizeDelta > 0)) revert OppositePosition();
        if (pos.size == 0 && marginToAdd < cfg.minMargin) revert RiskLib.InvalidLeverage();
        if (freeCollateral[msg.sender] < marginToAdd) revert InsufficientCollateral();

        freeCollateral[msg.sender] -= marginToAdd;

        uint256 notionalDelta = PositionLib.notional(sizeDelta, mark);
        uint256 fee = (notionalDelta * cfg.tradingFeeBps) / BPS;
        if (marginToAdd <= fee) revert InsufficientCollateral();
        uint256 marginNet = marginToAdd - fee;
        _payFee(fee);

        MarketState storage st = marketState[marketId];
        if (pos.size == 0) {
            pos.size = sizeDelta;
            pos.entryPrice = mark;
            pos.margin = marginNet;
            pos.lastCumulativeFunding = st.cumulativeFunding;
        } else {
            pos.entryPrice = PositionLib.blendEntry(pos.size, pos.entryPrice, sizeDelta, mark);
            pos.size += sizeDelta;
            pos.margin += marginNet;
        }

        _applyOIOpen(st, sizeDelta);
        _assertMaxOI(cfg, st, mark);
        RiskLib.assertLeverage(pos.size, pos.margin, pos.entryPrice, mark, cfg.maxLeverage);

        emit PositionOpened(msg.sender, marketId, sizeDelta, marginNet, mark, fee);
    }

    /// @notice Close `closeSize` base units of the current position (absolute).
    function closePosition(uint256 marketId, uint256 closeSize) external nonReentrant {
        MarketConfig storage cfg = _active(marketId);
        if (closeSize == 0) revert ZeroAmount();
        _settleFundingOnAccount(marketId, msg.sender);

        Position storage pos = positions[msg.sender][marketId];
        if (pos.size == 0) revert NoPosition();

        uint256 absSize = PositionLib.abs(pos.size);
        if (closeSize > absSize) revert CloseTooLarge();

        uint256 mark = _mark(cfg);
        int256 closed = pos.size > 0 ? int256(closeSize) : -int256(closeSize);
        int256 pnl = PositionLib.unrealizedPnl(closed, pos.entryPrice, mark);
        uint256 fee = (PositionLib.notional(closed, mark) * cfg.tradingFeeBps) / BPS;
        _payFee(fee);

        uint256 marginRelease = (pos.margin * closeSize) / absSize;
        pos.margin -= marginRelease;
        pos.size -= closed;
        _applyOIClose(marketState[marketId], closed);

        int256 settled = int256(marginRelease) + pnl - int256(fee);
        _creditOrDebit(msg.sender, settled);

        if (pos.size == 0) {
            delete positions[msg.sender][marketId];
        }

        emit PositionClosed(msg.sender, marketId, closed, pnl, mark, fee);
    }

    function addMargin(uint256 marketId, uint256 amount) external nonReentrant {
        _active(marketId);
        if (amount == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender][marketId];
        if (pos.size == 0) revert NoPosition();
        if (freeCollateral[msg.sender] < amount) revert InsufficientCollateral();
        freeCollateral[msg.sender] -= amount;
        pos.margin += amount;
        emit MarginAdjusted(msg.sender, marketId, int256(amount));
    }

    function removeMargin(uint256 marketId, uint256 amount) external nonReentrant {
        MarketConfig storage cfg = _active(marketId);
        if (amount == 0) revert ZeroAmount();
        _settleFundingOnAccount(marketId, msg.sender);
        Position storage pos = positions[msg.sender][marketId];
        if (pos.size == 0) revert NoPosition();
        if (pos.margin < amount) revert InsufficientCollateral();

        pos.margin -= amount;
        uint256 mark = _mark(cfg);
        if (RiskLib.liquidatable(
                pos.size,
                pos.margin,
                pos.entryPrice,
                mark,
                _pendingFunding(marketId, pos),
                cfg.maintenanceMarginBps
            )) {
            pos.margin += amount;
            revert RiskLib.InvalidLeverage();
        }
        RiskLib.assertLeverage(pos.size, pos.margin, pos.entryPrice, mark, cfg.maxLeverage);
        freeCollateral[msg.sender] += amount;
        emit MarginAdjusted(msg.sender, marketId, -int256(amount));
    }

    /// @notice Full or partial liquidation. `closeSize` 0 = full position.
    function liquidate(uint256 marketId, address account, uint256 closeSize)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
    {
        _liquidate(marketId, account, closeSize, msg.sender);
    }

    /// @notice Batch liquidate many accounts on one market (skips healthy / empty).
    function batchLiquidate(uint256 marketId, address[] calldata accounts, uint256 closeSize)
        external
        nonReentrant
        onlyRole(KEEPER_ROLE)
        returns (uint256 liquidated)
    {
        uint256 n = accounts.length;
        for (uint256 i = 0; i < n; i++) {
            address account = accounts[i];
            Position storage pos = positions[account][marketId];
            if (pos.size == 0) continue;
            MarketConfig storage cfg = markets[marketId];
            if (!cfg.listed || cfg.paused) continue;
            _settleFundingOnAccount(marketId, account);
            if (
                !RiskLib.liquidatable(
                    pos.size,
                    pos.margin,
                    pos.entryPrice,
                    _mark(cfg),
                    _pendingFunding(marketId, pos),
                    cfg.maintenanceMarginBps
                )
            ) continue;
            _liquidate(marketId, account, closeSize, msg.sender);
            liquidated++;
        }
    }

    /// @notice Settle funding across many markets in one keeper tick.
    function settleFundingBatch(uint256[] calldata marketIds)
        external
        onlyRole(KEEPER_ROLE)
        returns (uint256 settled)
    {
        uint256 n = marketIds.length;
        for (uint256 i = 0; i < n; i++) {
            if (_trySettleFunding(marketIds[i])) settled++;
        }
    }

    /// @notice Keeper tick: recompute skew funding and bump cumulative index.
    function settleFunding(uint256 marketId) external onlyRole(KEEPER_ROLE) {
        if (!_trySettleFunding(marketId)) revert FundingNotDue();
    }

    // -------- views --------

    function markPrice(uint256 marketId) external view returns (uint256) {
        return _mark(_listed(marketId));
    }

    function accountEquity(address account, uint256 marketId) external view returns (int256) {
        MarketConfig storage cfg = _listed(marketId);
        Position memory pos = positions[account][marketId];
        int256 free = int256(freeCollateral[account]);
        if (pos.size == 0) return free;
        uint256 mark = _mark(cfg);
        int256 pnl = PositionLib.unrealizedPnl(pos.size, pos.entryPrice, mark);
        int256 fundingDebt = _pendingFunding(marketId, pos);
        return PositionLib.equity(pos.margin, pnl, fundingDebt) + free;
    }

    function isLiquidatable(address account, uint256 marketId) external view returns (bool) {
        MarketConfig storage cfg = _listed(marketId);
        Position memory pos = positions[account][marketId];
        if (pos.size == 0) return false;
        return RiskLib.liquidatable(
            pos.size,
            pos.margin,
            pos.entryPrice,
            _mark(cfg),
            _pendingFunding(marketId, pos),
            cfg.maintenanceMarginBps
        );
    }

    function positionOf(address account, uint256 marketId) external view returns (Position memory) {
        return positions[account][marketId];
    }

    function openInterestUsd(uint256 marketId) public view returns (uint256) {
        MarketConfig storage cfg = _listed(marketId);
        MarketState storage st = marketState[marketId];
        uint256 mark = _mark(cfg);
        return PositionLib.notional(int256(st.longOpenInterest), mark)
            + PositionLib.notional(int256(st.shortOpenInterest), mark);
    }

    function previewFundingRate(uint256 marketId) external view returns (int256) {
        MarketConfig storage cfg = _listed(marketId);
        MarketState storage st = marketState[marketId];
        if (cfg.fundingSensitivityWad == 0) return st.fundingRateWad;
        int256 premium = FundingLib.skewPremium(st.longOpenInterest, st.shortOpenInterest);
        return FundingLib.cappedRate(premium, cfg.fundingSensitivityWad, cfg.maxFundingRateWad);
    }

    // ---- internals ----

    function _trySettleFunding(uint256 marketId) internal returns (bool) {
        MarketConfig storage cfg = markets[marketId];
        if (!cfg.listed) return false;
        MarketState storage st = marketState[marketId];
        if (block.timestamp < st.lastFundingTime + cfg.fundingInterval) return false;

        int256 premium = FundingLib.skewPremium(st.longOpenInterest, st.shortOpenInterest);
        int256 rate =
            FundingLib.cappedRate(premium, cfg.fundingSensitivityWad, cfg.maxFundingRateWad);
        if (cfg.fundingSensitivityWad == 0) rate = st.fundingRateWad;
        else st.fundingRateWad = rate;

        st.cumulativeFunding += rate;
        st.lastFundingTime = block.timestamp;
        emit FundingSettled(marketId, rate, st.cumulativeFunding, block.timestamp);
        return true;
    }

    function _liquidate(uint256 marketId, address account, uint256 closeSize, address keeper)
        internal
    {
        MarketConfig storage cfg = _active(marketId);
        _settleFundingOnAccount(marketId, account);
        Position storage pos = positions[account][marketId];
        if (pos.size == 0) revert NoPosition();

        uint256 mark = _mark(cfg);
        if (
            !RiskLib.liquidatable(
                pos.size,
                pos.margin,
                pos.entryPrice,
                mark,
                _pendingFunding(marketId, pos),
                cfg.maintenanceMarginBps
            )
        ) revert NotLiquidatable();

        uint256 absSize = PositionLib.abs(pos.size);
        if (closeSize == 0 || closeSize > absSize) closeSize = absSize;

        int256 closed = pos.size > 0 ? int256(closeSize) : -int256(closeSize);
        int256 pnl = PositionLib.unrealizedPnl(closed, pos.entryPrice, mark);
        uint256 marginSlice = (pos.margin * closeSize) / absSize;
        int256 eq = PositionLib.equity(marginSlice, pnl, 0);
        uint256 notionalUsd = PositionLib.notional(closed, mark);
        uint256 penalty = RiskLib.liquidationPenalty(notionalUsd, cfg.liquidationPenaltyBps);
        uint256 keeperReward = RiskLib.keeperShare(penalty, cfg.keeperIncentiveBps);

        uint256 covered;
        if (eq > 0) {
            uint256 eqU = uint256(eq);
            if (eqU >= penalty) {
                _payFee(penalty - keeperReward);
                if (keeperReward > 0) freeCollateral[keeper] += keeperReward;
                freeCollateral[account] += eqU - penalty;
            } else {
                uint256 toIns = eqU > keeperReward ? eqU - keeperReward : 0;
                if (keeperReward > 0) {
                    uint256 tip = eqU < keeperReward ? eqU : keeperReward;
                    freeCollateral[keeper] += tip;
                    keeperReward = tip;
                }
                _payFee(toIns);
            }
        } else {
            uint256 shortfall = uint256(-eq);
            covered = insuranceFund.cover(address(this), shortfall + penalty);
            uint256 afterShortfall = covered > shortfall ? covered - shortfall : 0;
            if (afterShortfall >= keeperReward && keeperReward > 0) {
                freeCollateral[keeper] += keeperReward;
                _payFee(afterShortfall - keeperReward);
            } else if (afterShortfall > 0) {
                freeCollateral[keeper] += afterShortfall;
                keeperReward = afterShortfall;
            } else {
                keeperReward = 0;
            }
        }

        pos.margin -= marginSlice;
        pos.size -= closed;
        _applyOIClose(marketState[marketId], closed);
        if (pos.size == 0) delete positions[account][marketId];

        emit Liquidated(account, marketId, keeper, closed, eq, penalty, keeperReward, covered);
    }

    function _symbolExists(string memory symbol) internal view returns (bool) {
        uint256 slot = _symbolToId[symbol];
        if (slot == 0) return false;
        return keccak256(bytes(idToSymbol[slot - 1])) == keccak256(bytes(symbol));
    }

    function _validateParams(MarketParams calldata p) internal pure {
        if (
            p.maxLeverage == 0 || p.maxLeverage > 100 || p.maintenanceMarginBps == 0
                || p.maintenanceMarginBps > 2000 || p.liquidationPenaltyBps > 1000
                || p.tradingFeeBps > 100 || p.keeperIncentiveBps > 5000
                || p.fundingInterval < 10 minutes
        ) revert InvalidParams();
    }

    function _listed(uint256 marketId) internal view returns (MarketConfig storage cfg) {
        cfg = markets[marketId];
        if (!cfg.listed) revert MarketUnknown();
    }

    function _active(uint256 marketId) internal view returns (MarketConfig storage cfg) {
        cfg = _listed(marketId);
        if (cfg.paused) revert MarketPaused();
    }

    function _mark(MarketConfig storage cfg) internal view returns (uint256 p) {
        p = cfg.oracle.price();
        if (p == 0) revert ZeroPrice();
    }

    function _pendingFunding(uint256 marketId, Position memory pos) internal view returns (int256) {
        return FundingLib.payment(
            pos.size, marketState[marketId].cumulativeFunding - pos.lastCumulativeFunding
        );
    }

    function _settleFundingOnAccount(uint256 marketId, address account) internal {
        Position storage pos = positions[account][marketId];
        if (pos.size == 0) return;
        int256 debt = _pendingFunding(marketId, pos);
        pos.lastCumulativeFunding = marketState[marketId].cumulativeFunding;
        if (debt == 0) return;
        if (debt > 0) {
            uint256 pay = uint256(debt);
            if (pos.margin >= pay) {
                pos.margin -= pay;
            } else {
                uint256 rest = pay - pos.margin;
                pos.margin = 0;
                if (freeCollateral[account] >= rest) freeCollateral[account] -= rest;
                else freeCollateral[account] = 0;
            }
            _payFee(pay);
        } else {
            pos.margin += uint256(-debt);
        }
    }

    function _applyOIOpen(MarketState storage st, int256 sizeDelta) internal {
        if (sizeDelta > 0) st.longOpenInterest += uint256(sizeDelta);
        else st.shortOpenInterest += uint256(-sizeDelta);
    }

    function _applyOIClose(MarketState storage st, int256 closedSize) internal {
        if (closedSize > 0) st.longOpenInterest -= uint256(closedSize);
        else st.shortOpenInterest -= uint256(-closedSize);
    }

    function _assertMaxOI(MarketConfig storage cfg, MarketState storage st, uint256 mark)
        internal
        view
    {
        if (cfg.maxOpenInterest == 0) return;
        uint256 oi = PositionLib.notional(int256(st.longOpenInterest), mark)
            + PositionLib.notional(int256(st.shortOpenInterest), mark);
        if (oi > cfg.maxOpenInterest) revert MaxOIExceeded();
    }

    function _creditOrDebit(address account, int256 settled) internal {
        if (settled >= 0) {
            freeCollateral[account] += uint256(settled);
            return;
        }
        uint256 loss = uint256(-settled);
        if (freeCollateral[account] >= loss) {
            freeCollateral[account] -= loss;
        } else {
            uint256 shortfall = loss - freeCollateral[account];
            freeCollateral[account] = 0;
            insuranceFund.cover(address(this), shortfall);
        }
    }

    function _payFee(uint256 amount) internal {
        if (amount == 0) return;
        collateral.safeTransfer(address(insuranceFund), amount);
    }
}
