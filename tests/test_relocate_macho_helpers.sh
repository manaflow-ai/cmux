#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-relocate-helpers.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

APP="$TMP_DIR/cmux.app"
RESOURCE_BIN="$APP/Contents/Resources/bin"
HELPERS="$APP/Contents/Helpers"
mkdir -p "$RESOURCE_BIN"

for name in cmux ghostty cmux-cua cmux-diff-sidecar cmux-tui cmuxd cmux-paste-text-worker coderouter; do
  printf 'macho:%s\n' "$name" > "$RESOURCE_BIN/$name"
  chmod 755 "$RESOURCE_BIN/$name"
done
printf '#!/bin/sh\necho wrapper\n' > "$RESOURCE_BIN/cmux-claude-wrapper"
chmod 755 "$RESOURCE_BIN/cmux-claude-wrapper"
printf 'license\n' > "$RESOURCE_BIN/cmux-cua-LICENSE.md"
mkdir -p "$RESOURCE_BIN/CmuxFoundation_CmuxFoundation.bundle/Contents"
printf 'localized\n' > "$RESOURCE_BIN/CmuxFoundation_CmuxFoundation.bundle/Contents/Localizable.strings"
printf 'not executable\n' > "$RESOURCE_BIN/readme"

FILE_TOOL="$TMP_DIR/file"
cat > "$FILE_TOOL" <<'SCRIPT'
#!/usr/bin/env bash
case "$*" in
  *cmux-claude-wrapper*|*cmux-cua-LICENSE.md*|*readme*) printf '%s: ASCII text\n' "$2" ;;
  *) printf '%s: Mach-O universal binary\n' "$2" ;;
esac
SCRIPT
chmod 755 "$FILE_TOOL"

CMUX_FILE_TOOL="$FILE_TOOL" "$ROOT/scripts/relocate-macho-helpers.sh" "$APP"

for name in cmux ghostty cmux-cua cmux-diff-sidecar cmux-tui cmuxd cmux-paste-text-worker coderouter; do
  [[ -x "$HELPERS/$name" ]] || { echo "missing relocated helper: $name" >&2; exit 1; }
done
[[ -L "$RESOURCE_BIN/cmux" ]] || { echo 'missing legacy cmux symlink' >&2; exit 1; }
[[ "$(readlink "$RESOURCE_BIN/cmux")" == '../../Helpers/cmux' ]] || { echo 'legacy cmux symlink points to the wrong helper' >&2; exit 1; }
for name in ghostty cmux-cua cmux-diff-sidecar cmux-tui cmuxd cmux-paste-text-worker coderouter; do
  [[ ! -e "$RESOURCE_BIN/$name" ]] || { echo "stale resource helper remains: $name" >&2; exit 1; }
done
[[ -x "$RESOURCE_BIN/cmux-claude-wrapper" ]] || { echo 'wrapper moved unexpectedly' >&2; exit 1; }
[[ -f "$RESOURCE_BIN/cmux-cua-LICENSE.md" ]] || { echo 'license moved unexpectedly' >&2; exit 1; }
[[ -L "$RESOURCE_BIN/CmuxFoundation_CmuxFoundation.bundle" ]] || { echo 'missing legacy resource bundle symlink' >&2; exit 1; }
[[ -d "$HELPERS/CmuxFoundation_CmuxFoundation.bundle" ]] || { echo 'package resource bundle was not relocated' >&2; exit 1; }
[[ "$(cat "$HELPERS/CmuxFoundation_CmuxFoundation.bundle/Contents/Localizable.strings")" == localized ]] || exit 1
[[ -f "$RESOURCE_BIN/readme" ]] || { echo 'non-Mach-O resource changed unexpectedly' >&2; exit 1; }

# The operation is idempotent when the signing script is rerun on the same app.
CMUX_FILE_TOOL="$FILE_TOOL" "$ROOT/scripts/relocate-macho-helpers.sh" "$APP" >/dev/null
[[ -x "$HELPERS/cmux" && -L "$RESOURCE_BIN/cmux" ]] || { echo 'second relocation changed the bundle' >&2; exit 1; }

echo 'PASS: release Mach-O helpers relocate to Contents/Helpers'
