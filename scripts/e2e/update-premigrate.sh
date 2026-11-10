#!/usr/bin/env bash
# An update of the cmux-tui session daemon from build N to build N+1 that bumps the agent roster
# reducer version, on a registry of millions of journal records (2026-11-09: a nightly's bump made
# the next start re-fold 12.2M records). Runs cmux-tui's ignored test
# tests/update_premigrate_e2e.rs, which asserts that the update repairs itself: the old owner
# keeps serving while the new build premigrates the roster, `server ensure` never replaces the
# restoring owner, an action held during the start replays once, and the roster catches up.
#   cmux-ci test --timeout 10800 --artifact DIR -- bash scripts/e2e/update-premigrate.sh
# Build N is this tree. Build N+1 is the same tree with AGENT_ROSTER_REDUCER_VERSION bumped by
# one in journal_reducers.rs, restored when the build ends. Linux only.
# Environment: CMUX_E2E_RECORDS (default 3000000), CMUX_E2E_DIR (default a temp dir), and the
# test's other CMUX_E2E_* knobs. The test's summary line (E2E-RESULT ...) goes to stdout and,
# when FAST_CHECKS_OUT is set, to $FAST_CHECKS_OUT/update-premigrate.txt.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
# ghostty-vt-sys builds libghostty-vt from the ghostty-next submodule (as cmux-tui-rust-check.sh).
if [[ ! -f "$root/ghostty-next/build.zig" ]]; then
  git -C "$root" submodule update --init --depth 1 ghostty-next
fi
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/.build/cmux-tui-rust-target}"
cd "$root/cmux-tui"
reducer=crates/cmux-tui-core/src/journal_reducers.rs
pattern='^pub(crate) const AGENT_ROSTER_REDUCER_VERSION: u32 = \([0-9][0-9]*\);$'
old_version="$(sed -n "s/$pattern/\\1/p" "$reducer")"
if [[ -z "$old_version" ]]; then
  echo "error: no AGENT_ROSTER_REDUCER_VERSION in $reducer" >&2
  exit 2
fi
new_version=$((old_version + 1))
# The registry is GBs: on disk, not /tmp (Linux /tmp can be RAM). Sockets stay below /tmp.
work="${CMUX_E2E_WORK:-$HOME/.cache/cmux-update-premigrate/run-$$}"
mkdir -p "$work"
# On any exit: build N's reducer file back, and this run's binaries and registries gone.
cleanup() {
  if [[ -f "$work/journal_reducers.rs.n" ]]; then
    cp "$work/journal_reducers.rs.n" "$reducer"
  fi
  if [[ -z "${CMUX_E2E_WORK:-}" ]]; then
    rm -rf "$work"
  fi
}
trap cleanup EXIT
export CMUX_E2E_DIR="${CMUX_E2E_DIR:-$work/sites}"
# Generated registries are kept between runs on this host, keyed by the generator (the test's
# CMUX_E2E_CACHE); CMUX_E2E_CACHE= turns it off.
export CMUX_E2E_CACHE="${CMUX_E2E_CACHE-$HOME/.cache/cmux-update-premigrate/templates}"
mkdir -p "$CMUX_E2E_DIR"
free_gb=$(( $(df -Pk "$CMUX_E2E_DIR" | awk 'NR==2 {print $4}') / 1048576 ))
echo "update-premigrate: host $(hostname -s) $(uname -sm), $free_gb GB free at $CMUX_E2E_DIR" >&2

# The executable a cargo build or test build made, from its JSON messages.
executable() {
  local kind="$1"
  grep '"reason":"compiler-artifact"' | grep "\"kind\":\[\"$kind\"\]" |
    sed -n 's/.*"executable":"\([^"]*\)".*/\1/p' | tail -n 1
}

echo "update-premigrate: build N (roster reducer $old_version) and the test" >&2
cargo build --locked --release -p cmux-tui --bin cmux-tui \
  --message-format=json-render-diagnostics >"$work/build-n.json"
old_bin="$(executable bin <"$work/build-n.json")"
cp "$old_bin" "$work/cmux-tui-n"
cargo test --locked --release -p cmux-tui --test update_premigrate_e2e --no-run \
  --message-format=json-render-diagnostics >"$work/build-test.json"
test_bin="$(executable test <"$work/build-test.json")"
cp "$test_bin" "$work/update-premigrate-e2e"

echo "update-premigrate: build N+1 (roster reducer $new_version)" >&2
cp "$reducer" "$work/journal_reducers.rs.n"
sed -i "s/$pattern/pub(crate) const AGENT_ROSTER_REDUCER_VERSION: u32 = $new_version;/" "$reducer"
# A bump that changed nothing would test an update to the same reducer: refuse it.
if cmp -s "$reducer" "$work/journal_reducers.rs.n" ||
  [[ "$(sed -n "s/$pattern/\\1/p" "$reducer")" != "$new_version" ]]; then
  echo "error: the reducer bump $old_version -> $new_version changed nothing in $reducer" >&2
  exit 3
fi
cargo build --locked --release -p cmux-tui --bin cmux-tui \
  --message-format=json-render-diagnostics >"$work/build-n1.json"
new_bin="$(executable bin <"$work/build-n1.json")"
cp "$new_bin" "$work/cmux-tui-n1"
mv "$work/journal_reducers.rs.n" "$reducer"

result="$work/e2e-result.txt"
rm -f "$result"
echo "update-premigrate: records ${CMUX_E2E_RECORDS:-3000000}, sites in $CMUX_E2E_DIR" >&2
CMUX_E2E_OLD_BIN="$work/cmux-tui-n" CMUX_E2E_NEW_BIN="$work/cmux-tui-n1" \
  CMUX_E2E_NEW_VERSION="$new_version" CMUX_E2E_RESULT_FILE="$result" \
  "$work/update-premigrate-e2e" --ignored --nocapture --test-threads=1 \
  an_update_that_bumps_the_roster_reducer_repairs_itself
if [[ -n "${FAST_CHECKS_OUT:-}" ]]; then
  mkdir -p "$FAST_CHECKS_OUT"
  cp "$result" "$FAST_CHECKS_OUT/update-premigrate.txt"
fi
cat "$result"
