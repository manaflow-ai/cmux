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
