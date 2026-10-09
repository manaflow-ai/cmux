#!/usr/bin/env bash
# Compiles the String Catalogs that `swift build` copied verbatim into the
# CmuxNext resource bundles into <lang>.lproj/*.strings(dict), as Xcode does.
# Without this, `swift test` sees no compiled tables: lookups fall back to
# their English default values and plural rules are lost.
# Run from Packages/macOS/CmuxNext after `swift build --build-tests`.
set -euo pipefail
# A sanitizer lane (package-test-lane.sh, CMUX_SWIFT_SANITIZE) builds into its own scratch folder.
scratch=()
if [ -n "${CMUX_SWIFT_SANITIZE:-}" ]; then scratch=(--scratch-path ".build-sanitize-$CMUX_SWIFT_SANITIZE"); fi
bin="$(swift build -c "${CMUX_SWIFT_SUITE_CONFIGURATION:-debug}" ${scratch[@]+"${scratch[@]}"} --show-bin-path)"
count=0
while IFS= read -r -d '' catalog; do
  xcrun xcstringstool compile "$catalog" --output-directory "$(dirname "$catalog")"
  count=$((count + 1))
done < <(find "$bin" -path '*.bundle/*' -name '*.xcstrings' -print0)
echo "compiled $count string catalogs"
