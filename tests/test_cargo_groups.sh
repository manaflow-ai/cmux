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
    --wait) wait_for="$2"; shift ;;
  esac
  shift
done
echo "started ${bins[*]}" >> "$FAKE_LOG"
# A group that waits for a file only finishes when another group is running too.
if [[ -n "$wait_for" ]]; then
  for _ in $(seq 1 200); do [[ -e "$wait_for" ]] && break; sleep 0.05; done
  [[ -e "$wait_for" ]] || { echo "error: never saw $wait_for" >&2; exit 3; }
fi
echo "compiling ${bins[*]} into $CARGO_TARGET_DIR"
((fail == 0)) || { echo "error: could not compile ${bins[*]}" >&2; exit 101; }
mkdir -p "$CARGO_TARGET_DIR/$target/release"
for b in "${bins[@]}"; do echo "$b from $CARGO_TARGET_DIR" > "$CARGO_TARGET_DIR/$target/release/$b"; done
FAKE
chmod +x "$work/bin/cargo"
export PATH="$work/bin:$PATH" FAKE_LOG="$work/log"
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
grep -Eq '^cargo group 2 \(acpmux\): [0-9]+ s$' <<<"$out" || fail "no time line for group 2: $out"

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

echo "PASS: cargo-groups.sh"
