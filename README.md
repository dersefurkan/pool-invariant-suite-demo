# Pool invariant suite

[![ci](https://github.com/dersefurkan32-dotcom/pool-invariant-suite-demo/actions/workflows/ci.yml/badge.svg)](https://github.com/dersefurkan32-dotcom/pool-invariant-suite-demo/actions/workflows/ci.yml)

Local Foundry sample of a handler-based invariant harness for share-accounted pool math.

The protocol here is original teaching code: a lending pool with interest accrual, plus a deliberately broken variant that prices shares off the live token balance. Default CI stays green on the **fixed** pool. The broken variant is opt-in so you can watch the same suite fail.

Not a live exploit. No real protocol was forked.

## Bug class

First-depositor inflation. `LendingPoolVulnerable` prices shares with no virtual offset:

```
shares = deposit_amount * totalShares / asset.balanceOf(this)
```

1. Actor A deposits 1 wei — receives 1 share.
2. Actor A donates 100 tokens with a plain transfer. No shares minted; price per share jumps.
3. Actor B deposits 99 tokens — the math rounds down to **0 shares**.
4. Actor A withdraws the 1 share and takes the donated plus B’s deposit.

## Directed PoC

```bash
forge test --match-contract InflationAttack -vv
```

```
[PASS] test_inflation_attack_drains_vulnerable_pool()
  attacker in : 100.000000000000000001
  attacker out: 199.000000000000000001
  victim shares (99 deposited): 0
```

The same sequence against the fixed pool holds: A recovers 1 wei; B keeps the value of the deposit.

## Invariant suite

`test/invariant/` — a handler drives random deposit / withdraw / round-trip / donate / time-warp sequences (128 runs × 15 calls). Ghost variables track in/out, accrual, and worst round-trip loss. After every call:

| Invariant | Property | Fixed pool | Vulnerable pool |
| --- | --- | --- | --- |
| `solvency_total_claims_backed` | Pool balance covers outstanding share claims, modulo bounded rounding | HOLDS | holds* |
| `attacker_cannot_extract` | No deposit/donate/withdraw sequence nets more than input plus rate-capped yield | HOLDS | **FAILS** |
| `rate_monotonic` | Exchange rate never decreases (modulo rounding) | HOLDS | **FAILS** |
| `accrual_bounded_by_cap` | Interest accrual bounded by the hard rate cap (~10%/yr linear) | HOLDS | holds |
| `round_trip_bounded_loss` | Deposit → full withdraw loses at most 2 wei of rounding dust | HOLDS | **FAILS** |

\*The vulnerable pool is solvent — claims equal the balance. The bug is how the **price** moves. Ledger-only reviews miss this class.

## Watching the suite fail (opt-in)

Gated so default CI stays green:

```bash
DEMO_RUN_KILLED=1 forge test --match-contract VulnerablePoolInvariant -vv
```

The fuzzer finds the inflation sequence and shrinks it. Exact numbers vary with the fuzz seed; the kill does not.

## Fork tests (opt-in)

`test/fork/` runs the **fixed** pool against mainnet WETH and USDC on an Anvil fork — real token semantics — plus a fee-on-transfer case (the pool books what it received, not what the caller asked for).

Skipped in CI. Needs an Ethereum RPC:

```bash
ETH_RPC_URL=https://eth.drpc.org forge test --match-path 'test/fork/**' -vv
```

Any mainnet RPC works. Public `eth.drpc.org` needs no key.

## What a full engagement adds

- Invariants on **your** share math, rate model, distributor, upgrade
- Fork fuzz against **your** deployment, pinned block, your token list
- Each finding as a failing-then-fixed test
- Handler coverage documented so your team can extend the suite

## Run it

```bash
forge test            # local suite: 13 passed, 2 gated suites skipped
forge test -vv
```

Requires [Foundry](https://getfoundry.sh). Default runs are local — no RPC, no keys.

## Scope

Authorized research and teaching. Do not point this suite at systems you do not own or are not contracted to test. See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

---

Contact: dersefurkan32@gmail.com · Telegram [@FURY_Fn](https://t.me/FURY_Fn)
