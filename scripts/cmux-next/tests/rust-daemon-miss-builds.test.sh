#!/usr/bin/env bash
# A build host compiles acpmux and optchat-chief on a cache miss; it never
# stops with "no cached acpmux" (cx-t3e5: three lanes building tagged apps
# through nx-remote on cmux-lawrence-2 stopped there and copied a binary from
# another tag's build). Build hosts are CI, fleet builds (CMUX_FLEET_BUILD_TAG)
# and nx-remote jobs (NX_JOB_ID); a developer Mac still never runs Cargo.
# acpmux builds into a persistent target dir in the tree, so the next commit of
# the same tree compiles incrementally.
# Fake cargo and rustup stand in for the toolchain.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

src="$TMP/src"
mkdir -p "$src/scripts/cmux-next" "$src/cmux-tui/crates/acpmux" "$src/Native/OptChat/optchat-chief" "$TMP/bin"
cp "$ROOT/scripts/cmux-next/build-acpmux.sh" "$ROOT/scripts/cmux-next/build-optchat-chief.sh" "$src/scripts/cmux-next/"
echo '[package]' > "$src/cmux-tui/crates/acpmux/Cargo.toml"
echo '[package]' > "$src/Native/OptChat/optchat-chief/Cargo.toml"
printf '[toolchain]\nchannel = "1.95.0"\n' > "$src/cmux-tui/rust-toolchain.toml"
git_q init "$src"; git_q -C "$src" add -A; git_q -C "$src" commit -m one

# cargo [+toolchain] build ... --target T (--package P | --bin B): writes
# $CARGO_TARGET_DIR/T/release/<name> and logs the target dir it used.
cat > "$TMP/bin/cargo" <<'EOF'
#!/usr/bin/env bash
target="" name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) target="$2"; shift ;;
    --package|-p|--bin) name="$2"; shift ;;
  esac
  shift
done
mkdir -p "$CARGO_TARGET_DIR/$target/release"
printf '#!/bin/sh\n' > "$CARGO_TARGET_DIR/$target/release/$name"
chmod 755 "$CARGO_TARGET_DIR/$target/release/$name"
echo "$CARGO_TARGET_DIR" >> "$FAKE_CARGO_LOG"
EOF
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/rustup"
chmod 755 "$TMP/bin/cargo" "$TMP/bin/rustup"

run() { env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" FAKE_CARGO_LOG="$TMP/cargo.log" "$@"; }

# A developer Mac: no build, the old message.
if run "$src/scripts/cmux-next/build-acpmux.sh" 2>"$TMP/err"; then fail "a developer Mac built acpmux"; fi
grep -q "not cached" "$TMP/err" || fail "unexpected refusal: $(cat "$TMP/err")"
run "$src/scripts/cmux-next/build-acpmux.sh" --check-build-allowed && fail "a developer Mac may build acpmux"

# An nx-remote job: builds, then the cache answers --cached-only.
run NX_JOB_ID=1008-1-x "$src/scripts/cmux-next/build-acpmux.sh" --check-build-allowed || fail "an nx-remote job may not build acpmux"
run NX_JOB_ID=1008-1-x "$src/scripts/cmux-next/build-acpmux.sh" >/dev/null 2>"$TMP/err" || fail "an nx-remote job did not build acpmux: $(cat "$TMP/err")"
run "$src/scripts/cmux-next/build-acpmux.sh" --cached-only --print-path >/dev/null || fail "the built acpmux is not cached"
run NX_JOB_ID=1008-1-x "$src/scripts/cmux-next/build-optchat-chief.sh" >/dev/null 2>"$TMP/err" || fail "an nx-remote job did not build optchat-chief: $(cat "$TMP/err")"
run "$src/scripts/cmux-next/build-optchat-chief.sh" --cached-only --print-path >/dev/null || fail "the built optchat-chief is not cached"

# The next commit of the same tree builds in the same target dir (warm).
echo '// two' >> "$src/cmux-tui/crates/acpmux/Cargo.toml"; git_q -C "$src" commit -am two
run CMUX_FLEET_BUILD_TAG=x "$src/scripts/cmux-next/build-acpmux.sh" >/dev/null 2>&1 || fail "a fleet build did not build acpmux"
dirs=$(grep -c . "$TMP/cargo.log"); first=$(sed -n 1p "$TMP/cargo.log"); last=$(sed -n '$p' "$TMP/cargo.log")
[[ "$first" == "$last" && "$first" == "$src/"* ]] || fail "acpmux did not build in one persistent target dir in the tree:" "$(cat "$TMP/cargo.log")"
echo "rust-daemon-miss-builds: ok ($dirs builds)"
