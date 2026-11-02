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
# The last reviewed source retained a canceled upward input until an unrelated native clamp.
git fetch --no-tags --depth=1 origin ebb38fe7eadafb72485bcb023120b2b8a9e91e3c
saved=$(mktemp /tmp/cmux-anchor-app.XXXXXXXX)
cp "$app" "$saved"
trap restore EXIT
git show ebb38fe7eadafb72485bcb023120b2b8a9e91e3c:webviews/src/agent-session/acpmux/App.tsx > "$app"
red_log=$(mktemp /tmp/cmux-anchor-canceled.XXXXXXXX)
red_status=0
(cd "$repo_root/webviews" && bun test test/transcript-row-renders.test.tsx \
  --test-name-pattern 'no-op upward gesture') > "$red_log" 2>&1 || red_status=$?
cat "$red_log"
restore
trap - EXIT
python3 - "$red_log" "$red_status" <<'PYRED'
from pathlib import Path
import re
import sys
log = re.sub(r"\x1b\[[0-9;]*m", "", Path(sys.argv[1]).read_text())
assert int(sys.argv[2]) != 0, 'canceled-input discriminator unexpectedly passed old source'
assert len(re.findall(r"^\(fail\).*a no-op upward gesture", log, re.M)) == 2, log[-4000:]
PYRED
rm -f "$red_log"
# Absolute Home/End targets discard a prior fractional origin, unlike relative arrow keys.
minimap="$repo_root/webviews/src/agent-session/acpmux/chatMinimap/ChatMinimap.tsx"
saved_minimap=$(mktemp /tmp/cmux-anchor-minimap.XXXXXXXX)
cp "$minimap" "$saved_minimap"
restore_minimap() { cp "$saved_minimap" "$minimap"; rm -f "$saved_minimap"; }
trap restore_minimap EXIT
git show ebb38fe7eadafb72485bcb023120b2b8a9e91e3c:webviews/src/agent-session/acpmux/chatMinimap/ChatMinimap.tsx > "$minimap"
red_log=$(mktemp /tmp/cmux-anchor-minimap-red.XXXXXXXX)
red_status=0
(cd "$repo_root/webviews" && bun test test/chat-minimap.test.tsx \
  --test-name-pattern 'absolute minimap keys') > "$red_log" 2>&1 || red_status=$?
cat "$red_log"
restore_minimap
trap - EXIT
python3 - "$red_log" "$red_status" <<'PYRED'
from pathlib import Path
import re
import sys
log = re.sub(r"\x1b\[[0-9;]*m", "", Path(sys.argv[1]).read_text())
assert int(sys.argv[2]) != 0, 'absolute-key discriminator unexpectedly passed old source'
assert len(re.findall(r"^\(fail\).*absolute minimap keys", log, re.M)) == 1, log[-4000:]
PYRED
rm -f "$red_log"
cd "$repo_root/webviews"
bun test test/chat-minimap.test.tsx --test-name-pattern 'absolute minimap keys'
bun test test/transcript-row-renders.test.tsx \
  src/agent-session/acpmux/conversation/scrollAnchorOrigin.test.ts \
  src/agent-session/acpmux/conversation/scrollCoordinates.test.ts \
  src/agent-session/acpmux/conversation/scrollAnchor.test.ts
bash scripts/agent-pane/fractional-anchor-paired.hosted.sh b13599e4568abc0cbb57a73ebbe8440a20b8b775
bun run check
cd "$repo_root"
scripts/web-lint.sh --base b13599e4568abc0cbb57a73ebbe8440a20b8b775 --head HEAD
