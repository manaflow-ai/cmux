#!/usr/bin/env bash
# Compiles the String Catalogs that `swift build` copied verbatim into the
# CmuxNext resource bundles into <lang>.lproj/*.strings(dict), as Xcode does.
# Without this, `swift test` sees no compiled tables: lookups fall back to
# their English default values and plural rules are lost.
# Run from Packages/macOS/CmuxNext after `swift build --build-tests`.
# CMUX_SWIFT_BIN_PATH names the build products folder when the caller already
# knows it (run-swift-testing-suites.sh), so this asks SwiftPM nothing and can
# run beside another SwiftPM command. The catalogs compile in parallel, one
# xcstringstool per CPU (100 catalogs took 5-12 s one at a time, hq11 2026-10-09).
set -euo pipefail
# A sanitizer lane (package-test-lane.sh, CMUX_SWIFT_SANITIZE) builds into its own scratch folder.
scratch=()
if [ -n "${CMUX_SWIFT_SANITIZE:-}" ]; then scratch=(--scratch-path ".build-sanitize-$CMUX_SWIFT_SANITIZE"); fi
bin="${CMUX_SWIFT_BIN_PATH:-}"
if [ -z "$bin" ]; then
  bin="$(swift build -c "${CMUX_SWIFT_SUITE_CONFIGURATION:-debug}" ${scratch[@]+"${scratch[@]}"} --show-bin-path)"
fi
jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
catalogs=()
while IFS= read -r -d '' catalog; do
  catalogs+=("$catalog")
done < <(find "$bin" -path '*.bundle/*' -name '*.xcstrings' -print0)
if [ "${#catalogs[@]}" -gt 0 ]; then
  # xargs exits nonzero when any compile failed, which fails this script.
  printf '%s\0' "${catalogs[@]}" \
    | xargs -0 -n 1 -P "$jobs" sh -c 'xcrun xcstringstool compile "$1" --output-directory "$(dirname "$1")"' sh
fi
echo "compiled ${#catalogs[@]} string catalogs"
