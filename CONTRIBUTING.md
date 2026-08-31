# Contributing

Keep the teaching story intact: one inflation PoC, one fixed pool, green invariants on the fixed code, opt-in red run on the vulnerable variant.

```bash
forge fmt
forge test -vv
```

- Do not delete `test_inflation_attack_drains_vulnerable_pool`.
- Do not make `VulnerablePoolInvariant` run in default CI.
- Do not add RPC keys or live-network scripts.
- Run `forge fmt --check` and `forge test` before pushing.
