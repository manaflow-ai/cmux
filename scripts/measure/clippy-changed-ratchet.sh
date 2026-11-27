#!/usr/bin/env bash
# The clippy-changed check's two cargo sub-steps (cargo clippy --all-targets, then the Rust panic ratchet), seconds
# each, for this checkout's cmux-tui-clippy-changed.py against OLD's, on one warm target: the same harness for the
# before and after of a change to that script (lane/clippy-ratchet-one-pass: the ratchet re-checked 155 of the 160
# crates the clippy step had just checked, because the two runs passed clippy different arguments).
#   cmux-ci test --timeout 10800 -- bash -c 'scripts/measure/clippy-changed-ratchet.sh BASE OLD; echo rc=$?'
# BASE is the base the check diffs against (pick one whose diff reaches a cmux-tui crate); OLD is the commit whose
# script is "before". Each run first touches the .rs files the diff changed, as a new commit would, and runs
# scripts/ci/feat-parity-check.sh clippy-changed BASE. Per side: one warm-up run (the target then holds what that
# side leaves), then two measured runs; then the same under load (one busy loop per core, LOAD=0 skips it).
# Prints "RUN tag (side) rc wall checking load" and the summary rows for each run; full logs in clippy-bench/.
set -uo pipefail
base="${1:?usage: clippy-changed-ratchet.sh BASE OLD}"
old="${2:?usage: clippy-changed-ratchet.sh BASE OLD}"
s=.github/scripts
out=clippy-bench
mkdir -p "$out/new"
cp "$s/cmux-tui-clippy-changed.py" "$s/test_cmux_tui_clippy_changed.py" "$out/new/"
side() {
  if [[ "$1" == old ]]; then
    git show "$old:$s/cmux-tui-clippy-changed.py" >"$s/cmux-tui-clippy-changed.py"
    git show "$old:$s/test_cmux_tui_clippy_changed.py" >"$s/test_cmux_tui_clippy_changed.py"
  else
    cp "$out/new/cmux-tui-clippy-changed.py" "$out/new/test_cmux_tui_clippy_changed.py" "$s/"
  fi
}
run() {
  local tag="$1" which="$2" t0=$SECONDS rc=0
  side "$which" || return
  git diff --name-only "$base" HEAD -- 'cmux-tui/*.rs' | xargs -r touch
  scripts/ci/feat-parity-check.sh clippy-changed "$base" >"$out/$tag.log" 2>&1 || rc=$?
  echo "RUN $tag ($which) rc=$rc wall=$((SECONDS - t0))s checking=$(grep -c '^ *Checking ' "$out/$tag.log")" \
    "load=$(cut -d' ' -f1 /proc/loadavg)"
  grep -E '^(cargo clippy --all-targets|Rust panic ratchet) .*[0-9]+$' "$out/$tag.log" | sed "s/^/  /"
  grep -E 'Finished .* in |is not linted|over the baseline' "$out/$tag.log" | cut -c1-200 | sed "s/^/  /"
}
echo "nproc=$(nproc) mem=$(free -g | awk '/Mem/{print $2}')G base=$base old=$old"
# The first run fetches BASE (a pool checkout is one commit deep), so OLD's script is readable after it.
run warm-new new
for which in old new; do run "warm-$which" "$which"; run "$which-1" "$which"; run "$which-2" "$which"; done
if [[ "${LOAD:-1}" != 0 ]]; then
  busy=()
  for _ in $(seq "$(nproc)"); do (while :; do :; done) & busy+=($!); done
  for which in old new; do run "load-warm-$which" "$which"; run "load-$which" "$which"; done
  kill "${busy[@]}" 2>/dev/null
fi
side new
