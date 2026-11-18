#!/usr/bin/env bash
# scripts/ci/cargo-groups.sh runs the cmux-tui tree's cargo invocations at the
# same time, each in its own target directory, and gathers every binary into
# the one target directory the staging steps read. A fake cargo stands in for
# the real one: it records when it ran and writes the binaries it was asked for.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/ci/cargo-groups.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/bin"
cat > "$work/bin/cargo" <<'FAKE'
#!/usr/bin/env bash
# fake cargo: build --bin NAME... --target T [--fail] [--wait FILE]
set -euo pipefail
target="" bins=() fail=0 wait_for=""
while (($#)); do
  case "$1" in
    --bin) bins+=("$2"); shift ;;
    --target) target="$2"; shift ;;
    --fail) fail=1 ;;
    --sigkill) fail=9 ;;
    --wait) wait_for="$2"; shift ;;
  esac
  shift
done
echo "started ${bins[*]} jobs=${CARGO_BUILD_JOBS:-}" >> "$FAKE_LOG"
# A group that waits for a file only finishes when another group is running too.
if [[ -n "$wait_for" ]]; then
  for _ in $(seq 1 200); do [[ -e "$wait_for" ]] && break; sleep 0.05; done
  [[ -e "$wait_for" ]] || { echo "error: never saw $wait_for" >&2; exit 3; }
fi
echo "compiling ${bins[*]} into $CARGO_TARGET_DIR"
# What cargo prints when the kernel killed rustc (job 134786831617).
((fail != 9)) || { echo "error: could not compile \`${bins[*]}\`"; echo "  process didn't exit successfully: \`rustc --crate-name x\` (signal: 9, SIGKILL: kill)"; exit 101; } >&2
((fail == 0)) || { echo "error: could not compile ${bins[*]}" >&2; exit 101; }
mkdir -p "$CARGO_TARGET_DIR/$target/release"
for b in "${bins[@]}"; do echo "$b from $CARGO_TARGET_DIR" > "$CARGO_TARGET_DIR/$target/release/$b"; done
echo "ended ${bins[*]}" >> "$FAKE_LOG"
FAKE
chmod +x "$work/bin/cargo"
# Room for every group at once unless a case says otherwise.
export PATH="$work/bin:$PATH" FAKE_LOG="$work/log" CARGO_GROUPS_MEM_GB=1000
t=x86_64-unknown-linux-musl
td="$work/target"

# 1. Groups overlap: group 2 waits for a file group 3 writes after it starts.
#    Run one after another, group 2 would never finish.
: > "$FAKE_LOG"
out="$("$script" "$td" "$t" \
  "cmux-tui cmux-tui-hook" "cargo build --bin cmux-tui --bin cmux-tui-hook --target $t" \
  "acpmux" "cargo build --bin acpmux --target $t --wait $work/relay-started" \
  "cmux-relay" "touch $work/relay-started && cargo build --bin cmux-relay --target $t" 2>&1)" \
  || fail "concurrent groups failed: $out"
for b in cmux-tui cmux-tui-hook acpmux cmux-relay; do
  [[ -f "$td/$t/release/$b" ]] || fail "$b is not in the main target directory"
done
grep -q "cmux-tui from $td\$" "$td/$t/release/cmux-tui" || fail "group 1 did not build in the main target directory"
grep -q "acpmux from $td/groups/2\$" "$td/$t/release/acpmux" || fail "group 2 did not get its own target directory"
grep -q "cmux-relay from $td/groups/3\$" "$td/$t/release/cmux-relay" || fail "group 3 did not get its own target directory"
# Each group's output is printed whole, in group order, with its time.
[[ "$(grep -n 'compiling cmux-tui' <<<"$out" | cut -d: -f1)" -lt "$(grep -n 'compiling acpmux' <<<"$out" | cut -d: -f1)" ]] \
  || fail "group logs are not in group order: $out"
grep -Eq '^cargo group 2 \(acpmux\): [0-9]+ s(, largest process [0-9.]+ GB)?$' <<<"$out" || fail "no time line for group 2: $out"

# 2. A failed group fails the run after every group finished, and names it.
rm -rf "$td"; : > "$FAKE_LOG"
if out="$("$script" "$td" "$t" \
  "cmux-tui" "cargo build --bin cmux-tui --target $t" \
  "chatmux-relay" "cargo build --bin chatmux-relay --target $t --fail" \
  "cmux-relay" "cargo build --bin cmux-relay --target $t" 2>&1)"; then
  fail "a failed group passed: $out"
fi
grep -q "error: could not compile chatmux-relay" <<<"$out" || fail "the failed group's log is missing: $out"
grep -q "cargo group 2 (chatmux-relay) failed" <<<"$out" || fail "the failed group is not named: $out"
[[ "$(grep -c '^started' "$FAKE_LOG")" == 3 ]] || fail "a failure stopped the other groups: $(cat "$FAKE_LOG")"
[[ ! -e "$td/$t/release/chatmux-relay" ]] || fail "a failed group's binary was gathered"

# 3. An optional binary ('?name') may be missing, and never leaves a stale copy.
rm -rf "$td"; mkdir -p "$td/$t/release"; echo stale > "$td/$t/release/cmux-agent-screen-detection"
out="$("$script" "$td" "$t" \
  "cmux-tui" "cargo build --bin cmux-tui --target $t" \
  "?cmux-agent-screen-detection" "cargo build --bin other --target $t --fail || echo 'detector did not build'" 2>&1)" \
  || fail "a missing optional binary failed the run: $out"
[[ ! -e "$td/$t/release/cmux-agent-screen-detection" ]] || fail "a stale optional binary stayed in place"

# 4. A required binary the group did not make fails the run.
rm -rf "$td"
if out="$("$script" "$td" "$t" \
  "cmux-tui" "cargo build --bin cmux-tui --target $t" \
  "cmux-relay" "cargo build --bin not-the-relay --target $t" 2>&1)"; then
  fail "a missing required binary passed: $out"
fi
grep -q "cmux-relay" <<<"$out" || fail "the missing binary is not named: $out"

# 5. Group 1 gets every core; the others share 2 x cores. A caller's
#    CARGO_BUILD_JOBS applies to every group.
cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
share=$(((2 * cores + 2) / 3))
lead=$((cores > share ? cores : share))
rm -rf "$td"; : > "$FAKE_LOG"
out="$(env -u CARGO_BUILD_JOBS "$script" "$td" "$t" \
  "cmux-tui" "cargo build --bin cmux-tui --target $t" \
  "acpmux" "cargo build --bin acpmux --target $t" \
  "cmux-relay" "cargo build --bin cmux-relay --target $t" 2>&1)" || fail "job split run failed: $out"
grep -qx "started cmux-tui jobs=$lead" "$FAKE_LOG" || fail "group 1 did not get $lead jobs: $(cat "$FAKE_LOG")"
grep -qx "started acpmux jobs=$share" "$FAKE_LOG" || fail "group 2 did not get $share jobs: $(cat "$FAKE_LOG")"
grep -qx "started cmux-relay jobs=$share" "$FAKE_LOG" || fail "group 3 did not get $share jobs: $(cat "$FAKE_LOG")"
rm -rf "$td"; : > "$FAKE_LOG"
out="$(CARGO_BUILD_JOBS=3 "$script" "$td" "$t" \
  "cmux-tui" "cargo build --bin cmux-tui --target $t" \
  "acpmux" "cargo build --bin acpmux --target $t" 2>&1)" || fail "caller jobs run failed: $out"
[[ "$(grep -c ' jobs=3$' "$FAKE_LOG")" == 2 ]] || fail "a caller's CARGO_BUILD_JOBS did not reach every group: $(cat "$FAKE_LOG")"

# 6. Weights: on 16 GB the two 12 GB groups (as cmux-tui and acpmux-standalone
#    under fat LTO) never run together, and the 2 GB group runs beside the
#    first (group 1 waits for a file group 2 writes). A group heavier than the
#    memory still runs, alone; groups with no weight count 6 GB.
rm -rf "$td"; : > "$FAKE_LOG"
out="$(CARGO_GROUPS_MEM_GB=16 CARGO_GROUPS_GB="12 2 12" "$script" "$td" "$t" \
  "cmux-tui" "cargo build --bin cmux-tui --target $t --wait $work/light-started" \
  "cmux-relay" "touch $work/light-started && cargo build --bin cmux-relay --target $t" \
  "acpmux" "cargo build --bin acpmux --target $t" 2>&1)" \
  || fail "weighted groups failed: $out"
grep -q "cargo groups: 3, 2 at first" <<<"$out" || fail "the first admission is not announced: $out"
[[ "$(grep -n '^ended cmux-tui' "$FAKE_LOG" | cut -d: -f1)" -lt "$(grep -n '^started acpmux' "$FAKE_LOG" | cut -d: -f1)" ]] \
  || fail "the two heavy groups ran together: $(cat "$FAKE_LOG")"
for b in cmux-tui cmux-relay acpmux; do [[ -f "$td/$t/release/$b" ]] || fail "$b missing with weights"; done
rm -rf "$td"; : > "$FAKE_LOG"
out="$(CARGO_GROUPS_MEM_GB=4 "$script" "$td" "$t" \
  "cmux-tui" "cargo build --bin cmux-tui --target $t" \
  "acpmux" "cargo build --bin acpmux --target $t" 2>&1)" || fail "groups over the memory failed: $out"
grep -q "cargo groups: 2, 1 at first" <<<"$out" || fail "one at first not announced: $out"
[[ "$(tr '\n' ' ' < "$FAKE_LOG")" == "started cmux-tui "*"ended cmux-tui started acpmux "*"ended acpmux " ]] \
  || fail "groups over the memory did not run one by one in order: $(cat "$FAKE_LOG")"
# The job split is sized for the most groups that can run together, not the
# first admission: on 16 GB with the Linux cross step's weights two start, but
# four 2 GB groups can run at once later, so each of the others gets
# ceil(2 x cores / 4), not every core (review of #46436, F1).
rm -rf "$td"; : > "$FAKE_LOG"
out="$(env -u CARGO_BUILD_JOBS CARGO_GROUPS_MEM_GB=16 CARGO_GROUPS_GB="13 2 2 2 13 2" "$script" "$td" "$t" \
  "g1" "cargo build --bin g1 --target $t" "g2" "cargo build --bin g2 --target $t" \
  "g3" "cargo build --bin g3 --target $t" "g4" "cargo build --bin g4 --target $t" \
  "g5" "cargo build --bin g5 --target $t" "g6" "cargo build --bin g6 --target $t" 2>&1)" \
  || fail "the Linux cross weights failed: $out"
grep -q "cargo groups: 6, 2 at first, at most 4 at once" <<<"$out" || fail "the peak is not announced: $out"
peak_share=$(((2 * cores + 3) / 4))
((peak_share <= cores)) || peak_share=$cores
for g in g2 g3 g4 g5 g6; do
  grep -qx "started $g jobs=$peak_share" "$FAKE_LOG" \
    || fail "$g did not get $peak_share jobs (sized for the peak of 4): $(cat "$FAKE_LOG")"
done
grep -qx "started g1 jobs=$cores" "$FAKE_LOG" || fail "group 1 did not keep every core: $(cat "$FAKE_LOG")"

# 7. A rustc killed by signal 9 is named as the runner's memory, not the code.
rm -rf "$td"
if out="$(GITHUB_ACTIONS=true RUNNER_NAME=blacksmith-4vcpu-test "$script" "$td" "$t" \
  "cmux-tui" "cargo build --bin cmux-tui --target $t" \
  "acpmux" "cargo build --bin acpmux --target $t --sigkill" 2>&1)"; then
  fail "a killed group passed: $out"
fi
grep -q '^::error title=runner out of memory::cargo group 2 (acpmux): .*\[cmux-ci machine: runner-oom\].*blacksmith-4vcpu-test' <<<"$out" \
  || fail "the killed group is not named as runner OOM: $out"
rm -rf "$td"
out="$("$script" "$td" "$t" "cmux-tui" "cargo build --bin cmux-tui --target $t --fail" 2>&1)" && fail "a failed group passed: $out"
! grep -q "runner-oom" <<<"$out" || fail "a compile error was named as runner OOM: $out"

echo "PASS: cargo-groups.sh"
