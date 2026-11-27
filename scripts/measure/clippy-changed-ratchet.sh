#!/usr/bin/env bash
# The clippy-changed check's two cargo sub-steps, seconds each: `cargo clippy --all-targets on changed cmux-tui
# packages` and `Rust panic ratchet on changed cmux-tui packages` (scripts/ci/feat-parity-check.sh clippy-changed,
# the same commands and environment), for this checkout's cmux-tui-clippy-changed.py against OLD's, on one warm
# target: the same harness for the before and after of a change to that script (lane/clippy-ratchet-one-pass: the
# ratchet re-checked 155 of the 160 crates the clippy step had just checked, as the two passed clippy different
# arguments).
#   cmux-ci test --setup rust --timeout 10800 -- bash -c 'scripts/measure/clippy-changed-ratchet.sh BASE OLD; echo rc=$?'
# BASE (40 hex) is the base the check diffs against: pick one whose diff reaches a cmux-tui crate. OLD (40 hex) is
# the commit whose script is "before". Both are fetched when the checkout lacks them (a pool checkout is one commit
# deep). Each run first touches the .rs files the diff changed, as a new commit would. Per side: one warm-up run (the
# target then holds what that side leaves), then RUNS measured runs (default 2); then one warm-up and one measured
# run per side under load (one busy loop per core; LOAD=0 skips it). Prints one "RUN" line per run.
set -uo pipefail
base="${1:?usage: clippy-changed-ratchet.sh BASE OLD}"
old="${2:?usage: clippy-changed-ratchet.sh BASE OLD}"
root="$(git rev-parse --show-toplevel)"
cd "$root" || exit 2
s=.github/scripts
out="$root/.build/clippy-bench"
mkdir -p "$out/new"
remote="$(git remote get-url origin 2>/dev/null || true)"
if [[ -z "$remote" ]]; then
  remote="${CMUX_CI_STEP_GIT_BASE:-https://github.com}"
  [[ "$remote" == */cmux || "$remote" == */cmux.git ]] || remote="${remote%/}/manaflow-ai/cmux.git"
fi
for sha in "$base" "$old"; do
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch --no-recurse-submodules -q --depth=1 "$remote" "$sha" || { echo "cannot fetch $sha" >&2; exit 2; }
done
git cat-file -e "$base^{commit}" && git cat-file -e "$old^{commit}" || exit 2
(git submodule status ghostty-next >/dev/null 2>&1 && [[ ! -f ghostty-next/build.zig ]]) && bash scripts/ci/init-submodule.sh ghostty-next
export GHOSTTY_ZIG_SOURCE=ghostty-next CMUX_GHOSTTY_SRC="" CMUX_GHOSTTY_VT_ZIG_CPU=baseline CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/.build/cmux-tui-clippy-target}"
cp "$s/cmux-tui-clippy-changed.py" "$s/cmux-tui-fmt-changed.py" "$out/new/"
git show "$old:$s/cmux-tui-clippy-changed.py" >"$out/old.py" || exit 2
mkdir -p "$out/old" && cp "$out/old.py" "$out/old/cmux-tui-clippy-changed.py" && git show "$old:$s/cmux-tui-fmt-changed.py" >"$out/old/cmux-tui-fmt-changed.py"
changed=$(git diff --name-only "$base" HEAD -- 'cmux-tui/*.rs')
echo "nproc=$(nproc) mem=$(free -g | awk '/Mem/{print $2}')G base=$base old=$old changed=$(wc -w <<<"$changed") .rs"
run() {
  local tag="$1" which="$2" t0 t1 t2 rc1=0 rc2=0
  # shellcheck disable=SC2086
  [[ -n "$changed" ]] && touch $changed
  t0=$SECONDS
  python3 "$out/$which/cmux-tui-clippy-changed.py" --repo "$root" --base "$base" >"$out/$tag.clippy.log" 2>&1 || rc1=$?
  t1=$SECONDS
  python3 "$out/$which/cmux-tui-clippy-changed.py" --repo "$root" --base "$base" \
    --panic-ratchet "$root/.build/panic-clippy.jsonl" --compare-base >"$out/$tag.ratchet.log" 2>&1 || rc2=$?
  t2=$SECONDS
  echo "RUN $tag ($which) clippy=$((t1 - t0))s rc=$rc1 checked=$(grep -c '^ *Checking ' "$out/$tag.clippy.log")" \
    "ratchet=$((t2 - t1))s rc=$rc2 checked=$(grep -c '^ *Checking ' "$out/$tag.ratchet.log") load=$(cut -d' ' -f1 /proc/loadavg)"
  grep -hE 'is not linted|over the baseline|panic ratchet:|^error' "$out/$tag.clippy.log" "$out/$tag.ratchet.log" | cut -c1-200 | head -4 | sed "s/^/  /"
}
for which in old new; do
  run "warm-$which" "$which"
  for i in $(seq "${RUNS:-2}"); do run "$which-$i" "$which"; done
done
if [[ "${LOAD:-1}" != 0 ]]; then
  busy=()
  for _ in $(seq "$(nproc)"); do (while :; do :; done) & busy+=($!); done
  for which in old new; do run "load-warm-$which" "$which"; run "load-$which" "$which"; done
  kill "${busy[@]}" 2>/dev/null
fi
