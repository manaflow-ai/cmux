#!/usr/bin/env bash
# Verify that every Mach-O in a packaged macOS app contains arm64 and x86_64.
#
# The scan intentionally examines every regular file instead of relying on
# executable bits or filename suffixes. That keeps newly embedded helpers,
# plug-ins, XPC services, and FFI libraries covered without per-file updates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ALLOWLIST="$SCRIPT_DIR/macos-universal-bundle-allowlist.txt"
ALLOWLIST_PATH="$DEFAULT_ALLOWLIST"
APP_PATH=""

usage() {
  cat <<'EOF'
Usage: scripts/verify-macos-bundle-architectures.sh [--allowlist PATH] <path-to-cmux.app>

Scans every regular file in a macOS app bundle, skips non-Mach-O files, and
requires every Mach-O to contain both arm64 and x86_64 slices. Allowlist PATH
contains relative-path shell globs for deliberately single-architecture files.
EOF
}

error() {
  echo "error: $*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allowlist)
      [[ $# -ge 2 ]] || error "--allowlist requires a path"
      ALLOWLIST_PATH="$2"
      shift 2
      ;;
    --allowlist=*)
      ALLOWLIST_PATH="${1#--allowlist=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      [[ $# -eq 1 ]] || error "expected exactly one app bundle path"
      APP_PATH="$1"
      shift
      ;;
    -*)
      error "unknown option: $1"
      ;;
    *)
      [[ -z "$APP_PATH" ]] || error "expected exactly one app bundle path"
      APP_PATH="$1"
      shift
      ;;
  esac
done

[[ -n "$APP_PATH" ]] || { usage >&2; exit 2; }
[[ -d "$APP_PATH/Contents" ]] || error "app bundle not found: $APP_PATH"
[[ -f "$ALLOWLIST_PATH" ]] || error "allowlist not found: $ALLOWLIST_PATH"
[[ -r "$ALLOWLIST_PATH" ]] || error "allowlist is not readable: $ALLOWLIST_PATH"

# Resolve the bundle once so relative paths are stable even when the caller
# supplied a path containing spaces or a trailing slash.
APP_PATH="$(cd "$APP_PATH" && pwd -P)"

# Allowlist entries are intentionally relative to the app root. Reject an
# absolute pattern up front so an exception cannot accidentally be tied to the
# runner's filesystem layout.
while IFS= read -r pattern || [[ -n "$pattern" ]]; do
  pattern="${pattern%$'\r'}"
  [[ -z "$pattern" || "$pattern" == \#* ]] && continue
  [[ "$pattern" != /* ]] || error "allowlist pattern must be relative: $pattern"
done < "$ALLOWLIST_PATH"

FILE_TOOL="${CMUX_FILE_TOOL:-file}"
LIPO_TOOL="${CMUX_LIPO_TOOL:-lipo}"

is_allowlisted() {
  local relative_path="$1"
  local pattern

  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    pattern="${pattern%$'\r'}"
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    # The unquoted right-hand side is deliberate: entries are shell globs.
    if [[ "$relative_path" == $pattern ]]; then
      return 0
    fi
  done < "$ALLOWLIST_PATH"
  return 1
}

has_architecture() {
  local archs="$1"
  local required="$2"
  case " $archs " in
    *" $required "*) return 0 ;;
    *) return 1 ;;
  esac
}

INVENTORY_PATH="$(mktemp "${TMPDIR:-/tmp}/cmux-macho-inventory.XXXXXX")"
cleanup() {
  rm -f "$INVENTORY_PATH"
}
trap cleanup EXIT

if ! find "$APP_PATH" -type f -print0 > "$INVENTORY_PATH"; then
  error "could not enumerate files in app bundle: $APP_PATH"
fi

files_seen=0
macho_files=0
single_arch_failures=0
lipo_failures=0
allowlisted_files=0

echo "Scanning Mach-O files in: $APP_PATH"
while IFS= read -r -d '' path; do
  files_seen=$((files_seen + 1))
  relative_path="${path#"$APP_PATH"/}"

  if ! file_description="$("$FILE_TOOL" -b -- "$path" 2>&1)"; then
    echo "ERROR: file identification failed for $relative_path: $file_description" >&2
    lipo_failures=$((lipo_failures + 1))
    continue
  fi

  # Non-Mach-O resources are expected and intentionally skipped.
  case "$file_description" in
    *Mach-O*) ;;
    *) continue ;;
  esac

  macho_files=$((macho_files + 1))
  if ! archs="$("$LIPO_TOOL" -archs "$path" 2>&1)"; then
    echo "ERROR: lipo -archs failed for $relative_path: $archs" >&2
    lipo_failures=$((lipo_failures + 1))
    continue
  fi

  if has_architecture "$archs" arm64 && has_architecture "$archs" x86_64; then
    continue
  fi

  if is_allowlisted "$relative_path"; then
    echo "Allowlisted single-arch Mach-O [$archs]: $relative_path"
    allowlisted_files=$((allowlisted_files + 1))
    continue
  fi

  echo "ERROR: non-universal Mach-O [$archs] (required arm64 x86_64): $relative_path" >&2
  single_arch_failures=$((single_arch_failures + 1))
done < "$INVENTORY_PATH"

total_failures=$((single_arch_failures + lipo_failures))
echo "Scanned $files_seen files; found $macho_files Mach-O files; allowlisted $allowlisted_files; failures $total_failures."

if (( total_failures > 0 )); then
  echo "ERROR: macOS app bundle contains Mach-Os that are not universal arm64+x86_64." >&2
  exit 1
fi

echo "PASS: every Mach-O in the app bundle is universal arm64+x86_64."
