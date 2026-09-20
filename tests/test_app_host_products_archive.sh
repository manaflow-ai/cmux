#!/usr/bin/env bash
# Round-trips a fixture shaped like Xcode's Build/Products through
# scripts/ci/app-host-products-archive.sh and checks contents, modes and links.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVER="$ROOT_DIR/scripts/ci/app-host-products-archive.sh"

if ! command -v aa >/dev/null 2>&1; then
  echo "SKIP: aa (Apple Archive) ships only with macOS; the macOS compile admission job runs this test"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/app-host-products-archive-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mode_of() {
  stat -f '%Lp' "$1"
}

assert_link() {
  local path="$1" expected="$2" actual
  [ -L "$path" ] || fail "$path should be a symbolic link"
  actual="$(readlink "$path")"
  [ "$actual" = "$expected" ] || fail "$path points to '$actual', expected '$expected'"
}

assert_real_file() {
  local path="$1" expected="$2"
  [ ! -L "$path" ] || fail "$path should be a copy, not a symbolic link"
  [ -f "$path" ] || fail "$path should be a regular file"
  [ "$(cat "$path")" = "$expected" ] || fail "$path has unexpected contents"
}

derived="$WORK/producer/derived data"
products="$derived/Build/Products"
debug="$products/Debug"
outside="$WORK/outside"

# Regular files, an executable, and a bundle path containing a space.
mkdir -p "$debug/cmux DEV.app/Contents/MacOS" "$derived/Build/Intermediates.noindex"
printf 'manifest' > "$products/cmux-unit_macosx-arm64.xctestrun"
printf 'object' > "$debug/CmuxCore.o"
chmod 644 "$debug/CmuxCore.o"
printf 'private' > "$debug/private.bin"
chmod 600 "$debug/private.bin"
printf '#!/bin/sh\nexit 0\n' > "$debug/cmux DEV.app/Contents/MacOS/cmux DEV"
chmod 755 "$debug/cmux DEV.app/Contents/MacOS/cmux DEV"
printf 'not a product' > "$derived/Build/Intermediates.noindex/scratch"

# A versioned framework as Xcode lays it out. Headers is dangling on purpose:
# binary package frameworks in CI carry the same dangling top-level links.
framework="$debug/cmux DEV.app/Contents/Frameworks/Sample.framework"
mkdir -p "$framework/Versions/A/Resources"
printf 'framework binary' > "$framework/Versions/A/Sample"
chmod 755 "$framework/Versions/A/Sample"
printf 'info' > "$framework/Versions/A/Resources/Info.plist"
ln -s A "$framework/Versions/Current"
ln -s Versions/Current/Sample "$framework/Sample"
ln -s Versions/Current/Resources "$framework/Resources"
ln -s Versions/Current/Headers "$framework/Headers"

# Links that leave Build/Products, as a PackageFrameworks link into another
# part of DerivedData would, and a `..` link that happens to stay inside.
mkdir -p "$outside/frameworks/Linked.framework/Versions/A"
printf 'linked binary' > "$outside/frameworks/Linked.framework/Versions/A/Linked"
ln -s A "$outside/frameworks/Linked.framework/Versions/Current"
ln -s Versions/Current/Linked "$outside/frameworks/Linked.framework/Linked"
printf 'outside file' > "$outside/file.txt"
ln -s "$outside/frameworks" "$debug/PackageFrameworks"
ln -s ../../../../../outside/file.txt "$debug/escaping.txt"
ln -s ../Debug/CmuxCore.o "$debug/sibling.o"
ln -s "$WORK/missing" "$debug/dangling-absolute"

archive="$WORK/app-host-products.aar"
"$ARCHIVER" pack "$derived" "$archive"
[ -s "$archive" ] || fail "pack did not write $archive"

# pack copies the unportable link targets into the producer tree.
[ ! -L "$debug/PackageFrameworks" ] || fail "producer PackageFrameworks should have been copied"

# The consumer must not need anything that lived outside Build/Products.
rm -rf "$outside"

consumer="$WORK/consumer/other derived"
"$ARCHIVER" unpack "$archive" "$consumer"
restored="$consumer/Build/Products"
restored_debug="$restored/Debug"

[ ! -e "$consumer/Build/Intermediates.noindex" ] || fail "only Build/Products may be archived"
assert_real_file "$restored/cmux-unit_macosx-arm64.xctestrun" "manifest"
assert_real_file "$restored_debug/CmuxCore.o" "object"
[ "$(mode_of "$restored_debug/CmuxCore.o")" = "644" ] || fail "CmuxCore.o mode changed"
[ "$(mode_of "$restored_debug/private.bin")" = "600" ] || fail "private.bin mode changed"
executable="$restored_debug/cmux DEV.app/Contents/MacOS/cmux DEV"
[ "$(mode_of "$executable")" = "755" ] || fail "executable mode changed"
"$executable" || fail "restored executable did not run"

restored_framework="$restored_debug/cmux DEV.app/Contents/Frameworks/Sample.framework"
assert_link "$restored_framework/Versions/Current" "A"
assert_link "$restored_framework/Sample" "Versions/Current/Sample"
assert_link "$restored_framework/Resources" "Versions/Current/Resources"
assert_link "$restored_framework/Headers" "Versions/Current/Headers"
[ "$(cat "$restored_framework/Sample")" = "framework binary" ] || fail "framework binary unreadable through its links"
[ "$(mode_of "$restored_framework/Versions/A/Sample")" = "755" ] || fail "framework binary mode changed"
[ "$(cat "$restored_framework/Resources/Info.plist")" = "info" ] || fail "framework resources unreadable through their link"

[ -d "$restored_debug/PackageFrameworks" ] || fail "PackageFrameworks missing"
[ ! -L "$restored_debug/PackageFrameworks" ] || fail "PackageFrameworks must not link outside the products"
assert_real_file "$restored_debug/PackageFrameworks/Linked.framework/Versions/A/Linked" "linked binary"
[ "$(cat "$restored_debug/PackageFrameworks/Linked.framework/Linked")" = "linked binary" ] || fail "copied framework binary missing"
assert_real_file "$restored_debug/escaping.txt" "outside file"
assert_real_file "$restored_debug/sibling.o" "object"
assert_link "$restored_debug/dangling-absolute" "$WORK/missing"

# Every surviving link except the reported dangling one is portable.
while IFS= read -r -d '' link; do
  [ "$link" != "$restored_debug/dangling-absolute" ] || continue
  case "$(readlink "$link")" in
    /*|..|../*|*/..|*/../*) fail "unportable link survived: $link -> $(readlink "$link")" ;;
  esac
done < <(find "$restored" -type l -print0)

listing="$("$ARCHIVER" list "$archive")"
python3 - "$listing" <<'PY' || fail "list output is not the expected JSON"
import json, sys
entries = json.loads(sys.argv[1])
by_path = {entry["PAT"]: entry for entry in entries}
assert all(path == "Build/Products" or path.startswith("Build/Products/") for path in by_path), by_path.keys()
link = by_path["Build/Products/Debug/cmux DEV.app/Contents/Frameworks/Sample.framework/Versions/Current"]
assert link["TYP"] == "L" and link["LNK"] == "A", link
binary = by_path["Build/Products/Debug/cmux DEV.app/Contents/Frameworks/Sample.framework/Versions/A/Sample"]
assert binary["TYP"] == "F" and binary["DAT"] == len("framework binary"), binary
assert not any("UID" in entry or "GID" in entry for entry in entries)
PY

# Failures are loud and never leave a usable-looking result.
if "$ARCHIVER" unpack "$archive" "$consumer" 2>/dev/null; then
  fail "unpack must refuse a destination that already has products"
fi
printf 'corrupt' > "$WORK/corrupt.aar"
if "$ARCHIVER" unpack "$WORK/corrupt.aar" "$WORK/corrupt-destination" 2>/dev/null; then
  fail "unpack must fail on a corrupt archive"
fi
if "$ARCHIVER" pack "$WORK/no-such-derived-data" "$WORK/none.aar" 2>/dev/null; then
  fail "pack must fail without a products directory"
fi
[ ! -e "$WORK/none.aar" ] || fail "failed pack must not leave an archive"
if "$ARCHIVER" unpack "$WORK/missing.aar" "$WORK/missing-destination" 2>/dev/null; then
  fail "unpack must fail on a missing archive"
fi

echo "PASS: app-host products archive round trip"
