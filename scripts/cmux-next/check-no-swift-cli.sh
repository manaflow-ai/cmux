#!/usr/bin/env bash
# Fails when the Swift CLI, its tests, the app's compat layer, the CLI-only
# CmuxFoundation package, a CLI-owned string table or a `cmux-cli` Xcode target
# comes back (a merge from main re-adds them). The `cmux` CLI is the Rust
# cmux-tui binary (plans/cmux-next/cli.md): port the change there.
#
# Checks tracked files only, so a stray local build directory is ignored.
# Usage: scripts/cmux-next/check-no-swift-cli.sh [repo-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)}"
paths=(
  CLI
  cmuxCLITests
  cmuxCLITestSupport
  Packages/macOS/CmuxNext/Sources/CmuxNextControl/Compat
  Packages/macOS/CmuxNext/Sources/CmuxNextApp/Compat
  Packages/macOS/CmuxFoundation
  Resources/Localizable.xcstrings
)
status=0
for path in "${paths[@]}"; do
  if [[ -n "$(git -C "$root" ls-files -- "$path" | head -n 1)" ]]; then
    # The shared resource path also owns web gallery labels. Only that namespace is
    # allowed here; retired CLI keys, mixed catalogs and malformed JSON still fail.
    if [[ "$path" == "Resources/Localizable.xcstrings" ]] && python3 - "$root/$path" <<'PY_GALLERY'
import json
from pathlib import Path
import sys
try:
    catalog = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, ValueError):
    sys.exit(1)
strings = catalog.get("strings") if isinstance(catalog, dict) else None
sys.exit(0 if isinstance(strings, dict) and strings and all(key.startswith("gallery.") for key in strings) else 1)
PY_GALLERY
    then
      continue
    fi
    echo "check-no-swift-cli: $path is back. The CLI is Rust (plans/cmux-next/cli.md); port the change there and delete $path." >&2
    status=1
  fi
done
if grep -Eq 'name = "?cmux-cli"?;' "$root/cmux.xcodeproj/project.pbxproj"; then
  echo "check-no-swift-cli: cmux.xcodeproj has a cmux-cli target. The CLI is Rust (plans/cmux-next/cli.md); port the change there and delete the target." >&2
  status=1
fi
if (( status == 0 )); then
  echo "check-no-swift-cli: ok"
fi
exit "$status"
