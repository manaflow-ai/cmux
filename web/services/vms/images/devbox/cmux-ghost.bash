# cmux history ghost text for Bash (/etc/cmux/ghost.bash).
#
# fish-style autosuggestions: after each typed key, the most recent history
# line that starts with the current input is shown in gray after the cursor,
# and Right, End, Ctrl-E or Ctrl-F accept it (Alt-F or Alt-Right accepts one
# word). Readline stays the line editor; this file only binds the printable
# keys and draws the suggestion. The lookup is `fc`, which scans Bash's own
# history list in C (about 0.2 ms for 50,000 entries), so a keystroke costs
# about what it costs without suggestions; ble.sh, a line editor written in
# shell, cost 15-30 ms per key with stalls of hundreds of milliseconds on
# Cloud VMs.
#
# The suggestion is never part of the line buffer: Enter, Tab, Ctrl-C and
# every other readline command see exactly what was typed. Readline redraws
# the input line after each `bind -x` command, so the suggestion is painted
# first, at the column where the typed text will end, and readline's redraw
# writes the prompt and input in front of it.
case $- in *i*) ;; *) return 0 ;; esac
[[ ${BASH_VERSINFO[0]} -ge 5 && -z ${__cmux_ghost_loaded-} && -t 1 ]] || return 0
[[ $TERM != dumb ]] || return 0
__cmux_ghost_loaded=1

__cmux_ghost_color=${CMUX_GHOST_COLOR-$'\e[38;5;245m'}
__cmux_ghost_shown=      # suffix painted after the cursor, empty when none
__cmux_ghost_prefix=     # input for which __cmux_ghost_match was computed
__cmux_ghost_match=      # full history line for that input, empty on a miss
__cmux_ghost_prompt_key= # prompt identity __cmux_ghost_prompt_width belongs to
__cmux_ghost_prompt_width=0
__cmux_ghost_column=0    # screen column where the painted suggestion starts
__cmux_ghost_echoctl=2   # width of readline's ^C echo, 0 when it is off
# `fc` prints its answer; a pipe this shell holds open for reading and
# writing carries it back without a command substitution's fork.
exec {__cmux_ghost_fd}<> <(:) || return 0

# The most recent history entry that starts with $1, or empty. A numeric
# argument names an entry number in `fc`, and a multi-line entry cannot be
# completed on one line, so both yield no suggestion.
__cmux_ghost_lookup() {
  __cmux_ghost_match=
  [[ $1 =~ ^-?[0-9]+$ ]] && return 0
  local line count=0
  { fc -ln -- "$1" "$1" 2>/dev/null; printf '\036\n'; } >&"$__cmux_ghost_fd"
  while IFS= read -r -u "$__cmux_ghost_fd" line && [[ $line != $'\036' ]]; do
    ((count++)) || __cmux_ghost_match=$line
  done
  ((count == 1)) || { __cmux_ghost_match=; return 0; }
  __cmux_ghost_match=${__cmux_ghost_match#$'\t'}
  __cmux_ghost_match=${__cmux_ghost_match# }
  [[ $__cmux_ghost_match == "$1"* ]] || __cmux_ghost_match=
}

# The width of the prompt's last line, cached per prompt. ${PS1@P} expands the
# prompt the way readline does; \[ \] spans become \001 \002 and are dropped.
__cmux_ghost_measure_prompt() {
  local key="$HISTCMD:$PS1:$PWD:$COLUMNS"
  [[ $key == "$__cmux_ghost_prompt_key" ]] && return 0
  local prompt=${PS1@P} visible=
  prompt=${prompt##*$'\n'}
  while [[ $prompt == *$'\001'* ]]; do
    visible+=${prompt%%$'\001'*}
    prompt=${prompt#*$'\001'}
    [[ $prompt == *$'\002'* ]] && prompt=${prompt#*$'\002'} || prompt=
  done
  visible+=$prompt
  __cmux_ghost_prompt_width=${#visible}
  __cmux_ghost_prompt_key=$key
}

# Choose the suggestion for the current input and paint it.
__cmux_ghost_suggest() {
  __cmux_ghost_shown=
  local line=$READLINE_LINE match=
  ((READLINE_POINT == ${#line})) || return 0
  [[ $line && $line != *$'\n'* ]] || return 0
  # Typing along an earlier answer needs no lookup: a match that still fits
  # is still the newest one, and a miss stays a miss.
  if ! [[ $__cmux_ghost_prefix && $line == "$__cmux_ghost_prefix"* ]] \
    || [[ $__cmux_ghost_match && $__cmux_ghost_match != "$line"* ]]; then
    __cmux_ghost_lookup "$line"
  fi
  __cmux_ghost_prefix=$line
  match=$__cmux_ghost_match
  ((${#match} > ${#line})) || return 0

  local columns=${COLUMNS:-80} end row column room ghost=${match:${#line}}
  __cmux_ghost_measure_prompt
  end=$((__cmux_ghost_prompt_width + ${#line}))
  row=$((end / columns))
  column=$((end % columns))
  room=$((columns - column - 1))
  ((room > 0)) || return 0
  ghost=${ghost:0:room}
  __cmux_ghost_shown=$ghost
  __cmux_ghost_column=$column
  # Readline has cleared the input line and left the cursor where the
  # prompt's last line starts. Newlines (not cursor-down) reach a row past
  # the bottom of the screen by scrolling, exactly as readline's redraw will.
  local down=
  ((row > 0)) && printf -v down '%*s' "$row" '' && down=${down// /$'\n'}
  local right=
  ((column > 0)) && printf -v right '\e[%dC' "$column"
  printf '\r%s%s%s%s\e[0m\r' "$down" "$right" "$__cmux_ghost_color" "$ghost"
  ((row > 0)) && printf '\e[%dA' "$row"
  return 0
}

# Printable keys: insert the character at the cursor, then suggest.
__cmux_ghost_insert() {
  READLINE_LINE=${READLINE_LINE:0:READLINE_POINT}$1${READLINE_LINE:READLINE_POINT}
  ((READLINE_POINT += ${#1}))
  __cmux_ghost_suggest
}

# Backspace shortens the line, and readline's redraw then clears to the end
# of the line, erasing a suggestion painted before it. The key is therefore a
# macro of two commands: delete, then repaint over an unchanged line.
__cmux_ghost_backspace() {
  if ((READLINE_POINT > 0)); then
    READLINE_LINE=${READLINE_LINE:0:READLINE_POINT-1}${READLINE_LINE:READLINE_POINT}
    ((READLINE_POINT--))
  fi
  __cmux_ghost_prefix=
  __cmux_ghost_shown=
}

__cmux_ghost_repaint() {
  __cmux_ghost_suggest
}

# Right, End, Ctrl-E, Ctrl-F: accept the suggestion, else move as usual.
__cmux_ghost_accept() {
  if [[ $__cmux_ghost_shown ]] && ((READLINE_POINT == ${#READLINE_LINE})); then
    READLINE_LINE=$__cmux_ghost_match
    READLINE_POINT=${#READLINE_LINE}
  elif [[ $1 == end ]]; then
    READLINE_POINT=${#READLINE_LINE}
  elif ((READLINE_POINT < ${#READLINE_LINE})); then
    ((READLINE_POINT++))
  fi
  __cmux_ghost_suggest
}

# Alt-F, Alt-Right: accept the next word of the suggestion, else move one
# word forward the way readline's forward-word does.
__cmux_ghost_accept_word() {
  local rest
  if [[ $__cmux_ghost_shown ]] && ((READLINE_POINT == ${#READLINE_LINE})); then
    rest=$__cmux_ghost_shown
  else
    rest=${READLINE_LINE:READLINE_POINT}
  fi
  [[ $rest =~ ^[^[:alnum:]]*[[:alnum:]]* ]]
  rest=${BASH_REMATCH[0]}
  if [[ $__cmux_ghost_shown ]] && ((READLINE_POINT == ${#READLINE_LINE})); then
    READLINE_LINE+=$rest
  fi
  ((READLINE_POINT += ${#rest}))
  __cmux_ghost_suggest
}

# Before Enter: the command is about to join the history, so forget the
# cached answer.
__cmux_ghost_commit() {
  __cmux_ghost_shown=
  __cmux_ghost_prefix=
  __cmux_ghost_match=
}

# Ctrl-C at the prompt is a signal, not a key: readline prints ^C and a
# newline without running a binding, leaving the suggestion on the screen.
# Before the next prompt, erase it from the row above (after the ^C). Bash
# reports status 130 for exactly this case.
__cmux_ghost_prompt() {
  local status=$?
  if [[ $__cmux_ghost_shown ]] && ((status == 130)); then
    printf '\e[A\e[%dG\e[K\e[B\r' "$((__cmux_ghost_column + __cmux_ghost_echoctl + 1))"
  fi
  __cmux_ghost_shown=
  __cmux_ghost_prefix=
  __cmux_ghost_match=
  return "$status"
}

# Before any other editing command: drop the painted suggestion (the
# `bind -x` redraw erases it).
__cmux_ghost_clear() {
  __cmux_ghost_shown=
}

__cmux_ghost_bind() {
  local code octal char key
  for ((code = 32; code < 127; code++)); do
    printf -v octal %03o "$code"
    printf -v char "\\$octal"
    key=$char
    [[ $char == [\"\\] ]] && key=\\$char
    printf -v char %q "$char"
    bind -m emacs -x "\"$key\": __cmux_ghost_insert $char"
  done
  local seq
  bind -m emacs -x '"\e[9103~": __cmux_ghost_backspace'
  bind -m emacs -x '"\e[9104~": __cmux_ghost_repaint'
  for seq in '\C-?' '\C-h'; do bind -m emacs "\"$seq\": \"\e[9103~\e[9104~\""; done
  for seq in '\e[C' '\eOC' '\C-f'; do bind -m emacs -x "\"$seq\": __cmux_ghost_accept char"; done
  for seq in '\e[F' '\eOF' '\e[4~' '\C-e'; do bind -m emacs -x "\"$seq\": __cmux_ghost_accept end"; done
  for seq in '\ef' '\e[1;3C' '\e[1;9C'; do bind -m emacs -x "\"$seq\": __cmux_ghost_accept_word"; done

  # Commands readline runs itself are routed through a private key that
  # clears the suggestion first. Private keys are CSI sequences no terminal
  # sends, one per readline function.
  bind -m emacs -x '"\e[9101~": __cmux_ghost_commit'
  bind -m emacs -x '"\e[9102~": __cmux_ghost_clear'
  local binding function index=9110 private
  local -A routed=()
  while IFS= read -r binding; do
    [[ $binding == \"*\":\ * ]] || continue
    key=${binding%\": *}\"
    function=${binding##*\": }
    case $function in
      accept-line | operate-and-get-next) private='\e[9101~' ;;
      backward-char | backward-word | beginning-of-line | unix-line-discard | unix-word-rubout | \
        backward-kill-word | backward-kill-line | kill-line | kill-word | kill-whole-line | yank | yank-pop | \
        previous-history | next-history | beginning-of-history | end-of-history | \
        history-search-backward | history-search-forward | reverse-search-history | forward-search-history | \
        complete | menu-complete | menu-complete-backward | possible-completions | insert-completions | \
        transpose-chars | transpose-words | capitalize-word | downcase-word | upcase-word | undo | revert-line | \
        shell-expand-line | history-expand-line | glob-expand-word | glob-list-expansions | edit-and-execute-command) private='\e[9102~' ;;
      *) continue ;;
    esac
    case $key in
      '"\e[91'*) continue ;;
    esac
    if [[ -z ${routed[$function]-} ]]; then
      routed[$function]="\\e[$index~"
      bind -m emacs "\"\\e[$index~\": $function"
      ((index++))
    fi
    bind -m emacs "$key: \"$private${routed[$function]}\""
  done < <(bind -m emacs -p 2>/dev/null)
  [[ $(bind -v 2>/dev/null) == *'set echo-control-characters off'* ]] && __cmux_ghost_echoctl=0

  if ((BASH_VERSINFO[0] > 5 || BASH_VERSINFO[1] >= 1)); then
    PROMPT_COMMAND=(__cmux_ghost_prompt "${PROMPT_COMMAND[@]}")
  else
    PROMPT_COMMAND="__cmux_ghost_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
  fi
}

__cmux_ghost_bind
unset -f __cmux_ghost_bind
