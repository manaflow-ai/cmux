#!/usr/bin/env bash
# Fails when the Swift CLI, its tests, the app's compat layer, the CLI-only
# CmuxFoundation package, the CLI string table or a `cmux-cli` Xcode target
# comes back (a merge from main re-adds them). The `cmux` CLI is the Rust
# cmux-tui binary (plans/cmux-next/cli.md): port the change there.
#
# Resources/Localizable.xcstrings is the webviews' shared diff label catalog
# (webviews/scripts/pages/gen-strings.mjs reads its diffViewer.* keys, since
# d69da1e49f2), so it fails only when it holds any other key: the CLI's strings.
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
)
status=0
for path in "${paths[@]}"; do
  if [[ -n "$(git -C "$root" ls-files -- "$path" | head -n 1)" ]]; then
    echo "check-no-swift-cli: $path is back. The CLI is Rust (plans/cmux-next/cli.md); port the change there and delete $path." >&2
    status=1
  fi
done
catalog=Resources/Localizable.xcstrings
if [[ -n "$(git -C "$root" ls-files -- "$catalog")" ]]; then
  other="$(python3 - "$root/$catalog" <<'PY'
import json, sys
keys = json.load(open(sys.argv[1], encoding="utf-8")).get("strings", {})
print(" ".join(sorted(key for key in keys if not key.startswith("diffViewer.")))[:400])
PY
)"
  if [[ -n "$other" ]]; then
    echo "check-no-swift-cli: $catalog holds keys other than diffViewer.* ($other). The CLI is Rust (plans/cmux-next/cli.md); port the change there and drop those keys." >&2
    status=1
  fi
fi
if grep -Eq 'name = "?cmux-cli"?;' "$root/cmux.xcodeproj/project.pbxproj"; then
  echo "check-no-swift-cli: cmux.xcodeproj has a cmux-cli target. The CLI is Rust (plans/cmux-next/cli.md); port the change there and delete the target." >&2
  status=1
fi
if (( status == 0 )); then
  echo "check-no-swift-cli: ok"
fi
exit "$status"
