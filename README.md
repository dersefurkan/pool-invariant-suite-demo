# Pool invariant suite

[![ci](https://github.com/dersefurkan/pool-invariant-suite-demo/actions/workflows/ci.yml/badge.svg)](https://github.com/dersefurkan/pool-invariant-suite-demo/actions/workflows/ci.yml)

Local Foundry sample of a handler-based invariant harness for share-accounted pool math.

The protocols here are original teaching code, each shipped in a hardened and a deliberately broken variant:

- **`LendingPool`** — a lending pool with interest accrual. The broken variant prices shares off the live token balance (first-depositor inflation).
- **`ShareVault`** — a yield vault with a performance fee. The broken variant charges the fee on the whole ledger, not the gain (fee creep).

Default CI stays green on the **fixed** contracts. The broken variants are opt-in so you can watch the same suites fail.

Not a live exploit. No real protocol was forked.

## Bug class 1 — first-depositor inflation

`LendingPoolVulnerable` prices shares with no virtual offset:

```
shares = deposit_amount * totalShares / asset.balanceOf(this)
```

1. Actor A deposits 1 wei — receives 1 share.
2. Actor A donates 100 tokens with a plain transfer. No shares minted; price per share jumps.
3. Actor B deposits 99 tokens — the math rounds down to **0 shares**.
4. Actor A withdraws the 1 share and takes the donated plus B’s deposit.

```bash
forge test --match-contract InflationAttack -vv
```

```
[PASS] test_inflation_attack_drains_vulnerable_pool()
  attacker in : 100.000000000000000001
  attacker out: 199.000000000000000001
  victim shares (99 deposited): 0
```

## Bug class 2 — fee creep

`ShareVaultVulnerable.harvest()` takes its performance fee on the **whole ledger**, not the funded gain:

```
fee = totalAssets * feeBps / 10_000   // should be: funded_gain * feeBps / 10_000
```

Every harvest — even one that funds zero yield — mints treasury shares against depositors' principal. Twenty routine keeper ticks at a 10% fee bleed a depositor to ~12% of their principal. The vault stays solvent the whole time: claims equal the balance. The value moves through the **price**, which is why ledger-only reviews miss the class.

```bash
forge test --match-contract PrincipalFeeCreep -vv
```

```
[PASS] test_fee_creep_drains_vulnerable_vault()
  alice in       : 100.000000000000000000
  alice out      : 14.864362802414368641  (20 no-yield harvests)
  treasury claim : 85.135637197585631359  (the difference, as shares)
```

The same sequences against the fixed contracts hold: A recovers 1 wei; B keeps the value of the deposit; a dry cron changes nothing.

## Invariant suites

`test/invariant/` — handlers drive random deposit / withdraw / round-trip / donate / harvest / time-warp sequences (128 runs × 15 calls). Ghost variables track in/out, accrual, fee mints, and worst round-trip loss.

A note on rounding honesty: floor rounding makes the contract keep dust, so a user operation loses less than one unit of share **price** — with a +1 wei virtual offset that granularity is `(totalAssets + 1)/(totalShares + 1)` wei, not a flat constant. The dust bounds below are rate-relative; the handlers track the per-call budget exactly.

Pool suite, after every call:

| Invariant | Property | Fixed pool | Vulnerable pool |
| --- | --- | --- | --- |
| `solvency_total_claims_backed` | Pool balance covers outstanding share claims, modulo bounded rounding | HOLDS | holds* |
| `attacker_cannot_extract` | No deposit/donate/withdraw sequence nets more than input plus rate-capped yield | HOLDS | **FAILS** |
| `rate_monotonic` | Exchange rate never decreases (modulo rounding) | HOLDS | **FAILS** |
| `accrual_bounded_by_cap` | Interest accrual bounded by the hard rate cap (~10%/yr linear) | HOLDS | holds |
| `round_trip_bounded_loss` | Deposit → full withdraw loses less than two units of share price | HOLDS | holds† |

\*The vulnerable pool is solvent — claims equal the balance. The bug is how the **price** moves.
†Deposits that would mint zero shares revert, so the fuzzer cannot complete the poisoned round trip; the extraction shows up in `attacker_cannot_extract`.

Vault suite, after every call:

| Invariant | Property | Fixed vault | Vulnerable vault |
| --- | --- | --- | --- |
| `solvency_total_claims_backed` | Vault balance covers outstanding share claims | HOLDS | holds* |
| `fees_bounded_by_yield` | Treasury fee mints never exceed `feeBps` of funded gain (exact per-harvest valuation) | HOLDS | **FAILS** |
| `crowd_principal_backed` | Crowd's claim plus withdrawals cover deposits, modulo the tracked dust budget | HOLDS | **FAILS** |
| `rate_monotonic` | Share price never decreases on a harvest (fee ≤ gain) | HOLDS | **FAILS** |
| `round_trip_bounded_loss` | Deposit → full withdraw loses less than one unit of share price | HOLDS | holds |

## Watching the suites fail (opt-in)

Gated so default CI stays green:

```bash
DEMO_RUN_KILLED=1 forge test --match-contract 'VulnerablePoolInvariant|VulnerableVaultInvariant' -vv
```

The fuzzer finds each attack sequence and shrinks it. Exact numbers vary with the fuzz seed; the kills do not.

## Cross-engine verification

The same hardened contracts are checked by independent engines — an invariant is only trusted once more than one engine agrees:

| Tool | Mode | What it covers | Command |
| --- | --- | --- | --- |
| Foundry | unit + fuzz + handler invariants | both suites above | `forge test` |
| echidna | property fuzzing (20k calls) | solvency, fee bound, principal | `echidna test/echidna/PoolProperties.sol --contract PoolProperties --config echidna.yaml` |
| halmos | symbolic execution | deposit totals, exact gain booking, donation neutrality | `halmos --match-contract ShareVaultSymbolic` |
| slither | static analysis (CI, non-blocking) | whole repo | `slither . --fail-none` |

Symbolic checks are deliberately linear: division-heavy share pricing is where SMT solvers time out, and those properties are already covered by the fuzz lanes.

## Storage-layout drift guard

`script/check-layout.sh` regenerates the storage layout of each accounting contract and fails on any drift against the committed snapshots in `.layouts/` — the first check of an upgrade review. Runs in CI.

## Fork tests (opt-in)

`test/fork/` runs the **fixed** pool against mainnet WETH and USDC on an Anvil fork — real token semantics — plus a fee-on-transfer case (the pool books what it received, not what the caller asked for).

Skipped in CI. Needs an Ethereum RPC:

```bash
ETH_RPC_URL=https://eth.drpc.org forge test --match-path 'test/fork/**' -vv
```

Any mainnet RPC works. Public `eth.drpc.org` needs no key.

## What a full engagement adds

- Invariants on **your** share math, rate model, fee accounting, distributor, upgrade
- Fork fuzz against **your** deployment, pinned block, your token list
- Symbolic checks where the math is linear enough to prove, fuzz where it is not
- Storage-layout drift guards across your upgrade diff
- Each finding as a failing-then-fixed test
- Handler coverage documented so your team can extend the suite

## Run it

```bash
forge test            # local suite: 32 passed; fork + 2 gated killed suites skipped
forge test -vv
```

Requires [Foundry](https://getfoundry.sh). Default runs are local — no RPC, no keys. echidna / halmos / slither runs are opt-in and need those tools installed.

## Scope

Authorized research and teaching. Do not point this suite at systems you do not own or are not contracted to test. See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

---

Contact: dersefurkan32@gmail.com · Telegram [@FURY_Fn](https://t.me/FURY_Fn)
