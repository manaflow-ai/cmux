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
echo "rustup \$(basename "\$PWD") \${RUSTUP_TOOLCHAIN:+[\$RUSTUP_TOOLCHAIN] }\$*" >> "$TMP/calls"
[[ "\$1" != which ]] || echo "\${RUSTUP_WHICH_CARGO:-$TMP/bin/cargo}"
[[ "\$1" != run ]] || { shift 2; exec "$TMP/bin/cargo" "\$@"; }
STUB
printf '#!/bin/bash\necho "${FAKE_OS:-Linux}"\n' >"$TMP/bin/uname"
cat >"$TMP/bin/swift" <<STUB
#!/bin/bash
echo "swift \${CMUX_SWIFTPM_TARGET_LINUX:-unset} \$*" >> "$TMP/calls"
STUB
cat >"$TMP/bin/bun" <<STUB
#!/bin/bash
[[ "\$1" != --version ]] || { echo 1.4.4; exit 0; }
echo "bun \$(basename "\$PWD") \$*" >> "$TMP/calls"
STUB
chmod +x "$TMP/bin/"*
# A checkout with every input the modes read.
W="$TMP/work"
mkdir -p "$W/.github/workflows" "$W/Packages/Shared/Port/Tests" "$W/Packages/Shared/NoTests" "$W/.github/scripts" "$W/crates/ws" "$W/crates/pinned" "$W/crates/off" "$W/cmux-tui" "$W/scripts/cmux-next" "$W/web/scripts"
cp "$ROOT/.github/scripts/rust-workspaces.py" "$W/.github/scripts/"
cat >"$W/.github/rust-workspaces.toml" <<'TOML'
[[workspace]]
root = "crates/ws"
run = true

[[workspace]]
root = "crates/pinned"
run = true

[[workspace]]
root = "crates/off"
skip = "a test root nothing checks"
TOML
printf '[package]\nname = "ws"\nversion = "0.1.0"\n\n[workspace]\n' >"$W/crates/ws/Cargo.toml"
printf '[package]\nname = "pinned"\nversion = "0.1.0"\n\n[workspace]\n' >"$W/crates/pinned/Cargo.toml"
printf '[toolchain]\nchannel = "1.90.0"\n' >"$W/crates/pinned/rust-toolchain.toml"
printf '[toolchain]\nchannel = "1.95.0"\n' >"$W/cmux-tui/rust-toolchain.toml"
printf '[package]\nname = "off"\nversion = "0.1.0"\n\n[workspace]\n' >"$W/crates/off/Cargo.toml"
cat >"$W/.github/workflows/swift-packages-linux.yml" <<'YML'
jobs:
  packages:
    strategy:
      matrix:
        include:
          - group: shared
            packages: >-
              Packages/Shared/Port
              Packages/Shared/NoTests
    steps:
      - run: echo Packages/Shared/Other
YML
touch "$W/Packages/Shared/Port/Tests/.keep" "$W/Packages/Shared/NoTests/Package.swift"
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
# A root with no rust-toolchain.toml gets cmux-tui's channel, as setup-cmux-tui-rust makes it the default.
ARGS=(rust-workspace crates/pinned)
out=$(run CMUX_CI_STEP_KEY=k) || fail "rust-workspace (pinned) refused: $out"
grep -q '^rustup pinned toolchain install$' "$TMP/calls" || fail "no toolchain install in the pinned root: $(calls)"
grep -q 'RUSTUP_TOOLCHAIN\|\[1.95.0\]' "$TMP/calls" && fail "a pinned root got cmux-tui's toolchain: $(calls)"
rm -f "$TMP/calls"
ARGS=(rust-workspace crates/ws)
out=$(run CMUX_CI_STEP_KEY=k) || fail "rust-workspace refused: $out"
grep -q '^rustup work \[1.95.0\] toolchain install 1.95.0 --profile minimal --component clippy --component rustfmt$' "$TMP/calls" || fail "an unpinned root did not get cmux-tui's toolchain: $(calls)"
grep -q '^cargo ws .*/.build/rust-workspace-target/crates__ws clippy --workspace --all-targets -- -D warnings$' "$TMP/calls" || fail "clippy: $(calls)"
grep -q '^cargo ws .*/.build/rust-workspace-target/crates__ws test --workspace$' "$TMP/calls" || fail "test: $(calls)"
grep -q 'feat-parity-check: green' <<<"$out" || fail "no green summary: $out"
rm -f "$TMP/calls"
# The cargo on a fleet Mac's PATH is not always the rustup proxy: then `cargo clippy` finds no
# cargo-clippy (2026-10-29, step dbb2c454 on cmux8s: "error: no such command: `clippy`"). The
# root's toolchain cargo (`rustup which cargo`, whose bin dir holds cargo-clippy) must run them.
mkdir -p "$TMP/toolchain"
cat >"$TMP/toolchain/cargo" <<STUB
#!/bin/bash
echo "toolchain-cargo \$(basename "\$PWD") \$*" >> "$TMP/calls"
STUB
chmod +x "$TMP/toolchain/cargo"
for root in crates/ws crates/pinned; do
  ARGS=(rust-workspace "$root")
  out=$(run CMUX_CI_STEP_KEY=k RUSTUP_WHICH_CARGO="$TMP/toolchain/cargo") || fail "rust-workspace $root with a non-proxy PATH cargo is red: $out"
  name="${root#crates/}"
  grep -q "^toolchain-cargo $name clippy --workspace --all-targets -- -D warnings$" "$TMP/calls" || fail "$root: clippy did not run with the toolchain's cargo: $(calls)"
  grep -q "^toolchain-cargo $name test --workspace$" "$TMP/calls" || fail "$root: tests did not run with the toolchain's cargo: $(calls)"
  ! grep -q "^cargo $name .* clippy" "$TMP/calls" || fail "$root: clippy ran with the PATH cargo: $(calls)"
  want_which="^rustup $name which cargo$"
  [[ "$name" != ws ]] || want_which='^rustup ws \[1.95.0\] which cargo$'
  grep -q "$want_which" "$TMP/calls" || fail "$root: rustup which cargo did not run in the root with its toolchain: $(calls)"
  rm -f "$TMP/calls"
done
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
  "clippy -p cmux-sdk -p cmux-sidebar --all-targets --locked -- -D warnings"
  "test -p cmux-sdk --all-targets --locked --no-default-features"
  "clippy -p cmux-sdk --all-targets --locked --no-default-features -- -D warnings"
  "doc -p cmux-sdk -p cmux-sidebar --locked --no-deps"
  "package -p cmux-sdk --locked"
  "package -p cmux-sidebar --locked --list")
[[ "$(grep '^cargo' "$TMP/calls" | sed 's/^cargo cmux-tui [^ ]* //')" == "$(printf '%s\n' "${want[@]}")" ]] || fail "sdk-rust: $(calls)"
rm -f "$TMP/calls"
# A red step does not stop the others; the step exits red.
ARGS=(sdk-rust)
out=$(run CMUX_CI_STEP_KEY=k CARGO_RED=fmt) && fail "a red fmt passed"
[[ "$(grep -c '^cargo' "$TMP/calls")" == 9 ]] || fail "a red fmt stopped the other steps: $(calls)"
grep -q 'feat-parity-check: RED' <<<"$out" || fail "no red summary: $out"
rm -f "$TMP/calls"

# sdk-msrv: Rust 1.88 for the public SDK crates and examples.
ARGS=(sdk-msrv)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "sdk-msrv refused"
grep -q '^rustup work toolchain install 1.88.0 --profile minimal --component clippy --component rustfmt$' "$TMP/calls" || fail "msrv toolchain: $(calls)"
[[ "$(grep -c '^rustup work run 1.88.0 cargo ' "$TMP/calls")" == 6 ]] || fail "msrv runs not through rustup run 1.88.0: $(calls)"
grep -q '^cargo work .* test --manifest-path .*/cmux-tui/bindings/rust/Cargo.toml --locked$' "$TMP/calls" || fail "msrv rust test: $(calls)"
rm -f "$TMP/calls"

# cef-shim-cpp: every test-*-cpp.sh, all of them even after a red one.
ARGS=(cef-shim-cpp)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "cef-shim-cpp refused"
[[ "$(calls)" == $'cpp a\ncpp b' ]] || fail "cef-shim-cpp: $(calls)"
rm -f "$TMP/calls"
run CMUX_CI_STEP_KEY=k CPP_RED=a >/dev/null && fail "a red shim test passed"
[[ "$(calls)" == $'cpp a\ncpp b' ]] || fail "a red shim test stopped the others: $(calls)"
rm -f "$TMP/calls"
# The Chromium Host's C++ tests (perf/chrome-parity: the dispatcher and the remote shim ABI), where
# the commit has them: run after the shim tests, each its own sub-step, every one even after a red.
mkdir -p "$W/scripts/cmux-next/tests"
for t in chromium-host-dispatch remote-shim-abi; do
  printf '#!/bin/bash\necho "host %s" >> "%s"\n[[ "%s" != "${HOST_RED:-}" ]]\n' "$t" "$TMP/calls" "$t" >"$W/scripts/cmux-next/tests/$t.test.sh"
  chmod +x "$W/scripts/cmux-next/tests/$t.test.sh"
done
out=$(run CMUX_CI_STEP_KEY=k) || fail "cef-shim-cpp with the host tests is red: $out"
[[ "$(calls)" == $'cpp a\ncpp b\nhost chromium-host-dispatch\nhost remote-shim-abi' ]] || fail "cef-shim-cpp did not run the host tests: $(calls)"
grep -q '^chromium-host-dispatch.test *pass' <<<"$out" || fail "no summary row for the host dispatcher test: $out"
rm -f "$TMP/calls"
out=$(run CMUX_CI_STEP_KEY=k HOST_RED=chromium-host-dispatch) && fail "a red host test passed"
grep -q '^chromium-host-dispatch.test *FAIL (exit 1)' <<<"$out" || fail "the summary does not name the red host test: $out"
[[ "$(calls)" == $'cpp a\ncpp b\nhost chromium-host-dispatch\nhost remote-shim-abi' ]] || fail "a red host test stopped the others: $(calls)"
rm -rf "$W/scripts/cmux-next/tests"
rm -f "$TMP/calls"

# swift-portable PKG: swift-packages-linux.yml's build and test, only for a package its matrix lists.
ARGS=(swift-portable Packages/Shared/Port)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "swift-portable refused"
[[ "$(calls)" == "$(printf '%s\n' 'swift 1 build --package-path Packages/Shared/Port --build-tests' 'swift 1 test --package-path Packages/Shared/Port --skip-build --parallel')" ]] || fail "swift-portable: $(calls)"
rm -f "$TMP/calls"
ARGS=(swift-portable Packages/Shared/NoTests)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "swift-portable with no Tests refused"
[[ "$(calls)" == 'swift 1 build --package-path Packages/Shared/NoTests --build-tests' ]] || fail "swift-portable ran tests a package does not have: $(calls)"
rm -f "$TMP/calls"
ARGS=(swift-portable Packages/Shared/Port)
rc=0; out=$(run CMUX_CI_STEP_KEY=k FAKE_OS=Darwin) || rc=$?
[[ "$rc" == 78 ]] || fail "swift-portable on macOS exited $rc, want 78 (no Linux evidence): $out"
for bad in Packages/Shared/Other Packages/Shared ../Packages/Shared/Port; do
  ARGS=(swift-portable "$bad")
  run CMUX_CI_STEP_KEY=k >/dev/null && fail "swift-portable accepted $bad"
done
[[ -z "$(calls)" ]] || fail "swift ran for a refused package: $(calls)"

# web: ci-web.yml's web/ checks with the pinned bun.
ARGS=(web)
run CMUX_CI_STEP_KEY=k >/dev/null || fail "web refused"
[[ "$(calls)" == "$(printf '%s\n' 'bun web install --frozen-lockfile' 'bun web tools/generate-managed-iroh-relay-catalog.ts --check' 'bun web run typecheck' 'bun web run lint:complexity' 'run-tests ')" ]] || fail "web: $(calls)"
rm -f "$TMP/calls"

# notices: cmux-next-guards.yml rust-notices-tree's "Generate the Rust notices from this tree (as the nightly does)", the
# same command and environment (cargo writes the cargo trees) with cmux-tui's pinned cargo first on PATH, and its
# cache and trees in the step's .build.
cat >"$W/scripts/cmux-next/generate-third-party-notices.sh" <<STUB
#!/bin/bash
echo "notices \$(basename "\$PWD") allow=\${CMUX_NOTICES_ALLOW_CARGO:-unset} cache=\${CMUX_NOTICES_CACHE#\$PWD/} \${*//\$PWD\//}" >> "$TMP/calls"
[[ -z "\${NOTICES_RED:-}" ]] || { echo "error: no license mapping for crate red-crate 1.0.0" >&2; exit 1; }
STUB
chmod +x "$W/scripts/cmux-next/generate-third-party-notices.sh"
ARGS=(notices)
out=$(run CMUX_CI_STEP_KEY=k) || fail "notices refused: $out"
[[ "$(calls)" == "$(printf '%s\n' 'rustup cmux-tui component add clippy rustfmt' 'rustup cmux-tui which cargo' 'notices work allow=1 cache=.build/notices/cache --tui-source tree --cargo-trees .build/notices/cargo-trees --write-cargo-trees')" ]] || fail "notices: $(calls)"
grep -q 'feat-parity-check: green' <<<"$out" || fail "no green summary for notices: $out"
rm -f "$TMP/calls"
out=$(run CMUX_CI_STEP_KEY=k NOTICES_RED=1) && fail "a red notices generation passed"
grep -q '^notices from the tree *FAIL (exit 1)' <<<"$out" || fail "the summary does not name the red notices step: $out"
grep -q 'error: no license mapping for crate red-crate' <<<"$out" || fail "the generator's error is not in the step log: $out"
rm -f "$TMP/calls"
ARGS=(notices extra)
run CMUX_CI_STEP_KEY=k >/dev/null && fail "notices accepted an argument"
[[ -z "$(calls)" ]] || fail "the generator ran for a refused request: $(calls)"

ARGS=(web extra)
run CMUX_CI_STEP_KEY=k >/dev/null && fail "web accepted an argument"
ARGS=(deploy)
run CMUX_CI_STEP_KEY=k >/dev/null && fail "accepted an unknown mode"
[[ -z "$(calls)" ]] || fail "tools ran for a refused request: $(calls)"
printf 'feat-parity-check tests: ok\n'
