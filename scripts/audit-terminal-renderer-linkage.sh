#!/usr/bin/env bash

set -euo pipefail

BINARY=""
XCFRAMEWORK=""
ARCHIVE_ONLY=false

usage() {
  echo "Usage: ./scripts/audit-terminal-renderer-linkage.sh [--archive-only | --binary <path>] --xcframework <path>"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      BINARY="$2"
      shift 2
      ;;
    --xcframework)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      XCFRAMEWORK="$2"
      shift 2
      ;;
    --archive-only)
      ARCHIVE_ONLY=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -d "$XCFRAMEWORK" ]] || { echo "error: scene renderer XCFramework is missing: $XCFRAMEWORK" >&2; exit 1; }
if [[ "$ARCHIVE_ONLY" == false ]]; then
  [[ -f "$BINARY" ]] || { echo "error: renderer executable is missing: $BINARY" >&2; exit 1; }
elif [[ -n "$BINARY" ]]; then
  echo "error: --archive-only and --binary are mutually exclusive" >&2
  exit 2
fi

for command in ar clang file nm otool; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required audit command is missing: $command" >&2
    exit 1
  }
done

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-renderer-audit.XXXXXX")"
cleanup() {
  case "$TEMP_DIR" in
    "${TMPDIR:-/tmp}"/cmux-renderer-audit.*) rm -rf "$TEMP_DIR" ;;
  esac
}
trap cleanup EXIT

fail_with_matches() {
  local description="$1"
  local matches="$2"
  echo "error: $description" >&2
  printf '%s\n' "$matches" >&2
  exit 1
}

contains_exact_symbol() {
  local symbols="$1"
  local symbol="$2"
  grep -Fqx -- "$symbol" "$symbols"
}

banned_process_regex='(^|[[:space:]])(_openpty|_forkpty|_fork|_vfork|_posix_spawn|_posix_spawnp|_execv|_execve|_execvp|_execvpe|_execl|_execle|_execlp|_waitpid)([[:space:]]|$)'
banned_ghostty_regex='ghostty_(app_|surface_|process_census)'
banned_terminal_regex='terminal\.(Parser|Stream)|termio|(^|[._])pty([._]|$)'

if [[ "$ARCHIVE_ONLY" == false ]]; then
  FILE_OUTPUT="$TEMP_DIR/file.txt"
  DEFINED="$TEMP_DIR/defined.txt"
  UNDEFINED="$TEMP_DIR/undefined.txt"
  ALL_SYMBOLS="$TEMP_DIR/all-symbols.txt"
  LOADS="$TEMP_DIR/loads.txt"

  file "$BINARY" > "$FILE_OUTPUT"
  grep -q 'Mach-O' "$FILE_OUTPUT" || fail_with_matches \
    "renderer output is not Mach-O" "$(cat "$FILE_OUTPUT")"
  grep -q 'executable' "$FILE_OUTPUT" || fail_with_matches \
    "renderer output is not an executable" "$(cat "$FILE_OUTPUT")"

  nm -gUj "$BINARY" > "$DEFINED"
  nm -uj "$BINARY" > "$UNDEFINED"
  nm -a "$BINARY" > "$ALL_SYMBOLS"
  otool -L "$BINARY" > "$LOADS"

  required_worker_symbols=(
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
  )
  for symbol in "${required_worker_symbols[@]}"; do
    contains_exact_symbol "$DEFINED" "$symbol" || {
      echo "error: final renderer executable is missing required symbol: $symbol" >&2
      exit 1
    }
  done

  unexpected_undefined_ghostty="$(grep -E '^_ghostty_' "$UNDEFINED" || true)"
  if [[ -n "$unexpected_undefined_ghostty" ]]; then
    fail_with_matches \
      "final renderer executable has unresolved Ghostty symbols" \
      "$unexpected_undefined_ghostty"
  fi

  for table in "$DEFINED" "$UNDEFINED" "$ALL_SYMBOLS"; do
    matches="$(grep -E "$banned_process_regex|$banned_ghostty_regex" "$table" || true)"
    if [[ -n "$matches" ]]; then
      fail_with_matches \
        "final renderer executable links process-owning or full Ghostty symbols" \
        "$matches"
    fi
  done
  terminal_matches="$(grep -Ei "$banned_terminal_regex" "$ALL_SYMBOLS" || true)"
  if [[ -n "$terminal_matches" ]]; then
    fail_with_matches \
      "final renderer executable contains parser, termio, or PTY implementation symbols" \
      "$terminal_matches"
  fi

  load_matches="$(sed -n '2,$p' "$LOADS" | grep -Ei 'Ghostty(SceneRenderer)?Kit|libghostty' || true)"
  if [[ -n "$load_matches" ]]; then
    fail_with_matches \
      "final renderer executable dynamically loads a Ghostty library" \
      "$load_matches"
  fi
fi

HEADER="$(find -H "$XCFRAMEWORK" -type f -path '*/Headers/ghostty_scene.h' -print -quit)"
MODULE_MAP="$(find -H "$XCFRAMEWORK" -type f -path '*/Headers/module.modulemap' -print -quit)"
[[ -n "$HEADER" ]] || { echo "error: scene XCFramework has no ghostty_scene.h" >&2; exit 1; }
[[ -n "$MODULE_MAP" ]] || { echo "error: scene XCFramework has no module.modulemap" >&2; exit 1; }

HEADERS_DIR="$(dirname "$HEADER")"
MODULE_SMOKE="$TEMP_DIR/module-smoke.m"
printf '@import GhosttySceneRendererKit;\nint main(void) { return 0; }\n' > "$MODULE_SMOKE"
clang \
  -fmodules \
  -fmodule-map-file="$MODULE_MAP" \
  -I "$HEADERS_DIR" \
  -x objective-c \
  -fsyntax-only \
  "$MODULE_SMOKE"

DECLARED_ABI="$TEMP_DIR/declared-abi.txt"
grep -Eo 'ghostty_(scene_init|config_[[:alnum:]_]+|scene_renderer_[[:alnum:]_]+)[[:space:]]*\(' "$HEADER" \
  | sed -E 's/[[:space:]]*\($//' \
  | sed 's/^/_/' \
  | sort -u > "$DECLARED_ABI"
[[ -s "$DECLARED_ABI" ]] || { echo "error: scene header declares no C ABI" >&2; exit 1; }

ARCHIVES_LIST="$TEMP_DIR/archives.txt"
find -H "$XCFRAMEWORK" -type f -name '*.a' -print | sort > "$ARCHIVES_LIST"
[[ -s "$ARCHIVES_LIST" ]] || { echo "error: scene XCFramework contains no static archives" >&2; exit 1; }

while IFS= read -r archive; do
  archive_slug="$(printf '%s' "$archive" | shasum -a 256 | awk '{print $1}')"
  archive_defined="$TEMP_DIR/archive-$archive_slug-defined.txt"
  archive_undefined="$TEMP_DIR/archive-$archive_slug-undefined.txt"
  archive_all="$TEMP_DIR/archive-$archive_slug-all.txt"
  archive_members="$TEMP_DIR/archive-$archive_slug-members.txt"
  archive_ghostty="$TEMP_DIR/archive-$archive_slug-ghostty.txt"

  nm -gUj "$archive" > "$archive_defined"
  nm -u -A "$archive" > "$archive_undefined"
  nm -a "$archive" > "$archive_all"
  ar -t "$archive" > "$archive_members"
  grep -E '^_ghostty_' "$archive_defined" | sort -u > "$archive_ghostty"

  forbidden_undefined="$(grep -E "$banned_process_regex|$banned_ghostty_regex" "$archive_undefined" || true)"
  [[ -z "$forbidden_undefined" ]] || fail_with_matches \
    "scene archive contains forbidden process/runtime references: $archive" \
    "$forbidden_undefined"

  forbidden_symbols="$(grep -Ei "$banned_terminal_regex|$banned_ghostty_regex" "$archive_all" || true)"
  [[ -z "$forbidden_symbols" ]] || fail_with_matches \
    "scene archive contains parser, termio, PTY, app, or surface symbols: $archive" \
    "$forbidden_symbols"

  forbidden_members="$(grep -Ei '(^|/)(sentry|breakpad|crash_generation|exception_handler|minidump|imgui|dcimgui|dcgettext|dcigettext|dcngettext|dgettext|dngettext|gettext|ngettext|intl-compat|simdutf|libhighway_zcu|vt|autofit|ftbase|ftbbox|ftbdf|ftbitmap|ftcid|ftfstype|ftgasp|ftglyph|ftgxval|ftinit|ftmm|ftotval|ftpatent|ftpfr|ftstroke|ftsynth|fttype1|ftwinfnt|png|adler32|compress|crc32|deflate|gzclose|gzlib|gzread|gzwrite|inflate|infback|inftrees|inffast|trees|uncompr|zutil)\.o$' "$archive_members" || true)"
  [[ -z "$forbidden_members" ]] || fail_with_matches \
    "scene archive bundles unrelated app/runtime dependency objects: $archive" \
    "$forbidden_members"

  missing="$(comm -23 "$DECLARED_ABI" "$archive_ghostty" || true)"
  [[ -z "$missing" ]] || fail_with_matches \
    "scene archive is missing header-declared ABI symbols: $archive" "$missing"
  unexpected="$(comm -13 "$DECLARED_ABI" "$archive_ghostty" || true)"
  [[ -z "$unexpected" ]] || fail_with_matches \
    "scene archive exports Ghostty symbols outside its public header: $archive" "$unexpected"
done < "$ARCHIVES_LIST"

archive_count="$(wc -l < "$ARCHIVES_LIST" | tr -d ' ')"
abi_count="$(wc -l < "$DECLARED_ABI" | tr -d ' ')"
if [[ "$ARCHIVE_ONLY" == true ]]; then
  echo "Renderer archive audit passed: archives=$archive_count declared_scene_abi=$abi_count"
else
  FINAL_GHOSTTY="$TEMP_DIR/final-ghostty.txt"
  grep -E '^_ghostty_' "$DEFINED" | sort -u > "$FINAL_GHOSTTY"
  unexpected_final="$(comm -13 "$DECLARED_ABI" "$FINAL_GHOSTTY" || true)"
  [[ -z "$unexpected_final" ]] || fail_with_matches \
    "final renderer executable exports Ghostty symbols outside the scene header" \
    "$unexpected_final"

  binary_size="$(stat -f '%z' "$BINARY")"
  linked_count="$(wc -l < "$FINAL_GHOSTTY" | tr -d ' ')"
  echo "Renderer linkage audit passed: binary_bytes=$binary_size archives=$archive_count declared_scene_abi=$abi_count linked_scene_abi=$linked_count"
fi
