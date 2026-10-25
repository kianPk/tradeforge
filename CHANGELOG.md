# Changelog

All notable changes to this project are documented here.

## [Unreleased]

## [1.1.0] - 2026-10-25

### Added
- Protocol-wide pause (`setProtocolPaused`) for incident response.
- `batchLiquidate` for keepers to clear multiple underwater accounts in one tx (skips healthy candidates).
- `settleFundingBatch` to tick funding across many markets without reverting on not-due markets.
- CONTRIBUTING and SECURITY policy docs.
