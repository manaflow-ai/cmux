#!/usr/bin/env bash
# scripts/cmux-next/swift-exports-cache.sh packs the Swift exports of a tree
# with its stamp, and installs a pack only into a tree with the same source key.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo/scripts/cmux-next/swift-exports-cache.sh"
key="$repo/scripts/cmux-next/swift-exports-key.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

make_tree() {
  local root="$1"
  mkdir -p "$root/scripts/cmux-next"
  cp "$script" "$key" "$root/scripts/cmux-next/"
  while IFS= read -r rel; do
    mkdir -p "$root/$(dirname "$rel")"
    echo "export $rel" > "$root/$rel"
  done < <(python3 "$key" "$root" --list)
  mkdir -p "$root/Packages/macOS/CmuxNext/Sources/A"
  echo "struct A {}" > "$root/Packages/macOS/CmuxNext/Sources/A/A.swift"
  git -C "$root" init -q
  git -C "$root" add -A
}

make_tree "$tmp/source"
"$tmp/source/scripts/cmux-next/swift-exports-cache.sh" pack "$tmp/pack" >/dev/null
[[ -f "$tmp/pack/schemas/settings/settings-schema.json" ]] || fail "pack has no settings schema"
[[ -f "$tmp/pack/.swift-exports.key" ]] || fail "pack has no stamp"
[[ "$(cat "$tmp/pack/.swift-exports.key")" == "$(python3 "$key" "$tmp/source" --stamp)" ]] || fail "stamp differs"

# Same sources, exports deleted: install restores every export.
make_tree "$tmp/same"
while IFS= read -r rel; do rm "$tmp/same/$rel"; done < <(python3 "$key" "$tmp/same" --list)
"$tmp/same/scripts/cmux-next/swift-exports-cache.sh" install "$tmp/pack" | grep -q "Swift exports restored" \
  || fail "install did not report the restore"
[[ "$(python3 "$key" "$tmp/same" --outputs)" == "$(python3 "$key" "$tmp/source" --outputs)" ]] \
  || fail "installed exports differ from the pack"

# Other sources: install refuses and writes nothing.
make_tree "$tmp/other"
echo "struct B {}" > "$tmp/other/Packages/macOS/CmuxNext/Sources/A/A.swift"
rm "$tmp/other/schemas/settings/settings-schema.json"
if "$tmp/other/scripts/cmux-next/swift-exports-cache.sh" install "$tmp/pack" 2>"$tmp/err"; then
  fail "install accepted a pack of other sources"
fi
grep -q "source key" "$tmp/err" || fail "refusal does not name the source key"
[[ ! -e "$tmp/other/schemas/settings/settings-schema.json" ]] || fail "a refused install wrote an export"

# A pack whose exports were edited after packing: install refuses.
make_tree "$tmp/edited"
echo "edited" > "$tmp/pack/plans/cmux-next/links.json"
if "$tmp/edited/scripts/cmux-next/swift-exports-cache.sh" install "$tmp/pack" 2>"$tmp/err"; then
  fail "install accepted an edited pack"
fi
grep -q "digest" "$tmp/err" || fail "refusal does not name the digest"

echo "swift-exports-cache: ok"
