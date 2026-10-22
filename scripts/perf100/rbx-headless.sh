#!/usr/bin/env bash
# perf100 headless on the Linux Rust builder (rbx): release cmux-tui and acpmux built from this
# checkout, then the tui (S0, S1, S3, S4) and acpmux (S2) scenarios. Linux /proc gives exact
# per-process disk bytes (io write_bytes) and no PTY cap below 1000 terminals.
#
#   $HQ_ROOT/build-fleet/rust-builder/rbx --lane perf100 --cwd . -- bash scripts/perf100/rbx-headless.sh sha=$(git rev-parse HEAD) [seed=1] [quick=1]
# sha= names the measured commit (rbx syncs files, not .git).
#
# Each run JSON is printed as one `PERF100-JSON <name> <json>` line; read them back with
# `perf100.py extract LOG --out DIR`.
set -euo pipefail
seed=1
quick=""
sha=unknown
for arg in "$@"; do
  case "$arg" in
    seed=*) seed="${arg#seed=}" ;;
    quick=1) quick="--quick" ;;
    sha=*) sha="${arg#sha=}" ;;
    *) echo "rbx-headless.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(pwd)"
(cd cmux-tui && cargo build --locked --release -p cmux-tui -p acpmux --bin cmux-tui --bin acpmux)
target="$(cd cmux-tui && cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
echo "PERF100-RBX target=$target"
# State on the root ext4 disk, not rbx's tmpfs TMPDIR (/t): tmpfs writes never reach storage, so
# /proc/pid/io write_bytes would read 0.
out="$(mktemp -d /tmp/p100out.XXXXXX)"
scratch="$(mktemp -d /tmp/p100.XXXXXX)"
trap 'rm -rf "$scratch" "$out"' EXIT
common=(--seed "$seed" --out "$out" --tag "rbx-release" --sha "$sha" --host-class "rbx" --root-dir "$scratch" $quick)
status=0
set +e +o pipefail
python3 scripts/perf100/perf100.py tui --tui "$target/release/cmux-tui" --flood-timeout 1800 "${common[@]}" 2>&1 | tee "$out/tui.log" | grep --line-buffered -E '^perf100:|Traceback|Error'
rc=("${PIPESTATUS[@]}"); [ "${rc[0]}" = 0 ] || status=1
python3 scripts/perf100/perf100.py acpmux --acpmux "$target/release/acpmux" "${common[@]}" 2>&1 | tee "$out/acpmux.log" | grep --line-buffered -E '^perf100:|Traceback|Error'
rc=("${PIPESTATUS[@]}"); [ "${rc[0]}" = 0 ] || status=1
set -e
for f in "$out"/S*.json; do
  [ -e "$f" ] || continue
  printf 'PERF100-JSON %s %s\n' "$(basename "$f")" "$(tr -d '\n' < "$f")"
done
python3 scripts/perf100/perf100.py report "$out"
exit "$status"
