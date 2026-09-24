#!/usr/bin/env bash
# Regression test for the Debug compilation cache that nightly seeds from main
# and the pull request compile admission job restores.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_FILE="$ROOT_DIR/.github/workflows/ci-macos.yml"
NIGHTLY_FILE="$ROOT_DIR/.github/workflows/nightly.yml"
SCRIPT="$ROOT_DIR/scripts/ci/compile-app-host-test-product.sh"

# Prints one job's body.
job_body() {
  awk -v job="$2" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job { print }
  ' "$1"
}

ADMISSION="$(job_body "$CI_FILE" "macos-compile-admission")"
SEEDER="$(job_body "$NIGHTLY_FILE" "refresh-test-compilation-cache")"

if [ -z "$ADMISSION" ] || [ -z "$SEEDER" ]; then
  echo "FAIL: expected ci-macos.yml macos-compile-admission and nightly.yml refresh-test-compilation-cache"
  exit 1
fi

# A cache entry is keyed on the whole compiler invocation. If either job builds
# the product by hand, the two drift and the seed stops hitting without any
# job failing.
for pair in "admission:$ADMISSION" "seeder:$SEEDER"; do
  name="${pair%%:*}"
  body="${pair#*:}"
  if ! grep -Fq 'scripts/ci/compile-app-host-test-product.sh canonical-build' <<<"$body" \
    || ! grep -Fq 'scripts/ci/compile-app-host-test-product.sh canonical-fingerprint' <<<"$body"; then
    echo "FAIL: the $name job must build and fingerprint through scripts/ci/compile-app-host-test-product.sh"
    exit 1
  fi
  if grep -Eq 'xcodebuild .*build-for-testing|^[[:space:]]+build-for-testing' <<<"$body"; then
    echo "FAIL: the $name job must not hand-roll the app-host test build; change scripts/ci/compile-app-host-test-product.sh"
    exit 1
  fi
done
echo "PASS: admission and the seeder build the app-host test product through one script"

# Pools may differ: the executable canonical recipe test checks absolute paths.

# The build paths are part of every cache entry, so both jobs must use the
# same ones.
for line in \
  'CMUX_COMPILE_ADMISSION_DERIVED_DATA=${CMUX_CI_CANONICAL_ROOT:-/private/tmp/cmux-ci}/derived-data-compile-admission' \
  'CMUX_COMPILE_ADMISSION_CAS=${CMUX_CI_CANONICAL_ROOT:-/private/tmp/cmux-ci}/compile-admission-cas'; do
  if ! grep -Fq "$line" <<<"$ADMISSION" || ! grep -Fq "$line" <<<"$SEEDER"; then
    echo "FAIL: admission and the seeder must both set $line"
    exit 1
  fi
done
echo "PASS: admission and the seeder build from the same paths"

KEY_PREFIX='xcode-compilation-test-${{ runner.os }}-${{ runner.arch }}-${{ steps.compilation-cache-key.outputs.fingerprint }}-'
if ! grep -Fq -- "$KEY_PREFIX" "$NIGHTLY_FILE" \
  || grep -F 'xcode-compilation-test-' "$NIGHTLY_FILE" | grep -vqF -- "$KEY_PREFIX"; then
  echo "FAIL: nightly.yml must key the test compilation cache on the canonical fingerprint"
  exit 1
fi
echo "PASS: the seeder keys the test compilation cache on the canonical fingerprint"

# Pull-request compile admission does not restore the test compilation cache.
# Swift keys every compile job on its whole module, so the one-module `cmux`
# app target (and cmuxUITests) missed on every file: 581 of 581 and 566 of 566
# in two sampled admission logs on 2026-09-24, although the key, path and
# Xcode matched the seed exactly. Only modules unchanged since the six-hourly
# seed hit, and those are what the adopted DerivedData seed already leaves
# up to date. The restore cost 13-43 s and a 932 MB download on every run.
# Admission still computes the fingerprint: the DerivedData seed is keyed on it.
if grep -Fq 'xcode-compilation-test-' <<<"$ADMISSION" \
  || grep -Eq '^      - name: Restore test compilation cache' <<<"$ADMISSION"; then
  echo "FAIL: macos-compile-admission must not restore the test compilation cache;"
  echo "      the app target misses on every file and the DerivedData seed covers the rest"
  exit 1
fi
if ! grep -Fq 'steps.compilation-cache-key.outputs.fingerprint' <<<"$ADMISSION"; then
  echo "FAIL: macos-compile-admission must still key the DerivedData seed on the canonical fingerprint"
  exit 1
fi
echo "PASS: pull requests skip the test compilation cache and keep the fingerprint for the seed"

if ! awk '
  /^      - name: Restore test compilation cache/ { step="restore" }
  /^      - name: Bound test compilation cache size/ { step="bound" }
  /^      - name: Save test compilation cache/ { step="save" }
  step == "restore" && /id: compilation-cache-restore/ { saw_restore_id=1 }
  step == "restore" && /needs\.decide\.outputs\.head_sha/ { saw_revision_key=1 }
  step == "bound" && /prune-xcode-compilation-cache\.py/ { saw_prune=1 }
  step == "save" && /uses: (actions\/cache\/save@|\.\/\.github\/actions\/cache-save$)/ { saw_save=1 }
  step == "save" && /cache-hit != '\''true'\'' && steps\.compilation-cache-bound\.outputs\.save == '\''true'\''/ { saw_gate=1 }
  END { exit !(saw_restore_id && saw_revision_key && saw_prune && saw_save && saw_gate) }
' <<<"$SEEDER"; then
  echo "FAIL: refresh-test-compilation-cache must key the seed by main revision, prune it, and save only a new, bounded cache"
  exit 1
fi
echo "PASS: the seeder rolls the cache forward by main revision and bounds what it saves"

# The seed must come from one clean build. The seeder used to restore its own
# last seed by prefix, so each run stacked another build's objects onto the
# CAS; Xcode keeps the primary generation and the upstream it faults from, and
# that pair crossed the 5 GiB save bound on 2026-09-22 after climbing 3.5 -> 5.0
# GiB in eight runs. Past the bound nothing is saved, so the next run restores
# the same older entry and lands past it again and the seed freezes for good.
# A cold build covers all of main anyway, and it measured smaller (3.5 GiB) and
# faster (18 min, against 19-25 warm) than a stacked one.
if awk '
  /^      - name: / { step = $0 }
  step ~ /Restore test compilation cache/ && /^[[:space:]]+restore-keys:/ { found = 1 }
  END { exit !found }
' <<<"$SEEDER"; then
  echo "FAIL: refresh-test-compilation-cache must not restore an earlier seed by prefix:"
  echo "      stacking builds onto one CAS grows it past the save bound, and then the seed freezes."
  exit 1
fi
echo "PASS: the seeder seeds from one clean build"

if ! grep -Eq "if: github\.event_name == 'schedule'" <<<"$SEEDER"; then
  echo "FAIL: refresh-test-compilation-cache must stay on the cache-warming schedule so it does not take a macOS slot per merge"
  exit 1
fi
echo "PASS: the seeder runs on the cache-warming schedule"

# Exercise the script against a stub xcodebuild.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"
cat > "$TMP_DIR/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-version" ]; then
  echo "Xcode ${STUB_XCODE_VERSION:-26.3}"
  exit 0
fi
printf '%s\n' "$@" >> "$STUB_XCODEBUILD_ARGS"
echo "---" >> "$STUB_XCODEBUILD_ARGS"
# Resolution fails for the first STUB_RESOLVE_FAILS_UNTIL attempts, then reports
# success, and writes the binary artifacts only from the attempt named by
# STUB_RESOLVE_ARTIFACTS_FROM.
packages=""
scheme=""
resolving=0
skip_updates=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -scheme) scheme="$2"; shift ;;
    -clonedSourcePackagesDirPath) packages="$2"; shift ;;
    -resolvePackageDependencies) resolving=1 ;;
    -skipPackageUpdates) skip_updates=1 ;;
  esac
  shift
done
if [ -n "$scheme" ]; then echo "build output for $scheme"; fi
if [ "$resolving" -eq 1 ]; then
  echo x >> "$STUB_RESOLVE_ATTEMPTS"
  # A package cache missing a pinned revision fails an offline resolve.
  if [ "$skip_updates" -eq 1 ] && [ -n "${STUB_SKIP_UPDATES_FAILS:-}" ]; then
    exit 74
  fi
  if [ "$(wc -l < "$STUB_RESOLVE_ATTEMPTS")" -le "${STUB_RESOLVE_FAILS_UNTIL:-0}" ]; then
    # A failed resolve that leaves a partial clone behind.
    mkdir -p "$packages/checkouts/partial-clone"
    exit 74
  fi
  if [ "$(wc -l < "$STUB_RESOLVE_ATTEMPTS")" -ge "${STUB_RESOLVE_ARTIFACTS_FROM:-1}" ]; then
    mkdir -p "$packages/artifacts/sparkle/Sparkle/Sparkle.xcframework" \
      "$packages/artifacts/sentry-cocoa/Sentry/Sentry.xcframework"
  fi
fi
STUB
chmod +x "$TMP_DIR/bin/xcodebuild"
export STUB_RESOLVE_ATTEMPTS="$TMP_DIR/resolve-attempts.txt"
export STUB_XCODEBUILD_ARGS="$TMP_DIR/args.txt"

run_script() {
  (cd "$TMP_DIR/work" && PATH="$TMP_DIR/bin:$PATH" "$SCRIPT" "$@")
}

first="$(run_script fingerprint /tmp/derived-a)"
again="$(run_script fingerprint /tmp/derived-a)"
other_path="$(run_script fingerprint /tmp/derived-b)"
other_xcode="$(STUB_XCODE_VERSION=26.5 run_script fingerprint /tmp/derived-a)"
if [ "$first" != "$again" ] || [ "$first" = "$other_path" ] || [ "$first" = "$other_xcode" ] || [ -z "$first" ]; then
  echo "FAIL: the fingerprint must be stable and must change with the build path and the toolchain"
  exit 1
fi
echo "PASS: the fingerprint follows the build path and the toolchain"

run_script build "$TMP_DIR/derived" "$TMP_DIR/packages" "$TMP_DIR/cas" "$TMP_DIR/build.log" >/dev/null
for expected in \
  cmux \
  cmux-unit \
  cmux-numeric-locale \
  build-for-testing \
  -showBuildTimingSummary \
  COMPILATION_CACHE_ENABLE_CACHING=YES \
  "COMPILATION_CACHE_CAS_PATH=$TMP_DIR/cas" \
  "$TMP_DIR/derived" \
  "$TMP_DIR/packages"; do
  if ! grep -Fxq -- "$expected" "$STUB_XCODEBUILD_ARGS"; then
    echo "FAIL: the build must pass $expected to xcodebuild"
    exit 1
  fi
done
if [ "$(grep -c '^---$' "$STUB_XCODEBUILD_ARGS")" -ne 3 ] || [ ! -d "$TMP_DIR/cas" ]; then
  echo "FAIL: the build must run all three schemes against an existing CAS directory"
  exit 1
fi
# `build` compiles no test files: the cmux-unit scheme marks cmuxTests
# buildForRunning=NO.
if grep -Fxq -- build "$STUB_XCODEBUILD_ARGS"; then
  echo "FAIL: the app-host test product must be compiled with build-for-testing, not build"
  exit 1
fi
echo "PASS: the build compiles all three schemes for testing with the compilation cache on"
if ! grep -Fxq 'build output for cmux' "$TMP_DIR/derived/cmux-build.log" \
  || grep -Fq 'build output for cmux-unit' "$TMP_DIR/derived/cmux-build.log"; then
  echo "FAIL: the warning-budget log must retain only app/UI build output"
  exit 1
fi
echo "PASS: app/UI warnings are captured separately from unit-test warnings"


# A restored package cache can make resolution succeed without the binary
# artifacts, and the build cannot resolve again.
: > "$STUB_RESOLVE_ATTEMPTS"
mkdir -p "$TMP_DIR/stale-packages/checkouts"
if ! STUB_RESOLVE_ARTIFACTS_FROM=2 run_script resolve "$TMP_DIR/derived" "$TMP_DIR/stale-packages" >/dev/null 2>&1 \
  || [ "$(wc -l < "$STUB_RESOLVE_ATTEMPTS")" -ne 2 ] \
  || [ -d "$TMP_DIR/stale-packages/checkouts" ]; then
  echo "FAIL: resolve must clear the package cache and retry when the binary artifacts are missing"
  exit 1
fi
: > "$STUB_RESOLVE_ATTEMPTS"
if ! STUB_RESOLVE_FAILS_UNTIL=1 STUB_RESOLVE_ARTIFACTS_FROM=2 run_script resolve "$TMP_DIR/derived" "$TMP_DIR/failed-packages" >/dev/null 2>&1 \
  || [ "$(wc -l < "$STUB_RESOLVE_ATTEMPTS")" -ne 2 ] \
  || [ -d "$TMP_DIR/failed-packages/checkouts/partial-clone" ]; then
  echo "FAIL: resolve must clear the partial clone a failed attempt leaves and retry"
  exit 1
fi
: > "$STUB_RESOLVE_ATTEMPTS"
if STUB_RESOLVE_ARTIFACTS_FROM=9 run_script resolve "$TMP_DIR/derived" "$TMP_DIR/never-packages" >/dev/null 2>&1 \
  || [ "$(wc -l < "$STUB_RESOLVE_ATTEMPTS")" -ne 3 ]; then
  echo "FAIL: resolve must fail after three attempts without the binary artifacts"
  exit 1
fi
for name_and_body in "macos-compile-admission:$ADMISSION" "refresh-test-compilation-cache:$SEEDER"; do
  if ! grep -Fq 'scripts/ci/compile-app-host-test-product.sh canonical-resolve' <<<"${name_and_body#*:}"; then
    echo "FAIL: the ${name_and_body%%:*} job must resolve packages through scripts/ci/compile-app-host-test-product.sh"
    exit 1
  fi
done
echo "PASS: resolve retries until the binary artifacts exist, in both jobs"

# An exact `spm-` hit was saved after a successful resolve of this same
# Package.resolved, so its repositories already hold every pinned revision.
# Resolving it must not fetch every package remote again. Anything short of an
# exact hit, or an offline resolve that fails, keeps the normal resolve.
: > "$STUB_RESOLVE_ATTEMPTS"
: > "$STUB_XCODEBUILD_ARGS"
mkdir -p "$TMP_DIR/exact-packages/checkouts/kept"
if ! CMUX_CI_SWIFTPM_CACHE_EXACT_HIT=true run_script resolve "$TMP_DIR/derived" "$TMP_DIR/exact-packages" >/dev/null 2>&1 \
  || [ "$(wc -l < "$STUB_RESOLVE_ATTEMPTS")" -ne 1 ] \
  || ! grep -Fxq -- -skipPackageUpdates "$STUB_XCODEBUILD_ARGS"; then
  echo "FAIL: an exact package-cache hit must resolve once without fetching package remotes"
  exit 1
fi
: > "$STUB_RESOLVE_ATTEMPTS"
: > "$STUB_XCODEBUILD_ARGS"
if ! CMUX_CI_SWIFTPM_CACHE_EXACT_HIT=true STUB_SKIP_UPDATES_FAILS=1 run_script resolve "$TMP_DIR/derived" "$TMP_DIR/exact-packages" >/dev/null 2>&1 \
  || [ "$(wc -l < "$STUB_RESOLVE_ATTEMPTS")" -ne 2 ] \
  || [ "$(grep -cFx -- -skipPackageUpdates "$STUB_XCODEBUILD_ARGS")" -ne 1 ] \
  || [ ! -d "$TMP_DIR/exact-packages/checkouts/kept" ]; then
  echo "FAIL: a failed offline resolve must fall back to a normal resolve of the same restored cache"
  exit 1
fi
for hit in "" false; do
  : > "$STUB_RESOLVE_ATTEMPTS"
  : > "$STUB_XCODEBUILD_ARGS"
  if ! CMUX_CI_SWIFTPM_CACHE_EXACT_HIT="$hit" run_script resolve "$TMP_DIR/derived" "$TMP_DIR/prefix-packages" >/dev/null 2>&1 \
    || grep -Fxq -- -skipPackageUpdates "$STUB_XCODEBUILD_ARGS"; then
    echo "FAIL: a prefix restore or a miss must fetch package remotes as before (hit='$hit')"
    exit 1
  fi
done
if ! awk '
  /^      - name: / { step = $0 }
  step ~ /name: Cache Swift packages$/ && /^        id: swift-package-cache$/ { id = 1 }
  step ~ /name: Resolve Swift packages$/ && /CMUX_CI_SWIFTPM_CACHE_EXACT_HIT: \$\{\{ steps\.swift-package-cache\.outputs\.cache-hit \}\}/ { wired = 1 }
  step ~ /name: Resolve Swift packages$/ && /CMUX_CI_MOVE_SOURCE_PACKAGES: "1"/ { moved = 1 }
  END { exit !(id && wired && moved) }
' <<<"$ADMISSION"; then
  echo "FAIL: macos-compile-admission must pass the package cache's exact-hit output to resolve and move, not copy, the cache"
  exit 1
fi
echo "PASS: an exact package-cache hit resolves without remote fetches, with a normal-resolve fallback"

if run_script bogus >/dev/null 2>&1 || run_script build only-one-arg >/dev/null 2>&1; then
  echo "FAIL: the script must reject unknown commands and short argument lists"
  exit 1
fi
echo "PASS: the script rejects bad usage"
