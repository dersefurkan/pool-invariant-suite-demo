#!/usr/bin/env bash
# Storage-layout drift guard — the first check of an upgrade review.
# Regenerates the layout of each accounting contract, normalizes away
# compilation churn (ast ids, source paths), and fails if a committed
# snapshot moved. Snapshots live in .layouts/ and are reviewed in diffs.
set -euo pipefail
cd "$(dirname "$0")/.."

contracts=(LendingPool ShareVault)
fail=0

for c in "${contracts[@]}"; do
  snap=".layouts/$c.json"
  norm=$(forge inspect "src/$c.sol:$c" storage-layout --json \
    | jq -S '{storage: [.storage[] | {label, slot, offset, type}]}')
  if [[ ! -f "$snap" ]]; then
    echo "MISSING snapshot for $c — run: forge inspect src/$c.sol:$c storage-layout --json | jq -S '{storage: [.storage[] | {label, slot, offset, type}]}' > $snap" >&2
    fail=1
    continue
  fi
  if ! diff <(echo "$norm") "$snap" > /dev/null; then
    echo "LAYOUT DRIFT in $c — review upgrade safety before shipping:" >&2
    diff <(echo "$norm") "$snap" | head -40 >&2
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then
  echo "storage layouts unchanged: ${contracts[*]}"
fi
exit $fail
