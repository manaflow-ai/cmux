#!/usr/bin/env bash
# clippy-changed fold A/B: what the panic ratchet's HEAD lint costs after the clippy step, with this tree's
# .github/scripts/cmux-tui-clippy-changed.py (the clippy step lints with the ratchet's flags, so the ratchet's
# `--lib --bins` units are fresh) against BASE's copy (it does not), on one machine and one target dir.
# Each arm touches the same file, so both relint the same crates; arms alternate after a warm-up.
# Prints per arm: the ratchet step's seconds, its HEAD cargo run's time, and how many workspace crates that run
# relinted. Run (fleet, warm cargo slot):
#   cmux-ci run --class light --script scripts/measure/clippy-changed-fold.sh --arg=BASE --ref SHA --measurement --timeout 7200
# TOUCH="crate/src/file.rs ..." picks the files (default: cmux-tui-core, a mid-graph crate, and cmux-json, a leaf).
set -uo pipefail
base=${1:?usage: clippy-changed-fold.sh BASE}
cd "$(git rev-parse --show-toplevel)"
out=$(mktemp -d)
for f in cmux-tui-clippy-changed.py test_cmux_tui_clippy_changed.py; do git show "HEAD:.github/scripts/$f" > "$out/after-$f"; done
arm() {  # NAME TOUCH_FILE
  local name=$1 file=$2 log="$out/$1-$(basename "$(dirname "$(dirname "$2")")").log"
  for f in cmux-tui-clippy-changed.py test_cmux_tui_clippy_changed.py; do cp "$out/$name-$f" ".github/scripts/$f"; done
  touch "$file"
  bash scripts/ci/feat-parity-check.sh clippy-changed "$base" > "$log" 2>&1
  local start head ws secs
  start=$(grep -n "^=== step Rust panic ratchet" "$log" | head -1 | cut -d: -f1)
  head=$(awk -v s="${start:-0}" 'NR>s && /Finished `dev`/ {print NR": "$0; exit}' "$log")
  ws=$(sed -n "${start:-1},${head%%:*}p" "$log" | grep -cE '^ +(Checking|Compiling) .*\(/')
  secs=$(grep -E '^Rust panic ratchet on changed.* [0-9]+$' "$log" | awk '{print $NF}')
  printf '%-7s %-22s ratchet_step_s=%s head_run=%s head_ws_relinted=%s clippy_step_s=%s\n' "$name" "$(basename "$(dirname "$(dirname "$file")")")" \
    "$secs" "$(echo "$head" | grep -o 'in .*')" "$ws" "$(grep -E '^cargo clippy --all-targets.* [0-9]+$' "$log" | awk '{print $NF}')"
}
read -r -a files <<<"${TOUCH:-cmux-tui/crates/cmux-tui-core/src/lib.rs cmux-tui/crates/cmux-json/src/lib.rs}"
arm after "${files[0]}" > /dev/null  # warm-up (it also fetches BASE): both arms then start from one fresh target
for f in cmux-tui-clippy-changed.py test_cmux_tui_clippy_changed.py; do
  git show "$base:.github/scripts/$f" > "$out/before-$f" || { echo "BASE $base is not in this checkout" >&2; exit 3; }
done
echo "warm-up done"
for file in "${files[@]}"; do arm before "$file"; arm after "$file"; done
git checkout -q -- .github/scripts
