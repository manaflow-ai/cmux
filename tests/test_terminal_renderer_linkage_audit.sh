#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-renderer-linkage-audit.XXXXXX")"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

FAKE_BIN="$TEST_ROOT/bin"
XCFRAMEWORK="$TEST_ROOT/GhosttySceneRendererKit.xcframework"
BINARY="$TEST_ROOT/cmux-terminal-renderer"
ARCHIVE="$XCFRAMEWORK/macos-arm64/libghostty-scene.a"
HEADERS="$XCFRAMEWORK/macos-arm64/Headers"
mkdir -p "$FAKE_BIN" "$HEADERS"
: > "$BINARY"
: > "$ARCHIVE"

cat > "$HEADERS/ghostty_scene.h" <<'EOF'
int ghostty_scene_init(void);
void *ghostty_config_new(void);
void ghostty_config_free(void);
void ghostty_config_load_string(void);
void ghostty_config_finalize(void);
void ghostty_config_diagnostics_count(void);
void ghostty_scene_renderer_new(void);
void ghostty_scene_renderer_destroy(void);
void ghostty_scene_renderer_get_metrics(void);
void ghostty_scene_renderer_apply(void);
void ghostty_scene_renderer_render(void);
void ghostty_scene_renderer_should_animate(void);
void ghostty_scene_renderer_borrow_iosurface(void);
void ghostty_scene_renderer_release_frame(void);
EOF

cat > "$HEADERS/module.modulemap" <<'EOF'
module GhosttySceneRendererKit { header "ghostty_scene.h" export * }
EOF

cat > "$FAKE_BIN/file" <<'EOF'
#!/usr/bin/env bash
printf '%s: Mach-O 64-bit executable arm64\n' "$1"
EOF

cat > "$FAKE_BIN/nm" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -gUj "*)
    cat <<'SYMBOLS'
_ghostty_scene_init
_ghostty_config_new
_ghostty_config_free
_ghostty_config_load_string
_ghostty_config_finalize
_ghostty_config_diagnostics_count
_ghostty_scene_renderer_new
_ghostty_scene_renderer_destroy
_ghostty_scene_renderer_get_metrics
_ghostty_scene_renderer_apply
_ghostty_scene_renderer_render
_ghostty_scene_renderer_should_animate
_ghostty_scene_renderer_borrow_iosurface
_ghostty_scene_renderer_release_frame
SYMBOLS
    ;;
  *" -uj "*)
    case "${CMUX_LINKAGE_FIXTURE_CASE:-}" in
      dlopen) printf '_dlopen\n' ;;
      dlsym) printf '_dlsym\n' ;;
    esac
    ;;
  *" -u -A "*)
    case "${CMUX_LINKAGE_FIXTURE_CASE:-}" in
      dlopen) printf '%s:fixture.o:         U _dlopen\n' "$3" ;;
      dlsym) printf '%s:fixture.o:         U _dlsym\n' "$3" ;;
    esac
    ;;
  *" -a "*)
    case "${CMUX_LINKAGE_FIXTURE_CASE:-}" in
      objc-bundle-load) printf '                 U _OBJC_CLASS_$_NSBundle\n' ;;
      swift-bundle-load) printf '                 U _$s10Foundation6BundleC4loadSbyF\n' ;;
    esac
    ;;
esac
EOF

cat > "$FAKE_BIN/otool" <<'EOF'
#!/usr/bin/env bash
printf '%s:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n' "${2:-fixture}"
EOF

cat > "$FAKE_BIN/strings" <<'EOF'
#!/usr/bin/env bash
if [[ "${CMUX_LINKAGE_FIXTURE_CASE:-}" == "objc-bundle-load" ]]; then
  printf 'loadAndReturnError:\n'
fi
EOF

for command in ar clang; do
  cat > "$FAKE_BIN/$command" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
chmod +x "$FAKE_BIN"/*

assert_rejected() {
  local fixture_case="$1"
  local diagnostic="$2"
  local output="$TEST_ROOT/$fixture_case.log"
  if CMUX_LINKAGE_FIXTURE_CASE="$fixture_case" \
      PATH="$FAKE_BIN:$PATH" \
      "$ROOT/scripts/audit-terminal-renderer-linkage.sh" \
        --binary "$BINARY" \
        --xcframework "$XCFRAMEWORK" >"$output" 2>&1; then
    echo "dynamic-loader fixture unexpectedly passed: $fixture_case" >&2
    exit 1
  fi
  grep -Fq "$diagnostic" "$output"
}

assert_rejected dlopen "generic dynamic-loading escape hatch"
assert_rejected dlsym "generic dynamic-loading escape hatch"
assert_rejected swift-bundle-load "generic dynamic-loading escape hatch"
assert_rejected objc-bundle-load "NSBundle dynamic-loading escape hatch"

CMUX_LINKAGE_FIXTURE_CASE=clean \
  PATH="$FAKE_BIN:$PATH" \
  "$ROOT/scripts/audit-terminal-renderer-linkage.sh" \
    --archive-only \
    --xcframework "$XCFRAMEWORK" > "$TEST_ROOT/archive-clean.log"

assert_archive_rejected() {
  local fixture_case="$1"
  local diagnostic="$2"
  local output="$TEST_ROOT/archive-$fixture_case.log"
  if CMUX_LINKAGE_FIXTURE_CASE="$fixture_case" \
      PATH="$FAKE_BIN:$PATH" \
      "$ROOT/scripts/audit-terminal-renderer-linkage.sh" \
        --archive-only \
        --xcframework "$XCFRAMEWORK" >"$output" 2>&1; then
    echo "dynamic-loader archive fixture unexpectedly passed: $fixture_case" >&2
    exit 1
  fi
  grep -Fq "$diagnostic" "$output"
}

assert_archive_rejected dlopen "scene archive contains a generic dynamic-loading escape hatch"
assert_archive_rejected dlsym "scene archive contains a generic dynamic-loading escape hatch"
assert_archive_rejected swift-bundle-load "scene archive contains a generic dynamic-loading escape hatch"
assert_archive_rejected objc-bundle-load "scene archive exposes an NSBundle dynamic-loading escape hatch"

echo "terminal renderer dynamic-loader linkage fixtures rejected"
