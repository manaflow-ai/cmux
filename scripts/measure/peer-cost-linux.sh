#!/usr/bin/env bash
# What one acpmux ssh peer costs, and what 130 of them cost a daemon's first minute (Linux; the "before/after"
# harness for making peers cheap). A release acpmux, then scripts/measure/peer-cost.py against a fake fleet on this
# machine (real sshd on loopback, a far daemon, 130 ssh aliases; the near daemon runs the real dial path). Run at a
# pushed head:
#   cmux-ci test --setup rust -- 'scripts/measure/peer-cost-linux.sh [peers=130] [secs=60] [reps=20] [mode=both] [style=plain|fleet|all]'
#   mode: cold-start | handshake | both. peer-cost-linux.sh build-only: only the release build.
# Prints PEERCOST lines, then {"rows": [...]} as one JSON line. Never run it on a Mac of Leo's.
set -euo pipefail
peers=130 secs=60 reps=20 mode=both style=all build_only=0
for arg in "$@"; do
  case "$arg" in
    peers=*) peers="${arg#peers=}" ;;
    secs=*) secs="${arg#secs=}" ;;
    reps=*) reps="${arg#reps=}" ;;
    mode=*) mode="${arg#mode=}" ;;
    style=*) style="${arg#style=}" ;;
    build-only) build_only=1 ;;
    *) echo "peer-cost-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
command -v cargo >/dev/null || "$root/scripts/install-rust-ci.sh"
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
# sshd: the fake fleet's far side (installed, never started as a service: the harness runs its own, unprivileged).
[[ -x /usr/sbin/sshd ]] || { sudo apt-get update -qq && sudo apt-get install -y -qq openssh-server; }
export PATH="$HOME/.cargo/bin:$PATH"
cd "$root/cmux-tui"
cargo build --locked --release -p acpmux --bin acpmux 2>&1 | tail -n 60
[[ "$build_only" == 1 ]] && exit 0
target="$(cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
cd "$root"
# $FAST_CHECKS_OUT (cmux-ci test --artifact DIR) brings the report back when the run's log cannot be read.
out="${FAST_CHECKS_OUT:-}"; [[ -n "$out" ]] && mkdir -p "$out"
scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/peercost-run.XXXXXX")"
chmod 700 "$scratch_root"
trap 'rm -rf "$scratch_root"' EXIT
set +e
python3 scripts/measure/peer-cost.py "$mode" --acpmux "$target/release/acpmux" --peers "$peers" --secs "$secs" --reps "$reps" --style "$style" \
  --scratch-root "$scratch_root" \
  --keep ${out:+--out "$out/peer-cost.json"} 2>&1 | tee "${out:-/dev/null}${out:+/peer-cost.txt}"
rc=${PIPESTATUS[0]}
# --keep left the scratch directory: its logs say why a run failed (the far side's stderr, ssh's spawn log).
# This is our private root, so collection cannot read or delete another run's files.  Preserve symlinks.
for d in "$scratch_root"/*; do
  [[ -d "$d" ]] || continue
  [[ -n "$out" ]] && mkdir -p "$out/scratch/${d##*/}" && cp -P "$d"/*.err "$d"/ssh.log "$out/scratch/${d##*/}/" 2>/dev/null
done
exit "$rc"
