# Contributing

Keep the teaching story intact: inflation + fee-creep PoCs, green invariants on the **fixed** contracts, opt-in red runs on the vulnerable variants.

```bash
forge fmt
forge test -vv
script/check-layout.sh
```

- Do not delete `test_inflation_attack_drains_vulnerable_pool` or `test_fee_creep_drains_vulnerable_vault`.
- Do not make `VulnerablePoolInvariant` / `VulnerableVaultInvariant` run in default CI.
- Do not add RPC keys, live-network scripts, or unverified tools (medusa is currently broken upstream).
- Run `forge fmt --check` and `forge test` before pushing. Default suite is 32 passed, 3 skipped.
