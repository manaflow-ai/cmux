#!/usr/bin/env bash
# build-acpmux.sh --cached-only seeds its cache from the same-tree acpmux a tree fetch put beside cmux-tui, and says
# why when it will not. Regression (air-blue, 2026-11-21): the fetched, checksum-verified acpmux sat in the tree folder,
# `lipo -archs` failed (a Mac with only the /usr/bin/lipo stub), the skip printed nothing, and resolve-acpmux.sh told
# the relaunch bench the acpmux "could not be fetched".
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$TMP/repo"; mkdir -p "$repo/scripts/cmux-next" "$repo/cmux-tui/crates/acpmux" "$repo/tree"
cp "$ROOT/scripts/cmux-next/build-acpmux.sh" "$repo/scripts/cmux-next/"
touch "$repo/cmux-tui/crates/acpmux/Cargo.toml"
cat > "$repo/scripts/cmux-next/pin-cmux-tui.sh" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == acpmux-path ]] || exit 2
echo "$(cd "$(dirname "$0")/../.." && pwd)/tree/acpmux"
STUB
chmod +x "$repo/scripts/cmux-next/"*.sh
git -C "$repo" init -q && git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m t

# A thin arm64 Mach-O as `file` reads it: the magic and CPU type are enough.
printf '\xcf\xfa\xed\xfe\x0c\x00\x00\x01\x00\x00\x00\x00\x02\x00\x00\x00' > "$repo/tree/acpmux"
head -c 4096 /dev/zero >> "$repo/tree/acpmux"; chmod 755 "$repo/tree/acpmux"
file -b "$repo/tree/acpmux" | grep -q 'Mach-O.*arm64' || { echo "skip: this file(1) does not read Mach-O"; exit 0; }

# lipo is the failing stub, as on a Mac without developer tools.
mkdir -p "$TMP/bin"; printf '#!/bin/sh\necho "xcrun: error: invalid active developer path" >&2\nexit 1\n' > "$TMP/bin/lipo"
chmod +x "$TMP/bin/lipo"
run() { (cd "$repo" && env -u CI -u GITHUB_ACTIONS -u CMUX_FLEET_BUILD_TAG -u NX_JOB_ID -u NX_APP PATH="$TMP/bin:$PATH" \
  CMUX_NEXT_ACPMUX_CACHE="$TMP/cache" "$@" "$repo/scripts/cmux-next/build-acpmux.sh" --cached-only --print-path 2>"$TMP/err") }

# The arch it needs: seeded through file(1), and the cached path printed.
out="$(run env CMUX_NEXT_ACPMUX_ARCHS=arm64)" || fail "arm64 not seeded: $(cat "$TMP/err")"
[[ "$out" == "$TMP/cache/in-tree-"*/arm64/acpmux && -x "$out" ]] || fail "seeded path: $out"
grep -q "source=same-tree" "$out.ref" || fail "ref: $(cat "$out.ref")"

# An arch it lacks: not seeded, and the reason names both sides.
rm -rf "$TMP/cache"
if out="$(run env CMUX_NEXT_ACPMUX_ARCHS=x86_64)"; then fail "x86_64 seeded from an arm64 binary: $out"; fi
grep -q "the same-tree fetch has no x86_64 slice for this build (needs x86_64; fetched: .*acpmux (arm64))" "$TMP/err" \
  || fail "skip reason: $(cat "$TMP/err")"

echo "build-acpmux-same-tree-seed.test.sh: ok"
