#!/usr/bin/env bash
# build-cmux-tui-client.sh: a build host builds an unpublished tree's cmux-tui
# client set instead of waiting for a cmux-tui-artifacts run that a newer push
# may have replaced (cx-t3e5). A developer Mac refuses; an nx-remote job
# builds cmux-tui and the companions the bundle scripts name, with the build
# commit stamped so pin-cmux-tui.sh local-build accepts it; a clean tree reuses
# the set, and a tree with uncommitted cmux-tui edits rebuilds. Fake cargo.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
fail() { printf '%s\n' "$@" >&2; exit 1; }

src="$TMP/src"
git_q init "$src"
detector="cmux-tui/bindings/examples/rust-agent-screen-detection"
mkdir -p "$src/cmux-tui/crates/cmux-app-host" "$src/$detector" "$src/scripts/cmux-next" "$src/scripts/ci" "$TMP/bin"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$ROOT/scripts/cmux-next/build-cmux-tui-client.sh" "$src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$src/scripts/cmux-next/"
echo reducer > "$src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$src"
echo '[package]' > "$src/cmux-tui/crates/cmux-app-host/Cargo.toml"
echo '[package]' > "$src/$detector/Cargo.toml"
printf '#!/bin/sh\n# installs cmux-app-host and cmux-agent-screen-detection beside cmux\n' > "$src/scripts/cmux-next/bundle-cmux-tui.sh"
echo one > "$src/cmux-tui/a"
git_q -C "$src" add -A
git_q -C "$src" commit -m one

# cargo build -p P --bin B: writes $CARGO_TARGET_DIR/release/B, which reports
# CMUX_TUI_BUILD_COMMIT the way the real binary's --version does.
cat > "$TMP/bin/cargo" <<'EOF'
#!/usr/bin/env bash
name=""
while [[ $# -gt 0 ]]; do case "$1" in --bin) name="$2"; shift ;; esac; shift; done
mkdir -p "$CARGO_TARGET_DIR/release"
printf '#!/bin/sh\necho "%s 0.1.0 (%s 2026-10-08)"\n' "$name" "${CMUX_TUI_BUILD_COMMIT:-0000000000000000000000000000000000000000}" > "$CARGO_TARGET_DIR/release/$name"
chmod 755 "$CARGO_TARGET_DIR/release/$name"
echo "$name $PWD" >> "$FAKE_CARGO_LOG"
EOF
chmod 755 "$TMP/bin/cargo"
run() { (cd "$src" && env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" FAKE_CARGO_LOG="$TMP/cargo.log" "$@"); }
builds() { grep -c . "$TMP/cargo.log" 2>/dev/null || echo 0; }

if run bash scripts/cmux-next/build-cmux-tui-client.sh 2>"$TMP/err"; then fail "a developer Mac built cmux-tui"; fi
grep -q "never runs Cargo" "$TMP/err" || fail "unexpected refusal: $(cat "$TMP/err")"

path=$(run NX_JOB_ID=job bash scripts/cmux-next/build-cmux-tui-client.sh --print-path 2>"$TMP/err") || fail "an nx-remote job did not build: $(cat "$TMP/err")"
[[ -x "$path" && -x "$(dirname "$path")/cmux-app-host" && -x "$(dirname "$path")/cmux-agent-screen-detection" ]] || fail "missing client set at $path: $(ls "$(dirname "$path")" 2>&1)"
(cd "$src" && bash scripts/cmux-next/pin-cmux-tui.sh local-build "$path") || fail "pin-cmux-tui.sh local-build refused the build"
[[ "$(builds)" == 3 ]] || fail "want cmux-tui, cmux-app-host and the detector built once each: $(cat "$TMP/cargo.log")"
# The detector is its own Cargo workspace: built from its own directory.
grep -qx "cmux-agent-screen-detection $src/$detector" "$TMP/cargo.log" \
  || grep -q "^cmux-agent-screen-detection .*/rust-agent-screen-detection$" "$TMP/cargo.log" \
  || fail "the detector was not built from $detector: $(cat "$TMP/cargo.log")"

again=$(run NX_JOB_ID=job bash scripts/cmux-next/build-cmux-tui-client.sh --print-path 2>/dev/null)
[[ "$again" == "$path" && "$(builds)" == 3 ]] || fail "a clean tree rebuilt its set"

echo edit >> "$src/cmux-tui/a"
run NX_JOB_ID=job bash scripts/cmux-next/build-cmux-tui-client.sh --print-path >/dev/null 2>&1 || fail "a dirty tree did not build"
[[ "$(builds)" == 6 ]] || fail "a tree with uncommitted cmux-tui edits reused the set"
echo "build-cmux-tui-client: ok"
