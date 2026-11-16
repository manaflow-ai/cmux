#!/usr/bin/env bash
# The built-in uBlock Origin's manifest pin exists twice: fetch-ublock.sh
# (staging refuses another manifest) and CEFBuiltInExtensions.swift (the agent
# extension guard trusts only a built-in copy with this manifest). A version
# bump that changes one and not the other would make every agent page read
# refused again; this keeps them equal.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
script=$(sed -n 's/^UBLOCK_MANIFEST_SHA256="\([0-9a-f]\{64\}\)"$/\1/p' "$ROOT/scripts/cmux-next/fetch-ublock.sh")
swift=$(sed -n 's/.*static let adBlockerManifestSHA256 = "\([0-9a-f]\{64\}\)".*/\1/p' \
  "$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFBuiltInExtensions.swift")
[[ -n "$script" && "$script" == "$swift" ]] || { echo "uBlock Origin manifest pins differ: fetch-ublock.sh '$script', CEFBuiltInExtensions.swift '$swift'" >&2; exit 1; }
echo "ublock pin test: ok ($script)"

# Version floor: uBlock Origin 1.75.2 and older let any website frame and drive
# the element picker and add trusted filters, a universal XSS
# (GHSA-cmqw-9r2w-6wv2, https://github.com/gorhill/uBlock/security/advisories/GHSA-cmqw-9r2w-6wv2;
# fixed in 1.75.4, hardened in 1.76.0). No pin may go below the fixed release:
# the built-in copy, the version the notices name, and the extension test store's CRX.
# The floor lives in CEFBuiltInExtensions.adBlockerMinimumVersion (it also retires a person's
# own older copy at start); it may not drop below the fixed release either.
UBLOCK_FLOOR=$(sed -n 's/.*static let adBlockerMinimumVersion = "\([0-9.]*\)".*/\1/p' \
  "$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFBuiltInExtensions.swift")
[[ -n "$UBLOCK_FLOOR" ]] || { echo "no adBlockerMinimumVersion in CEFBuiltInExtensions.swift" >&2; exit 1; }
version=$(sed -n 's/^UBLOCK_VERSION="\([0-9.]*\)"$/\1/p' "$ROOT/scripts/cmux-next/fetch-ublock.sh")
at_least() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" == "$2" ]]; }
at_least "$UBLOCK_FLOOR" 1.75.4 || { echo "adBlockerMinimumVersion $UBLOCK_FLOOR is below the fixed 1.75.4" >&2; exit 1; }
[[ -n "$version" ]] || { echo "no UBLOCK_VERSION in fetch-ublock.sh" >&2; exit 1; }
at_least "$version" "$UBLOCK_FLOOR" || { echo "uBlock Origin $version is below $UBLOCK_FLOOR (GHSA-cmqw-9r2w-6wv2 element picker UXSS)" >&2; exit 1; }
crx=$(sed -n 's#.*gorhill/uBlock/releases/download/\([0-9.]*\)/uBlock0_.*\.crx".*#\1#p' "$ROOT/scripts/cmux-next/ext-store/extensions.json")
[[ -n "$crx" ]] && at_least "$crx" "$UBLOCK_FLOOR" || { echo "ext-store uBlock Origin CRX '$crx' is below $UBLOCK_FLOOR" >&2; exit 1; }
for notice in THIRD_PARTY_LICENSES.md scripts/cmux-next/notices/hand-written.md; do
  grep -q "bundles the uBlock Origin $version release build" "$ROOT/$notice" || { echo "$notice does not name uBlock Origin $version" >&2; exit 1; }
done
echo "ublock version floor test: ok ($version >= $UBLOCK_FLOOR)"
