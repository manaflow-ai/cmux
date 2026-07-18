#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/nightly-perf-benchmark.yml"
RUNNER="$ROOT_DIR/scripts/ci/benchmark-nightly-build.sh"
UUID_KEYS="$ROOT_DIR/scripts/ci/macho-uuid-keys.sh"
NIGHTLY="$ROOT_DIR/.github/workflows/nightly.yml"

if [ ! -f "$WORKFLOW" ] || [ ! -x "$RUNNER" ]; then
  echo "FAIL: nightly performance benchmark workflow and executable runner are required" >&2
  exit 1
fi

for scenario in universal-wmo universal-singlefile arm64-wmo x86_64-wmo; do
  if ! grep -Fq "$scenario" "$WORKFLOW"; then
    echo "FAIL: missing benchmark scenario: $scenario" >&2
    exit 1
  fi
done

if [ ! -x "$UUID_KEYS" ]; then
  echo "FAIL: normalized Mach-O UUID helper is required" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cat > "$tmp_dir/dwarfdump" <<'EOF'
#!/usr/bin/env bash
printf 'UUID: AAAA-BBBB (arm64) %s\n' "$2"
printf 'UUID: CCCC-DDDD (x86_64) %s\n' "$2"
EOF
chmod +x "$tmp_dir/dwarfdump"
CMUX_DWARFDUMP_TOOL="$tmp_dir/dwarfdump" "$UUID_KEYS" /one/cmux > "$tmp_dir/one"
CMUX_DWARFDUMP_TOOL="$tmp_dir/dwarfdump" "$UUID_KEYS" /different/cmux > "$tmp_dir/two"
if ! cmp -s "$tmp_dir/one" "$tmp_dir/two"; then
  echo "FAIL: Mach-O UUID comparison must ignore differing file paths" >&2
  exit 1
fi
if grep -Fq "grep -q UUID" "$RUNNER"; then
  echo "FAIL: normalized UUID intersections must not search for removed labels" >&2
  exit 1
fi

for requirement in \
  'CMUX_CI_XCODE_APP_MACOS_26' \
  'blacksmith-6vcpu-macos-26' \
  './scripts/select-ci-xcode.sh' \
  './scripts/download-prebuilt-ghosttykit.sh' \
  './scripts/ci/benchmark-nightly-build.sh' \
  'actions/upload-artifact@'; do
  if ! grep -Fq "$requirement" "$WORKFLOW"; then
    echo "FAIL: benchmark workflow missing: $requirement" >&2
    exit 1
  fi
done

for requirement in \
  'SWIFT_COMPILATION_MODE=' \
  'SWIFT_OPTIMIZATION_LEVEL=-O' \
  'COMPILATION_CACHE_ENABLE_CACHING=YES' \
  'COMPILER_INDEX_STORE_ENABLE=NO' \
  'CODE_SIGNING_ALLOWED=NO' \
  'lipo' \
  'macho-uuid-keys.sh' \
  'strip-release-bundle.sh' \
  'smoke-launch-macos-app.sh'; do
  if ! grep -Fq "$requirement" "$RUNNER"; then
    echo "FAIL: benchmark runner missing safety or measurement check: $requirement" >&2
    exit 1
  fi
done

for requirement in \
  'notarization_mode:' \
  'DMG_ONLY_EXPERIMENT' \
  'DMG-only notarization experiment is forbidden on main' \
  'if [ "$DMG_ONLY_EXPERIMENT" != "true" ]' \
  'xcrun stapler staple "$app_path"'; do
  if ! grep -Fq "$requirement" "$NIGHTLY"; then
    echo "FAIL: nightly DMG-only notarization experiment missing safety check: $requirement" >&2
    exit 1
  fi
done

echo "PASS: nightly performance benchmark preserves release constraints"
