# TradeForge

**Multi-market perpetual futures clearing in Solidity** — isolated-margin long/short across listed markets, skew-based funding, trading fees, partial keeper liquidations with incentives, and an insurance fund. Built with Foundry + OpenZeppelin.

![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636?logo=solidity)
![Foundry](https://img.shields.io/badge/Foundry-24%20tests-22d3ee)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

## Why this exists

TradeForge is a production-shaped derivatives risk lab — not a single-market toy counter. One `ClearingHouse` lists many perps (ETH-PERP, BTC-PERP, …), each with its own oracle, leverage band, fees, and funding sensitivity. Traders deposit shared collateral, open isolated positions per market, and keepers settle skew funding or liquidate underwater books into the insurance vault.

## Architecture

| Piece | Role |
|---|---|
| `ClearingHouse` | List/pause markets · **protocol pause** · deposit/withdraw · open/increase · close · add/remove margin · partial + **batch liquidate** · funding settle / **batch funding** |
| `InsuranceFund` | Fee sink · covers shortfalls on toxic liquidations |
| `BoundOracle` | Mark feed with max deviation + heartbeat staleness |
| `MockOracle` | Simple lab feed |
| `FundingLib` | Skew premium → capped funding rate |
| `RiskLib` / `PositionLib` | Leverage, MMR, PnL, notional, entry blend |

```text
Trader ──deposit──▶ ClearingHouse ──fees──▶ InsuranceFund
              │              │
         open/close     settleFunding (skew)
              │              │
         positions[account][marketId]
              │
         liquidate ──keeper tip──▶ keeper freeCollateral
                     └──cover──▶ InsuranceFund
```

### Position model

- `size` — signed base (`+` long / `-` short), 1e18
- `margin` — isolated collateral locked in that market
- `entryPrice` — volume-weighted blend on increases
- `lastCumulativeFunding` — settles on every interaction

### Default risk band (ETH-PERP demo)

- Max leverage **20x** · Maintenance **5%** · Liq penalty **2.5%**
- Trading fee **0.10%** · Keeper tip **10%** of penalty
- Funding interval **1h** · skew sensitivity → rate (capped)

## Quick start

```bash
git clone https://github.com/kianPk/tradeforge
cd tradeforge
forge install
forge test
forge test -vvv
```

Deploy local markets (ETH-PERP + BTC-PERP):

```bash
forge script script/Deploy.s.sol --broadcast
```

## Tests

```text
21 passing — deposit/withdraw · long/short PnL · multi-market
leverage cap · entry blend · opposite-side guard · full + partial liq
keeper incentive · skew funding · manual funding · fees · pause
BoundOracle deviation/heartbeat · PositionLib/FundingLib · fuzz
```

## Demo

[kianpk.github.io/tradeforge](https://kianpk.github.io/tradeforge/) — interactive position desk + protocol surface.

## Disclaimer

Educational / research protocol lab. **Not audited.** Do not deploy with real funds.
