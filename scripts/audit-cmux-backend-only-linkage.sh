#!/usr/bin/env bash

set -euo pipefail

APP_BUNDLE=""
INFO_PLIST=""
declare -a EXPLICIT_BINARIES=()

usage() {
  echo "Usage: ./scripts/audit-cmux-backend-only-linkage.sh (--app-bundle <path> | --info-plist <path> --binary <path> [--binary <path> ...])"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      APP_BUNDLE="$2"
      shift 2
      ;;
    --info-plist)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      INFO_PLIST="$2"
      shift 2
      ;;
    --binary)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      EXPLICIT_BINARIES+=("$2")
      shift 2
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

if [[ -n "$APP_BUNDLE" && ( -n "$INFO_PLIST" || ${#EXPLICIT_BINARIES[@]} -gt 0 ) ]]; then
  echo "error: --app-bundle cannot be combined with --info-plist or --binary" >&2
  exit 2
fi
if [[ -z "$APP_BUNDLE" && ( -z "$INFO_PLIST" || ${#EXPLICIT_BINARIES[@]} -eq 0 ) ]]; then
  usage >&2
  exit 2
fi

for command in file nm otool strings; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required audit command is missing: $command" >&2
    exit 1
  }
done

declare -a BINARIES=()
if [[ -n "$APP_BUNDLE" ]]; then
  [[ -d "$APP_BUNDLE" ]] || { echo "error: app bundle is missing: $APP_BUNDLE" >&2; exit 1; }
  INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
  [[ -f "$INFO_PLIST" ]] || { echo "error: app Info.plist is missing: $INFO_PLIST" >&2; exit 1; }
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true)"
  [[ -n "$executable_name" ]] || { echo "error: CFBundleExecutable is missing from $INFO_PLIST" >&2; exit 1; }
  primary_binary="$APP_BUNDLE/Contents/MacOS/$executable_name"
  [[ -f "$primary_binary" ]] || { echo "error: app executable is missing: $primary_binary" >&2; exit 1; }
  BINARIES+=("$primary_binary")

  # Xcode's debug executable can be a small trampoline whose Swift code lives
  # in a sibling *.debug.dylib. Audit both so a clean trampoline cannot hide a
  # linked legacy runtime.
  while IFS= read -r candidate; do
    [[ "$candidate" == "$primary_binary" ]] && continue
    BINARIES+=("$candidate")
  done < <(find "$APP_BUNDLE/Contents/MacOS" -maxdepth 1 -type f -name '*.debug.dylib' -print | sort)

  bundled_legacy_artifacts="$(find "$APP_BUNDLE/Contents" -type f \
    \( -iname '*ghosttykit*' -o -iname '*libghostty*' -o -iname '*cmuxterminallegacy*' \) \
    -print || true)"
  if [[ -n "$bundled_legacy_artifacts" ]]; then
    echo "error: backend-only app bundles a loadable Ghostty or legacy terminal artifact" >&2
    printf '%s\n' "$bundled_legacy_artifacts" >&2
    exit 1
  fi
else
  BINARIES=("${EXPLICIT_BINARIES[@]}")
fi

[[ -f "$INFO_PLIST" ]] || { echo "error: Info.plist is missing: $INFO_PLIST" >&2; exit 1; }

truthy_plist_value() {
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || true)"
  case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

truthy_plist_value CMUXTerminalBackendServiceEnabled || {
  echo "error: backend-only audit requires CMUXTerminalBackendServiceEnabled=true" >&2
  exit 1
}
runtime_ownership="$(/usr/libexec/PlistBuddy -c 'Print :CMUXTerminalRuntimeOwnership' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$runtime_ownership" == "backend-only" ]] || {
  echo "error: CMUXTerminalRuntimeOwnership is '$runtime_ownership', expected backend-only" >&2
  exit 1
}

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-backend-only-audit.XXXXXX")"
cleanup() {
  case "$TEMP_DIR" in
    "${TMPDIR:-/tmp}"/cmux-backend-only-audit.*) rm -rf "$TEMP_DIR" ;;
  esac
}
trap cleanup EXIT

banned_ghostty_symbol_regex='(^|[[:space:]])_?ghostty_[[:alnum:]_]+([[:space:]]|$)'
banned_pty_symbol_regex='(^|[[:space:]])(_openpty|_forkpty|_posix_openpt|_grantpt|_unlockpt|_ptsname|_ptsname_r|_login_tty)([[:space:]]|$)'
banned_legacy_identity_regex='GhosttyApp|GhosttyNSView|EmbeddedTerminalPanelFactory|TerminalSurfaceEmbeddedRuntimeDependencies|TerminalEngineHosting|embeddedGhostty|CmuxTerminalLegacyRuntime'
banned_load_regex='GhosttyKit|libghostty|CmuxTerminalLegacyRuntime'

for binary in "${BINARIES[@]}"; do
  [[ -f "$binary" ]] || { echo "error: audited binary is missing: $binary" >&2; exit 1; }
  slug="$(printf '%s' "$binary" | shasum -a 256 | awk '{print $1}')"
  file_output="$TEMP_DIR/$slug-file.txt"
  symbols="$TEMP_DIR/$slug-symbols.txt"
  loads="$TEMP_DIR/$slug-loads.txt"
  embedded_strings="$TEMP_DIR/$slug-strings.txt"

  file "$binary" > "$file_output"
  grep -q 'Mach-O' "$file_output" || {
    echo "error: backend-only artifact is not Mach-O: $binary" >&2
    cat "$file_output" >&2
    exit 1
  }
  nm -a "$binary" > "$symbols"
  otool -L "$binary" > "$loads"
  strings -a "$binary" > "$embedded_strings"

  forbidden_symbols="$(grep -E "$banned_ghostty_symbol_regex|$banned_pty_symbol_regex" "$symbols" || true)"
  if [[ -n "$forbidden_symbols" ]]; then
    echo "error: backend-only Swift product links Ghostty or PTY ownership symbols: $binary" >&2
    printf '%s\n' "$forbidden_symbols" >&2
    exit 1
  fi

  forbidden_identities="$(grep -E "$banned_legacy_identity_regex" "$symbols" "$embedded_strings" || true)"
  if [[ -n "$forbidden_identities" ]]; then
    echo "error: backend-only Swift product contains a legacy terminal runtime identity: $binary" >&2
    printf '%s\n' "$forbidden_identities" >&2
    exit 1
  fi

  forbidden_loads="$(sed -n '2,$p' "$loads" | grep -Ei "$banned_load_regex" || true)"
  if [[ -n "$forbidden_loads" ]]; then
    echo "error: backend-only Swift product dynamically loads Ghostty or legacy terminal code: $binary" >&2
    printf '%s\n' "$forbidden_loads" >&2
    exit 1
  fi
done

echo "cmux backend-only linkage audit passed: binaries=${#BINARIES[@]} runtime_ownership=$runtime_ownership"
