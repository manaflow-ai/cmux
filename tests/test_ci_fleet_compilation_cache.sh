#!/usr/bin/env bash
# Regression guard for the fleet compiler-cache path used by PR admission.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/compile-app-host-test-product.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/ci-macos.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The compiler must emit the Xcode 26.6 cache remarks and use the supported
# prefix/project mapping settings so a fleet CAS entry can be read from another
# runner without enabling the crash-prone DerivedData mapping.
for setting in \
  'COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES' \
  'SWIFT_ENABLE_PREFIX_MAPPING=YES' \
  'CLANG_ENABLE_PREFIX_MAPPING=YES' \
  'SWIFT_ENABLE_PROJECT_PREFIX_MAPPING=YES' \
  'CLANG_ENABLE_PROJECT_PREFIX_MAPPING=YES'; do
  grep -Fq "$setting" "$SCRIPT" || fail "$SCRIPT must pass $setting"
done

grep -Fq 'fleet-cas-settings.sh' "$SCRIPT" || fail 'compile script must query fleet-cas settings'
grep -Fq 'COMPILATION_CACHE_REMOTE_SERVICE_PATH' "$SCRIPT" || fail 'compile script must pass the fleet CAS socket setting'
grep -Fq 'fleet_plugin_ok' "$SCRIPT" || fail 'compile script must require a healthy fleet plugin response before switching CAS'
grep -Fq 'fleet_remote_ok' "$SCRIPT" || fail 'compile script must require a healthy fleet remote response before switching CAS'

grep -Fq 'glaeda-compile-telemetry.json' "$WORKFLOW" || fail 'compile admission must publish the host telemetry sidecar'

echo 'PASS: fleet compiler-cache settings and host telemetry are wired'
