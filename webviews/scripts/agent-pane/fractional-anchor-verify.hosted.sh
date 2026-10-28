#!/usr/bin/env bash
# Run the small-input discriminator, restore source, then the unchanged long-chat oracle.
set -euo pipefail
repo_root=$(git rev-parse --show-toplevel)
app="$repo_root/webviews/src/agent-session/acpmux/App.tsx"
saved=$(mktemp /tmp/cmux-anchor-app.XXXXXXXX)
cp "$app" "$saved"
restore() { cp "$saved" "$app"; rm -f "$saved"; }
trap restore EXIT
python3 - "$app" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
current = "scrolledTo.current.top - live > 0;"
old = "scrolledTo.current.top - live > FOLLOW_BOTTOM_DEADBAND_PX;"
assert source.count(current) == 1
source = source.replace(current, old)
current = "const clamped = !recentUp && live < scrolledTo.current.top - 0.5 && live >= end - 1;"
old = "const clamped = live < scrolledTo.current.top - 0.5 && live >= end - 1;"
assert source.count(current) == 1
path.write_text(source.replace(current, old))
PY
red_status=0
(cd "$repo_root/webviews" && bun test test/transcript-row-renders.test.tsx \
  --test-name-pattern 'delayed scroll event keeps') || red_status=$?
restore
trap - EXIT
if (( red_status == 0 )); then
  echo 'fractional-anchor: controlled reversion unexpectedly passed the small-input discriminator' >&2
  exit 1
fi
printf 'fractional-anchor: controlled-reversion status=%s\n' "$red_status"
cd "$repo_root/webviews"
bun test test/transcript-row-renders.test.tsx \
  src/agent-session/acpmux/conversation/scrollAnchorOrigin.test.ts \
  src/agent-session/acpmux/conversation/scrollCoordinates.test.ts \
  src/agent-session/acpmux/conversation/scrollAnchor.test.ts
bash scripts/agent-pane/fractional-anchor-paired.hosted.sh b13599e4568abc0cbb57a73ebbe8440a20b8b775
bun run check
cd "$repo_root"
scripts/web-lint.sh --base b13599e4568abc0cbb57a73ebbe8440a20b8b775 --head HEAD
