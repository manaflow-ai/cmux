#!/usr/bin/env bash
# scripts/ci/clippy-base-seed.sh against a fake r2-cache.sh and cargo-target-delta.sh in a scratch repo.
set -uo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/clippy-base-seed-test.XXXXXX")"
fail=0
check() { if ! eval "$2"; then echo "FAIL: $1"; fail=1; else echo "ok: $1"; fi; }

mkdir -p "$work/repo/scripts/ci" "$work/repo/cmux-tui" "$work/repo/.cargo"
cp "$src/scripts/ci/clippy-base-seed.sh" "$work/repo/scripts/ci/"
echo lock > "$work/repo/cmux-tui/Cargo.lock"; echo tc > "$work/repo/cmux-tui/rust-toolchain.toml"; echo c > "$work/repo/.cargo/config.toml"
git -C "$work/repo" init -q && git -C "$work/repo" add -A
log="$work/calls.log"
cat > "$work/repo/scripts/ci/r2-cache.sh" <<F
#!/usr/bin/env bash
echo "r2 \$*" >> "$log"
[[ -n "\${FAKE_R2_FAIL:-}" ]] && exit 1
exit 0
F
cat > "$work/repo/scripts/ci/cargo-target-delta.sh" <<F
#!/usr/bin/env bash
echo "delta \$*" >> "$log"
exit 0
F
run() { bash "$work/repo/scripts/ci/clippy-base-seed.sh" restore "$@"; }

: > "$log"; run "$work/cold" >/dev/null 2>&1
check "cold target restores the deps entry, the ws delta, then applies" \
  '[[ "$(grep -c "^r2 restore" "$log")" == 2 && "$(grep -c "^delta apply" "$log")" == 1 ]]'
check "the deps key carries the 16-hex input hash" 'grep -Eq "seed-deps-v1-[0-9a-f]{16} " "$log"'

mkdir -p "$work/warm/release/.fingerprint"; : > "$log"; run "$work/warm" >/dev/null 2>&1
check "a warm target is left alone" '[[ ! -s "$log" ]]'

: > "$log"; CMUX_CLIPPY_BASE_SEED=off run "$work/cold2" >/dev/null 2>&1
check "CMUX_CLIPPY_BASE_SEED=off does nothing" '[[ ! -s "$log" ]]'

: > "$log"; FAKE_R2_FAIL=1 run "$work/cold3" >/dev/null 2>&1; rc=$?
check "a miss is not fatal" '[[ $rc == 0 ]]'

verdict() { bash "$work/repo/scripts/ci/clippy-base-seed.sh" verdict "$@"; }
: > "$log"; verdict "$work/v" abc123 >/dev/null 2>&1; rc=$?
check "verdict restores the base's own key, then the newest by prefix, in the shared namespace" \
  '[[ $rc == 0 ]] && grep -q "^r2 restore $work/v cmux-tui-clippy-verdict-v1-abc123 cmux-tui-clippy-verdict-v1-$" "$log"'
: > "$log"; FAKE_R2_FAIL=1 verdict "$work/v2" abc123 >/dev/null 2>&1; rc=$?
check "a verdict miss is not fatal" '[[ $rc == 0 ]]'
: > "$log"; CMUX_CLIPPY_BASE_VERDICT=off verdict "$work/v3" abc123 >/dev/null 2>&1
check "CMUX_CLIPPY_BASE_VERDICT=off reads nothing" '[[ ! -s "$log" ]]'

check "usage error without a mode" '! bash "$work/repo/scripts/ci/clippy-base-seed.sh" >/dev/null 2>&1'
exit $fail
