#!/usr/bin/env bash
# scripts/ci/feat-parity-check.sh: feat-cmux-next checks with no fleet mode before 2026-10-29
# (rust-workspaces roots, the Rust SDK and its MSRV, the CEF shim C++ tests, web/), as fleet steps.
# Stub cargo, rustup and bun record what runs; rust-workspaces.py is the real one on a scratch repo.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/ci/feat-parity-check.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
python3 -c 'import tomllib' 2>/dev/null || { echo "SKIP: python3 has no tomllib"; exit 0; }
mkdir -p "$TMP/bin"
cat >"$TMP/bin/cargo" <<STUB
#!/bin/bash
echo "cargo \$(basename "\$PWD") \${CARGO_TARGET_DIR:-unset} \$*" >> "$TMP/calls"
[[ "\${CARGO_RED:-}" != "\$1" ]]
STUB
cat >"$TMP/bin/rustup" <<STUB
#!/bin/bash
echo "rustup \$(basename "\$PWD") \$*" >> "$TMP/calls"
[[ "\$1" != which ]] || echo "$TMP/bin/cargo"
STUB
cat >"$TMP/bin/bun" <<STUB
#!/bin/bash
[[ "\$1" != --version ]] || { echo 1.4.4; exit 0; }
echo "bun \$(basename "\$PWD") \$*" >> "$TMP/calls"
STUB
chmod +x "$TMP/bin/"*
# A checkout with every input the modes read.
W="$TMP/work"
mkdir -p "$W/.github/scripts" "$W/crates/ws" "$W/crates/off" "$W/cmux-tui" "$W/scripts/cmux-next" "$W/web/scripts"
cp "$ROOT/.github/scripts/rust-workspaces.py" "$W/.github/scripts/"
cat >"$W/.github/rust-workspaces.toml" <<'TOML'
[[workspace]]
root = "crates/ws"
run = true

[[workspace]]
root = "crates/off"
skip = "a test root nothing checks"
TOML
printf '[package]\nname = "ws"\nversion = "0.1.0"\n\n[workspace]\n' >"$W/crates/ws/Cargo.toml"
printf '[package]\nname = "off"\nversion = "0.1.0"\n\n[workspace]\n' >"$W/crates/off/Cargo.toml"
for t in a b; do printf '#!/bin/bash\necho "cpp %s" >> "%s"\n[[ "%s" != "${CPP_RED:-}" ]]\n' "$t" "$TMP/calls" "$t" >"$W/scripts/cmux-next/test-$t-cpp.sh"; done
printf '#!/bin/bash\necho "run-tests $*" >> "%s"\n' "$TMP/calls" >"$W/web/scripts/run-tests.sh"
chmod +x "$W"/scripts/cmux-next/*.sh "$W/web/scripts/run-tests.sh"
git -C "$W" init -q && git -C "$W" add -A && git -C "$W" -c user.email=t@t -c user.name=t commit -qm fixture
run() { (cd "$W" && env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" "$@" /bin/bash "$SCRIPT" "${ARGS[@]}") 2>&1; }
calls() { cat "$TMP/calls" 2>/dev/null || true; }

ARGS=(sdk-rust)
out=$(run) && fail "ran outside a fleet step"
grep -q 'cmux-ci run --class light --script scripts/ci/feat-parity-check.sh' <<<"$out" || fail "refusal does not name the fleet command: $out"
[[ -z "$(calls)" ]] || fail "ran tools outside a fleet step: $(calls)"

# rust-workspace ROOT: the root's toolchain, then rust-workspaces.py run (clippy, then cargo test).
ARGS=(rust-workspace crates/ws)
out=$(run CMUX_CI_STEP_KEY=k) || fail "rust-workspace refused: $out"
grep -q '^rustup ws toolchain install$' "$TMP/calls" || fail "no toolchain install in the root: $(calls)"
grep -q '^cargo ws .*/.build/rust-workspace-target/crates__ws clippy --workspace --all-targets -- -D warnings$' "$TMP/calls" || fail "clippy: $(calls)"
grep -q '^cargo ws .*/.build/rust-workspace-target/crates__ws test --workspace$' "$TMP/calls" || fail "test: $(calls)"
grep -q 'feat-parity-check: green' <<<"$out" || fail "no green summary: $out"
rm -f "$TMP/calls"
for bad in crates/off crates/none ../crates/ws crates/./ws; do
  ARGS=(rust-workspace "$bad")
  run CMUX_CI_STEP_KEY=k >/dev/null && fail "rust-workspace accepted $bad"
done
ARGS=(rust-workspace)
run CMUX_CI_STEP_KEY=k >/dev/null && fail "rust-workspace ran with no root"
grep -q '^cargo' "$TMP/calls" 2>/dev/null && fail "cargo ran for a refused root: $(calls)"
rm -f "$TMP/calls"

# sdk-rust: cmux-tui-sdks.yml's rust package job, in cmux-tui, with the pinned cargo.
ARGS=(sdk-rust)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "sdk-rust refused"
want=("fmt -p cmux-sdk -p cmux-sidebar -- --check"
  "test -p cmux-sdk -p cmux-sidebar --all-targets --locked"
  "test -p cmux-sdk -p cmux-sidebar --doc --locked"
  "clippy -p cmux-sdk -p cmux-sidebar --all-targets --locked -- -D warnings")
[[ "$(grep '^cargo' "$TMP/calls" | sed 's/^cargo cmux-tui [^ ]* //')" == "$(printf '%s\n' "${want[@]}")" ]] || fail "sdk-rust: $(calls)"
rm -f "$TMP/calls"
# A red step does not stop the others; the step exits red.
ARGS=(sdk-rust)
out=$(run CMUX_CI_STEP_KEY=k CARGO_RED=fmt) && fail "a red fmt passed"
[[ "$(grep -c '^cargo' "$TMP/calls")" == 4 ]] || fail "a red fmt stopped the other steps: $(calls)"
grep -q 'feat-parity-check: RED' <<<"$out" || fail "no red summary: $out"
rm -f "$TMP/calls"

# sdk-msrv: Rust 1.88 for the public SDK crates and examples.
ARGS=(sdk-msrv)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "sdk-msrv refused"
grep -q '^rustup work toolchain install 1.88.0 --profile minimal --component clippy --component rustfmt$' "$TMP/calls" || fail "msrv toolchain: $(calls)"
[[ "$(grep -c '^cargo work .* +1.88.0 ' "$TMP/calls")" == 6 ]] || fail "msrv cargo runs: $(calls)"
grep -q '+1.88.0 test --manifest-path .*/cmux-tui/bindings/rust/Cargo.toml --locked$' "$TMP/calls" || fail "msrv rust test: $(calls)"
rm -f "$TMP/calls"

# cef-shim-cpp: every test-*-cpp.sh, all of them even after a red one.
ARGS=(cef-shim-cpp)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "cef-shim-cpp refused"
[[ "$(calls)" == $'cpp a\ncpp b' ]] || fail "cef-shim-cpp: $(calls)"
rm -f "$TMP/calls"
run CMUX_CI_STEP_KEY=k CPP_RED=a >/dev/null && fail "a red shim test passed"
[[ "$(calls)" == $'cpp a\ncpp b' ]] || fail "a red shim test stopped the others: $(calls)"
rm -f "$TMP/calls"

# web: ci-web.yml's web/ checks with the pinned bun.
ARGS=(web)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "web refused"
[[ "$(calls)" == "$(printf '%s\n' 'bun web install --frozen-lockfile' 'bun web tools/generate-managed-iroh-relay-catalog.ts --check' 'bun web run typecheck' 'bun web run lint:complexity' 'run-tests ')" ]] || fail "web: $(calls)"
rm -f "$TMP/calls"

ARGS=(web extra)
run CMUX_CI_STEP_KEY=k >/dev/null && fail "web accepted an argument"
ARGS=(deploy)
run CMUX_CI_STEP_KEY=k >/dev/null && fail "accepted an unknown mode"
[[ -z "$(calls)" ]] || fail "tools ran for a refused request: $(calls)"
printf 'feat-parity-check tests: ok\n'
