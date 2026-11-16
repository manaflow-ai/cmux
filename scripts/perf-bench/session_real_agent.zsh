#!/bin/zsh -f
# session_real_agent.zsh <working|blocked|idle> <name>
#
# The program of one agent terminal of the shared `real` bench session (session_real.py). It is NOT a
# model session. It draws like an agent TUI and reports its state through the product's own path:
# the hook helper every cmux-tui terminal exports (`$CMUX_TUI_HOOK claude <event>`, JSON on stdin).
#
# idle:    the prompt box, then it waits and prints nothing (most of a person's agents).
# blocked: a permission question, then it waits.
# working: a spinner line and the title at 10 Hz and one output line each second, for ever.
# Only zsh builtins in the loops (zselect, print): no process is started per frame.

zmodload zsh/zselect
state=${1:-idle}
name=${2:-agent}
session="session-real-$name"

report() {  # report <native event>
  [[ -n $CMUX_TUI_HOOK && -x $CMUX_TUI_HOOK ]] || return 0
  print -r -- "{\"session_id\":\"$session\",\"hook_event_name\":\"$1\",\"cwd\":\"$PWD\",\"prompt\":\"bench\",\"message\":\"Claude needs your permission to use Bash\"}" \
    | "$CMUX_TUI_HOOK" claude "$1" >/dev/null 2>&1
}

box() {
  print -r -- "╭──────────────────────────────────────────────────────────────╮"
  print -r -- "│ > $1"
  print -r -- "╰──────────────────────────────────────────────────────────────╯"
  print -r -- "  ? for shortcuts                                $name"
}

print -n -- "\e]0;✳ $name\a"
print -r -- "✻ Welcome to the bench agent ($name). This is session_real_agent.zsh, not a model."
report SessionStart

case $state in
  idle)
    box ""
    report UserPromptSubmit
    report Stop
    ;;
  blocked)
    report UserPromptSubmit
    print -r -- "⏺ Bash(make test)"
    print -r -- "  Do you want to proceed?  ❯ 1. Yes   2. No"
    report Notification
    ;;
  working)
    report UserPromptSubmit
    frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    integer tick=0
    while true; do
      (( tick += 1 ))
      frame=$frames[$(( tick % 10 + 1 ))]
      print -n -- "\e]0;$frame $name\a\r\e[2K$frame Working… ($(( tick / 10 ))s · ↑ $(( tick * 7 )) tokens · esc to interrupt)"
      if (( tick % 10 == 0 )); then
        print -r -- $'\r\e[2K'"⏺ Read(src/file-$(( tick / 10 )).swift)  ⎿ $(( tick % 97 + 12 )) lines"
      fi
      zselect -t 10
    done
    ;;
esac

# Wait for ever without a wake (the terminal's end kills this program).
while true; do zselect -t 360000; done
