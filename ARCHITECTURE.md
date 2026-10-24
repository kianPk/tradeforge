# TradeForge architecture

## Contracts

### ClearingHouse

Central multi-market engine. Shared ERC-20 collateral vault; positions keyed by `(account, marketId)`.

**Admin / risk**

- `listMarket(symbol, MarketParams)` — register a perp with oracle + risk band
- `updateMarketParams` / `setMarketOracle` / `setMarketPaused`
- `setFundingRate` — manual override when `fundingSensitivityWad == 0`

**Trader**

- `deposit` / `withdraw` — free collateral
- `openPosition(marketId, sizeDelta, marginToAdd)` — open or increase same side
- `closePosition(marketId, closeSize)` — proportional margin release + PnL
- `addMargin` / `removeMargin` — isolated top-ups (remove reverts if it would breach leverage/MMR)

**Keeper**

- `settleFunding(marketId)` — skew premium → capped rate → bump cumulative index
- `liquidate(marketId, account, closeSize)` — full (`0`) or partial; keeper tip from penalty; insurance covers underwater equity

### InsuranceFund

Ownable vault. Only the clearing house may `cover(to, amount)`. Trading fees are transferred in via `_payFee`.

### Oracles

- `IOracle.price()` → 1e18 mark
- `BoundOracle` — feeder role, max tick deviation, heartbeat revert on stale reads
- `MockOracle` — lab setPrice

### Libraries

- `PositionLib` — abs, unrealized PnL, notional, equity, MMR, blend entry
- `FundingLib` — skew premium, capped rate, payment
- `RiskLib` — leverage assert, liquidatable check, penalty / keeper share

## Funding

```text
premium = (longOI - shortOI) / (longOI + shortOI)   # WAD
rate    = clamp(premium * sensitivity, ±maxRate)
cumulativeFunding += rate   # once per fundingInterval
account payment = size * Δcumulative / WAD          # + = trader pays
```

Settled lazily on open/close/margin/liquidate before position math.

## Liquidation

1. Settle funding
2. Require `equity < maintenanceMargin` (or equity ≤ 0)
3. Slice `closeSize` (or full)
4. Penalty = notional × liquidationPenaltyBps
5. Keeper share = penalty × keeperIncentiveBps
6. Residual fee → insurance; shortfall → `insurance.cover`

## Invariants (lab)

- Opposite-side open reverts (close first)
- Max leverage enforced on open / removeMargin
- Max OI (USD) optional per market
- Paused market blocks trading & liquidations
- Symbol uniqueness on list
