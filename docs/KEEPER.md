# Keeper runbook

## Funding
Call `settleFunding(marketId)` or `settleFundingBatch(ids)` once per `fundingInterval`.

## Liquidations
1. Scan `isLiquidatable(account, marketId)`
2. Prefer `batchLiquidate` for toxic books
3. Keep insurance fund topped up so underwater shorts get covered

## Roles
- `KEEPER_ROLE` — settle + liquidate
- `RISK_ROLE` — params / pause
