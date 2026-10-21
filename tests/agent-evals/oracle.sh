#!/bin/bash
# The oracle agent: does each headless task the right way with the cmux CLI.
# It must score 100%; if it does not, the harness or a grader is wrong.
set -euo pipefail
task="$1"
j() { cmux --json "$@"; }
v() { j "$@" | jq -r "${JQ:-.value}"; }

me_tab=$(j tab list | jq -r --arg t "$CMUX_TUI_TERMINAL_ID" '.[] | select(.content_id == $t) | .id')
me_pane=$(j tab list | jq -r --arg t "$CMUX_TUI_TERMINAL_ID" '.[] | select(.content_id == $t) | .pane_id')
me_ws=$(j workspace list | jq -r '.[] | select(.focused) | .id')

# The pane right of mine: reuse it when there is one, else split once.
right_pane() {
  local n
  n=$(j pane "$me_pane" neighbor right 2>/dev/null | jq -r '.pane.id // empty' 2>/dev/null || true)
  if [ -n "$n" ] && [ "$n" != "null" ]; then echo "new-tab $n"; else echo split; fi
}
# Opens a terminal on the right; prints "tab_id term_id".
open_right() {
  local where r
  where=$(right_pane)
  if [ "$where" = split ]; then
    r=$(j pane "$me_pane" split --right --viewport-width 0.5)
  else
    r=$(j tab create terminal --pane "${where#new-tab }")
  fi
  echo "$(echo "$r" | jq -r .value.tab_id) $(echo "$r" | jq -r .value.terminal_id)"
}
run_in() { j terminal "$1" write --text "$2"$'\n' > /dev/null; }
refocus() { j pane "$me_pane" focus > /dev/null; }

case "$task" in
  terminal-right | watch-command)
    word=EVAL_RIGHT_OK; [ "$task" = watch-command ] && word=EVAL_WATCH_OK
    read -r tab term < <(open_right); refocus
    run_in "$term" "echo $word"
    ;;
  reuse-right)
    read -r tab term < <(open_right); refocus
    run_in "$term" "echo EVAL_REUSE_OK"
    ;;
  subagents-right)
    tabs=()
    for role in build test lint; do
      read -r tab term < <(open_right); refocus
      j tab "$tab" rename "$role" > /dev/null
      run_in "$term" "cmux-eval-agent --role $role"
      tabs+=("$tab")
    done
    sleep 2
    j tab group create --tabs "$(IFS=,; echo "${tabs[*]}")" --name "Helpers" > /dev/null
    ;;
  group-workspaces)
    for topic in api web; do
      g=$(j workspace group create --name "${topic^^}" | jq -r .value.id)
      j workspace list | jq -r --arg p "$topic:" '.[] | select(.name | startswith($p)) | .id' | while read -r ws; do
        j workspace group "$g" add --workspace "$ws" > /dev/null
      done
    done
    ;;
  group-tabs)
    ids() { j tab list | jq -r --argjson n "$1" '[.[] | select(.name as $x | $n | index($x)) | .id] | join(",")'; }
    j tab group create --tabs "$(ids '["server","server logs"]')" --name "Server" > /dev/null
    j tab group create --tabs "$(ids '["unit tests","test watcher"]')" --name "Tests" > /dev/null
    ;;
  read-only-answer)
    pane=$(j pane "$me_pane" neighbor right | jq -r '.pane.id')
    term=$(j tab list | jq -r --arg p "$pane" '[.[] | select(.pane_id == $p)][0].content_id')
    code=$(j terminal "$term" screen read | jq -r .text | grep -o 'E[0-9]\{4\}' | head -1)
    echo "The build failed with error $code."
    ;;
  new-workspace-background)
    r=$(j workspace create --name eval-proj)
    ws=$(echo "$r" | jq -r .value.workspace_id); p=$(echo "$r" | jq -r .value.pane_id)
    j workspace "$me_ws" focus > /dev/null; refocus
    s=$(j pane "$p" split --right)
    j workspace "$me_ws" focus > /dev/null; refocus
    run_in "$(echo "$s" | jq -r .value.terminal_id)" "echo EVAL_WS_OK"
    ;;
  organize-end-to-end)
    read -r t1 term1 < <(open_right); refocus
    read -r t2 term2 < <(open_right); refocus
    run_in "$term1" "echo EVAL_FE_OK"; run_in "$term2" "echo EVAL_BE_OK"
    j tab group create --tabs "$t1,$t2" --name "Shop servers" > /dev/null
    g=$(j workspace group create --name "Shop" | jq -r .value.id)
    j workspace group "$g" add --workspace "$me_ws" > /dev/null
    ;;
  *) echo "oracle: no plan for $task" >&2; exit 3 ;;
esac
refocus
