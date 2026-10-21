#!/usr/bin/env bash
# perf100 headless on the Linux Rust builder (rbx): release cmux-tui and acpmux built from this
# checkout, then the tui (S0, S1, S3, S4) and acpmux (S2) scenarios. Linux /proc gives exact
# per-process disk bytes (io write_bytes) and no PTY cap below 1000 terminals.
#
#   $HQ_ROOT/build-fleet/rust-builder/rbx --lane perf100 --cwd . -- bash scripts/perf100/rbx-headless.sh [seed=1] [quick=1]
#
# Each run JSON is printed as one `PERF100-JSON <name> <json>` line; read them back with
# `perf100.py extract LOG --out DIR`.
set -euo pipefail
seed=1
quick=""
for arg in "$@"; do
  case "$arg" in
    seed=*) seed="${arg#seed=}" ;;
    quick=1) quick="--quick" ;;
    *) echo "rbx-headless.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(pwd)"
target="${CARGO_TARGET_DIR:-$root/cmux-tui/target}"
(cd cmux-tui && cargo build --locked --release -p cmux-tui -p acpmux --bin cmux-tui --bin acpmux)
out="$(mktemp -d /tmp/p100out.XXXXXX)"
scratch="$(mktemp -d /tmp/p100.XXXXXX)"
trap 'rm -rf "$scratch" "$out"' EXIT
sha="$(git rev-parse HEAD 2>/dev/null || echo "${PERF100_SHA:-unknown}")"
common=(--seed "$seed" --out "$out" --tag "rbx-release" --sha "${PERF100_SHA:-$sha}" --host-class "rbx" --root-dir "$scratch" $quick)
status=0
python3 scripts/perf100/perf100.py tui --tui "$target/release/cmux-tui" "${common[@]}" > "$out/tui.log" 2>&1 || status=$?
tail -n 3 "$out/tui.log"
python3 scripts/perf100/perf100.py acpmux --acpmux "$target/release/acpmux" "${common[@]}" > "$out/acpmux.log" 2>&1 || status=$?
tail -n 3 "$out/acpmux.log"
for f in "$out"/S*.json; do
  [ -e "$f" ] || continue
  printf 'PERF100-JSON %s %s\n' "$(basename "$f")" "$(tr -d '\n' < "$f")"
done
python3 scripts/perf100/perf100.py report "$out"
exit "$status"
