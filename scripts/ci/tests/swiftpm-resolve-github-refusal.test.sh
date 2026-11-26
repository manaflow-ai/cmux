#!/usr/bin/env bash
# scripts/ci/tests/swiftpm-resolve-github-refusal.test.sh: swiftpm_resolve_package
# (scripts/ci/swiftpm-binary-module-guard.sh) returns 75 (fetch failed, no verdict) when GitHub
# refuses the worker with 403 or 429 on every try, and 1 (the commit's defect) on a 404.
#
# Step 0787f5e4 (ultra2, 2026-11-26): every github.com fetch from the worker got 403, the public
# apple/swift-crypto clone and the release-zip downloads alike; the resolve was read as the commit's
# failure, so a kit suite went red (exit 1) with no test run. No network, Xcode or real SwiftPM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/pkg"
printf '// swift-tools-version:6.0\n' > "$tmp/pkg/Package.swift"
cat > "$tmp/bin/swift" <<'SWIFT'
#!/usr/bin/env bash
case "$1 $2" in
  "package resolve")
    echo "Fetching https://github.com/apple/swift-crypto.git from cache"
    echo "error: Failed to clone repository https://github.com/apple/swift-crypto.git:"
    echo "    fatal: unable to access 'https://github.com/apple/swift-crypto.git/': $FAKE_ERROR"
    exit 1
    ;;
  *) echo "swift 6.2 (fake)" ;;
esac
SWIFT
chmod +x "$tmp/bin/swift"

export PATH="$tmp/bin:$PATH" CMUX_SWIFTPM_SEED_ARTIFACTS=0 CMUX_SWIFTPM_RESOLVE_RETRY_DELAYS="0"
# shellcheck source=scripts/ci/swiftpm-binary-module-guard.sh
source "$ROOT/scripts/ci/swiftpm-binary-module-guard.sh"

expect() {
  local want="$1" error="$2" code=0
  FAKE_ERROR="$error" swiftpm_resolve_package "$tmp/pkg" > "$tmp/out.log" 2>&1 || code=$?
  if [ "$code" -ne "$want" ]; then
    echo "FAIL: '$error' gave $code, want $want:"
    sed 's/^/  | /' "$tmp/out.log"
    exit 1
  fi
}

expect 75 "The requested URL returned error: 403"
expect 75 "The requested URL returned error: 429"
expect 75 "The requested URL returned error: 502"
expect 1 "The requested URL returned error: 404"
expect 1 "Authentication failed"

echo "ok: a GitHub 403/429 on every resolve try is a fetch failure (75); a 404 stays the commit's (1)"
