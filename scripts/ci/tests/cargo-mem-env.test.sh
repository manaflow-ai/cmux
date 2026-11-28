#!/usr/bin/env bash
# cargo-mem-env.sh: capped by memory, a single cargo build gets the jobs cap and the giant lock, so the acpmux and
# cmux_tui rustc never compile at once (relay journey run 46172359390: both SIGKILLed at -j2 in a 14 GiB slot).
# A fake cgroup tree, getconf and rustc stand in.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_sh="$here/../cargo-mem-env.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/cg/slot"
printf '#!/bin/sh\necho 8\n' > "$tmp/bin/getconf"; chmod +x "$tmp/bin/getconf"
echo "0::/slot" > "$tmp/proc-cgroup"
echo max > "$tmp/cg/memory.max"
echo $((14 * 1073741824)) > "$tmp/cg/slot/memory.max"
export PATH="$tmp/bin:$PATH" CARGO_GROUPS_CGROUP_ROOT="$tmp/cg" CARGO_GROUPS_PROC_CGROUP="$tmp/proc-cgroup" RUNNER_TEMP="$tmp"
unset CARGO_BUILD_JOBS RUSTC_WRAPPER CARGO_GROUPS_GIANTS CARGO_GROUPS_GIANT_LOCK CARGO_GROUPS_NO_GIANT_LOCK || true
fail() { echo "FAIL: $*"; exit 1; }

# 1. A 14 GiB cmux-linux slot: -j2 and the lock.
out=$(source "$env_sh" >/dev/null; echo "$CARGO_BUILD_JOBS|${RUSTC_WRAPPER:-}|${CARGO_GROUPS_GIANTS:-}")
[[ "$out" == "2|$here/../cargo-giant-lock.sh|acpmux cmux_tui cmux_tui_core" || "$out" == "2|$(cd "$here/.." && pwd)/cargo-giant-lock.sh|acpmux cmux_tui cmux_tui_core" ]] || fail "capped slot: $out"

# 2. The lock serializes two giants: fake rustc records start/end; acpmux and cmux_tui must not overlap.
cat > "$tmp/bin/fake-rustc" <<'R'
#!/bin/sh
for a; do [ "$p" = --crate-name ] && c=$a; p=$a; done
echo "start $c" >> "$LOG"; sleep 1; echo "end $c" >> "$LOG"
R
chmod +x "$tmp/bin/fake-rustc"
export LOG="$tmp/log"; : > "$LOG"
(
  source "$env_sh" >/dev/null
  "$RUSTC_WRAPPER" fake-rustc --crate-name acpmux & "$RUSTC_WRAPPER" fake-rustc --crate-name cmux_tui & wait
)
order=$(tr '\n' ' ' < "$LOG")
[[ "$order" == "start acpmux end acpmux start cmux_tui end cmux_tui " || "$order" == "start cmux_tui end cmux_tui start acpmux end acpmux " ]] || fail "giants overlapped: $order"
# A small crate does not wait.
: > "$LOG"
( source "$env_sh" >/dev/null; "$RUSTC_WRAPPER" fake-rustc --crate-name acpmux & sleep 0.2; "$RUSTC_WRAPPER" fake-rustc --crate-name serde & wait )
[[ "$(sed -n 2p "$LOG")" == "start serde" ]] || fail "small crate waited: $(tr '\n' ' ' < "$LOG")"

# 3. Memory to spare: no cap, no lock.
echo max > "$tmp/cg/slot/memory.max"
out=$(source "$env_sh" >/dev/null; echo "${CARGO_BUILD_JOBS:-unset}|${RUSTC_WRAPPER:-}")
[[ "$out" == "unset|" ]] || fail "uncapped: $out"

# 4. A caller's CARGO_BUILD_JOBS wins and adds no lock; CARGO_GROUPS_NO_GIANT_LOCK keeps the cap only.
echo $((14 * 1073741824)) > "$tmp/cg/slot/memory.max"
out=$(CARGO_BUILD_JOBS=5; source "$env_sh" >/dev/null; echo "$CARGO_BUILD_JOBS|${RUSTC_WRAPPER:-}")
[[ "$out" == "5|" ]] || fail "caller: $out"
out=$(CARGO_GROUPS_NO_GIANT_LOCK=1; source "$env_sh" >/dev/null; echo "$CARGO_BUILD_JOBS|${RUSTC_WRAPPER:-}")
[[ "$out" == "2|" ]] || fail "no lock: $out"

# 5. A caller's RUSTC_WRAPPER still runs, inside the lock.
printf '#!/bin/sh\necho inner >> "$LOG"\nexec "$@"\n' > "$tmp/bin/inner"; chmod +x "$tmp/bin/inner"
: > "$LOG"
( RUSTC_WRAPPER="$tmp/bin/inner"; source "$env_sh" >/dev/null; "$RUSTC_WRAPPER" fake-rustc --crate-name acpmux )
[[ "$(head -1 "$LOG")" == inner ]] || fail "inner wrapper: $(tr '\n' ' ' < "$LOG")"
echo "cargo-mem-env: ok"
