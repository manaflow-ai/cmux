#!/bin/sh
# The whole Leo collection in one command: the four extensions, then the look.
#
#   examples/extensions/leo-collection/install.sh            # everything, the dusk look
#   examples/extensions/leo-collection/install.sh neon       # everything, another look
#   examples/extensions/leo-collection/install.sh remove     # take it all off again
#
# `cmux ext dev` loads one folder at a time, so this loops over them.
set -u
cd "$(dirname "$0")/../../.." || exit 1
EXTENSIONS="leo-clock leo-weather leo-gacha leo-usage"
LOOK="${1:-dusk}"

if [ "$LOOK" = remove ]; then
  for ext in $EXTENSIONS; do
    id=$(sed -n 's/.*"id": *"\(local\/[^"]*\)".*/\1/p' "examples/extensions/$ext"/cmux-app*.json 2>/dev/null | head -n 1)
    [ -n "$id" ] && cmux ext remove "$id"
  done
  cmux customize discard
  exit 0
fi

for ext in $EXTENSIONS; do
  if [ -d "examples/extensions/$ext" ]; then
    cmux ext dev --once "examples/extensions/$ext" || echo "$ext did not load; see above"
  else
    echo "$ext is not on this branch yet; skipped"
  fi
done
cmux customize use "examples/customize/leo/$LOOK.json"
