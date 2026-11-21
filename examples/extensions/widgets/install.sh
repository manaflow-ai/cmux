#!/bin/sh
# The widgets in one command: clock, weather, calendar and to-do, each its own card in the sidebar.
#
#   examples/extensions/widgets/install.sh                   # all four
#   examples/extensions/widgets/install.sh weather todo      # only the ones you name
#   examples/extensions/widgets/install.sh remove            # take them all off again
#
# `cmux ext dev` loads one folder at a time, so this loops over them.
set -u
cd "$(dirname "$0")/../../.." || exit 1
ALL="clock weather calendar todo"

if [ "${1:-}" = remove ]; then
  for w in $ALL; do cmux ext remove "local/widget-$w"; done
  exit 0
fi

for w in ${*:-$ALL}; do
  if [ -d "examples/extensions/widget-$w" ]; then
    cmux ext dev --once "examples/extensions/widget-$w" || echo "widget-$w did not load; see above"
  else
    echo "no widget called $w (clock, weather, calendar, todo)"
  fi
done
