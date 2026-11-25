#!/usr/bin/env bash
# Regenerate, or with --check verify, the settings exports (settings-exports.txt, or
# $CMUX_SETTINGS_EXPORTS_LIST) off the Mac, byte for byte what ManagedPreferencesManifestTests and
# SettingsSchemaExportTests write. (links.json comes from regenerate-action-exports-linux.sh.)
#   export-settings-linux.sh [--check]
# Exit: 0 written/fresh, 1 stale (--check, stale paths on stderr), 2 cannot decide (fall back to
# the Mac). Needs python3 (3.9+) only. Code: scripts/cmux-next/linux-exports/.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null || { echo "export-settings-linux: python3 not found" >&2; exit 2; }
exec python3 -I -B "$here/linux-exports/export.py" "$@"
