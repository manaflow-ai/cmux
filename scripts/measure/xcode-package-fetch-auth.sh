#!/usr/bin/env bash
# Whether xcodebuild's package fetches carry a github.com header given through GIT_CONFIG_* in the
# environment (scripts/ci/swiftpm-binary-module-guard.sh, github_git_auth_env). Resolves one small
# public package (swift-atomics) into a new DerivedData three ways: with no header (must resolve),
# with a header holding a bogus token (must be refused by GitHub: proof the header reached git),
# and with the header github_git_auth_env makes from CMUX_GITHUB_GIT_TOKEN when that is set
# (must resolve). Prints one line per arm; exit 0 when every arm behaved so.
#   cmux-ci run --class light --script scripts/measure/xcode-package-fetch-auth.sh --ref SHA
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
repo="$PWD"
if [ -z "${DEVELOPER_DIR:-}" ]; then
  pin="$(awk '$1 == "26" { print $2 }' scripts/ci/xcode-pins.txt)"
  export DEVELOPER_DIR="/Applications/Xcode_${pin}.app/Contents/Developer"
fi
echo "Xcode: $DEVELOPER_DIR"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/p/Sources/P"
cat > "$tmp/p/Package.swift" <<'P'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "P",
  products: [.library(name: "P", targets: ["P"])],  // xcodebuild makes scheme P only for a product
  dependencies: [.package(url: "https://github.com/apple/swift-atomics.git", exact: "1.2.0")],
  targets: [.target(name: "P", dependencies: [.product(name: "Atomics", package: "swift-atomics")])])
P
echo 'import Atomics' > "$tmp/p/Sources/P/P.swift"
resolve() {  # ARM [ENV...]: exit status of a resolve into a new DerivedData
  local arm="$1"; shift
  (cd "$tmp/p" && env -u GIT_CONFIG_COUNT "$@" xcodebuild -scheme P -derivedDataPath "$tmp/dd-$arm" \
    -packageCachePath "$tmp/cache-$arm" -resolvePackageDependencies) > "$tmp/$arm.log" 2>&1
}
ok=1
resolve none; s=$?
echo "no header: exit $s (want 0)"; [ "$s" -eq 0 ] || { ok=0; tail -5 "$tmp/none.log"; }
bogus="AUTHORIZATION: basic $(printf 'x-access-token:bogus' | base64 | tr -d '\n')"
resolve bogus GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader GIT_CONFIG_VALUE_0="$bogus"; s=$?
# git answers GitHub's 401 by asking for credentials, which a job has no terminal for: that line is the refusal too
refusal="$(grep -m1 -oE 'returned error: [0-9]+|Authentication failed|Invalid username or token|could not read Username' "$tmp/bogus.log")"
echo "bogus token header: exit $s, ${refusal:-no refusal} (want a refusal)"
[ "$s" -ne 0 ] && [ -n "$refusal" ] || { ok=0; tail -5 "$tmp/bogus.log"; }
if [ -n "${CMUX_GITHUB_GIT_TOKEN:-}" ]; then
  (# shellcheck source=scripts/ci/swiftpm-binary-module-guard.sh
   source "$repo/scripts/ci/swiftpm-binary-module-guard.sh"; github_git_auth_env
   cd "$tmp/p" && xcodebuild -scheme P -derivedDataPath "$tmp/dd-token" -packageCachePath "$tmp/cache-token" \
     -resolvePackageDependencies) > "$tmp/token.log" 2>&1; s=$?
  echo "job token header: exit $s (want 0)"; [ "$s" -eq 0 ] || { ok=0; tail -5 "$tmp/token.log"; }
else
  echo "job token header: skipped (no CMUX_GITHUB_GIT_TOKEN)"
fi
[ "$ok" -eq 1 ] && echo "xcode-package-fetch-auth: ok" || { echo "xcode-package-fetch-auth: FAIL"; exit 1; }
