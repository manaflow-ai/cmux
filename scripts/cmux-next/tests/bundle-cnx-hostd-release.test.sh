#!/usr/bin/env bash
# A Release cmux-next app always bundles cnx-hostd built from its own source:
# the "Bundle cnx-hostd" phase fails a Release build with no binary or with one
# whose .ref names another source key, and only CMUX_NEXT_CNX_HOSTD_OPTIONAL=1
# lets a Release build ship without it. Debug builds without it still pass.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

src="$TMP/src"
mkdir -p "$src/scripts/cmux-next" "$src/cnx-ios/rust/crates/cnx-hostd"
cp "$ROOT/scripts/cmux-next/build-cnx-hostd.sh" "$ROOT/scripts/cmux-next/bundle-cnx-hostd.sh" "$src/scripts/cmux-next/"
echo '[package]' > "$src/cnx-ios/rust/crates/cnx-hostd/Cargo.toml"
git_q init "$src"; git_q -C "$src" add -A; git_q -C "$src" commit -m one
key="$("$src/scripts/cmux-next/build-cnx-hostd.sh" --print-key)"
[[ "$key" =~ ^[0-9a-f]{16}$ ]] || fail "--print-key printed '$key'"

bin="$TMP/hostd/cnx-hostd"; mkdir -p "$(dirname "$bin")"; cp /usr/bin/true "$bin"
phase() { # CONFIGURATION, then extra env
  local conf="$1"; shift
  env -u CMUX_NEXT_CNX_HOSTD_BIN -u CMUX_NEXT_REQUIRE_CNX_HOSTD -u CMUX_NEXT_CNX_HOSTD_OPTIONAL -u ARCHS \
    SRCROOT="$src" TARGET_BUILD_DIR="$TMP/out" UNLOCALIZED_RESOURCES_FOLDER_PATH=App.app/Contents/Resources \
    CONFIGURATION="$conf" "$@" "$src/scripts/cmux-next/bundle-cnx-hostd.sh"
}
dest="$TMP/out/App.app/Contents/Resources/bin/cnx-hostd"

phase Release >/dev/null 2>"$TMP/err" && fail "a Release build without cnx-hostd passed"
grep -q 'must bundle cnx-hostd' "$TMP/err" || fail "unexpected error: $(cat "$TMP/err")"
phase Release CMUX_NEXT_CNX_HOSTD_OPTIONAL=1 >/dev/null || fail "the explicit opt-out failed"
[[ ! -e "$dest" ]] || fail "the opt-out bundled cnx-hostd"
phase Debug >/dev/null 2>&1 || fail "a Debug build without cnx-hostd failed"

phase Release CMUX_NEXT_CNX_HOSTD_BIN="$bin" >/dev/null 2>"$TMP/err" && fail "a Release build took a cnx-hostd with no .ref"
printf 'key=0000000000000000\n' > "$bin.ref"
phase Release CMUX_NEXT_CNX_HOSTD_BIN="$bin" >/dev/null 2>"$TMP/err" && fail "a Release build took cnx-hostd from another source"
grep -q 'built from source key' "$TMP/err" || fail "unexpected error: $(cat "$TMP/err")"
phase Debug CMUX_NEXT_CNX_HOSTD_BIN="$bin" >/dev/null 2>&1 || fail "a Debug build refused a stale cnx-hostd"

printf 'key=%s\ncommit=x\n' "$key" > "$bin.ref"
phase Release CMUX_NEXT_CNX_HOSTD_BIN="$bin" >/dev/null || fail "a Release build refused a same-source cnx-hostd"
[[ -x "$dest" ]] || fail "cnx-hostd is not in the bundle"
grep -q "key=$key" "$dest.version" || fail "cnx-hostd.version does not name the source key"

# A source change changes the key, so the old binary is refused again.
echo '# edit' >> "$src/cnx-ios/rust/crates/cnx-hostd/Cargo.toml"
phase Release CMUX_NEXT_CNX_HOSTD_BIN="$bin" >/dev/null 2>&1 && fail "a Release build took cnx-hostd from before a source edit"
echo "bundle-cnx-hostd-release: ok"
