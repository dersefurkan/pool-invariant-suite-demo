# pool-invariant-suite-demo

[![test](https://github.com/dersefurkan32-dotcom/pool-invariant-suite-demo/actions/workflows/ci.yml/badge.svg)](https://github.com/dersefurkan32-dotcom/pool-invariant-suite-demo/actions/workflows/ci.yml)

**Your vault's invariants shouldn't be a bullet point in a slide deck. They should be a Foundry suite that runs in CI and kills bugs before your users find them.**

This repo is the public sample of what an engagement delivers: a handler-based
invariant harness plus fork tests for one synthetic but realistic protocol — a
share-accounted lending pool with interest accrual — and one deliberately
vulnerable variant that the suite catches and kills.

Everything here is original code written for demonstration. No real protocol
was forked, renamed, or harmed.

## The bug class

First-depositor inflation. `LendingPoolVulnerable` prices shares off the
**live token balance** with no virtual offset:

```
shares = deposit_amount * totalShares / asset.balanceOf(this)
```

The sequence is a classic:

1. Attacker deposits 1 wei — gets 1 share.
2. Attacker **donates** 100 tokens with a plain transfer. No shares minted,
   but the price per share just moved 100×.
3. Victim deposits 99 tokens — the math rounds down to **0 shares**.
4. Attacker withdraws their 1 share and takes everything.

## The attack (30 seconds)

```bash
forge test --match-contract InflationAttack -vv
```

```
[PASS] test_inflation_attack_drains_vulnerable_pool()
  attacker in : 100.000000000000000001
  attacker out: 199.000000000000000001
  victim shares (99 deposited): 0
```

The fixed pool gets the exact same sequence and holds: the attacker recovers
their 1 wei, the victim keeps the full value of their deposit.

## The invariant suite

`test/invariant/` — a handler drives random deposit / withdraw / round-trip /
attacker-deposit / donate / time-warp sequences (128 runs × 15 calls) while
ghost variables track the attacker's in/out, per-accrual gains, and the worst
round-trip loss. Five invariants are checked after every call:

| Invariant | Property | Fixed pool | Vulnerable pool |
|---|---|---|---|
| `solvency_total_claims_backed` | Pool balance covers every outstanding share claim, modulo bounded rounding | HOLDS | holds* |
| `attacker_cannot_extract` | No deposit/donate/withdraw sequence nets the attacker more than they put in, plus their rate-capped share of yield | HOLDS | **FAILS** |
| `rate_monotonic` | Exchange rate never decreases (modulo rounding) | HOLDS | **FAILS** |
| `accrual_bounded_by_cap` | Every interest accrual is bounded by the hard rate cap (~10%/yr linear) | HOLDS | holds |
| `round_trip_bounded_loss` | Deposit → full withdraw loses at most 2 wei of rounding dust | HOLDS | **FAILS** |

*The vulnerable pool's accounting is solvent — claims equal the balance. The
bug is not *what* it tracks, it is *how the price moves*. That is exactly why
this class slips through reviews that only check the ledger.

## The killed bug: watch the suite go red

The same harness, dropped on `LendingPoolVulnerable`. The run is gated behind
an env flag so default CI stays green on the fixed code:

```bash
DEMO_RUN_KILLED=1 forge test --match-contract VulnerablePoolInvariant -vv
```

The fuzzer finds the inflation sweep on its own and shrinks it to four calls:

```
[FAIL: assertion failed: 8775453558271167127 > 8750059077868022922]
	[Sequence] (original: 7, shrunk: 4)
		calldata=attackerDonate(uint96) args=[8750059077868022841 [8.75e18]]
		calldata=attackerDeposit(uint96) args=[79]
		calldata=deposit(uint96) args=[3121464160768331438581 [3.121e21]]
		calldata=attackerWithdrawAll() args=[]
 invariant_attacker_cannot_extract()
```

Donate, deposit dust for the first shares, let a victim deposit into the
inflated price, withdraw all. The assertion is the attacker's ghost
accounting: `attackerOut > attackerIn + yieldBound + slack`.
`Suite result: FAILED. 2 passed; 3 failed` — the suite kills it three ways.
(Exact numbers vary with the fuzz seed; the kill does not.)

## Fork tests against Ethereum mainnet state

`test/fork/` runs the pool against real mainnet **WETH and USDC** on an anvil
fork — real token semantics, no friendly mocks — plus a fee-on-transfer token
case proving the pool books what it *received*, not what the caller asked for.

Fork tests are network-dependent and opt-in. They skip silently in CI; run
them manually or on a nightly schedule:

```bash
ETH_RPC_URL=https://eth.drpc.org forge test --match-path 'test/fork/**' -vv
```

Any Ethereum mainnet RPC works; `https://eth.drpc.org` is a public endpoint
that needs no key. Verified green against live mainnet state:

```
[PASS] test_fork_weth_round_trip()
[PASS] test_fork_usdc_round_trip()
[PASS] test_fork_weth_yield_accrual()
[PASS] test_fork_fee_on_transfer_accounting()
```

## What a real engagement adds on top of this sample

- Invariants written against **your** pool: your share math, your rate model,
  your reward distributor, your upgrade — not a synthetic stand-in
- Fork fuzzing against your **live deployment** with pinned block numbers and
  your real token list, run nightly against your RPC
- A **red-then-green** delivery for every finding: the failing invariant is
  the report; the fix PR makes the same suite pass
- Handler coverage reviews: which calls, which actors, which ghost variables —
  documented so your team can extend the suite after I leave

## Run it

```bash
forge test            # full local suite: 13 passed, 2 gated suites skipped
forge test -vv        # with attack traces
```

Requires [Foundry](https://getfoundry.sh). Default runs are fully local —
no RPC, no keys. Fork tests and the killed-bug run are opt-in (see above).

---

*Pre-ship invariant suites and fork fuzzing for lending pools and vaults.
7 days, you keep the tests. Contact: Telegram [@FURY_Fn](https://t.me/FURY_Fn) ·
dersefurkan32@gmail.com*
