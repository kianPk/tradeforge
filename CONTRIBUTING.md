# Contributing

Thanks for interest in TradeForge.

## Setup

```bash
forge install
forge build
forge test -vvv
```

## Guidelines

- Keep risk math in libraries (`RiskLib`, `PositionLib`, `FundingLib`) and covered by unit + fuzz tests.
- Prefer isolated-margin invariants; do not silently share margin across markets.
- Open an issue before large protocol redesigns.
- Conventional commits preferred (`feat:`, `fix:`, `test:`).
