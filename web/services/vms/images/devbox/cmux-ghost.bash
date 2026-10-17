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
# The suggestion is never part of the line buffer: Enter, Tab, Ctrl-R and
# every other readline command see exactly what was typed. Readline redraws
# the input line after each `bind -x` command, so the suggestion is painted
# first, at the column where the typed text will end, and readline's redraw
# writes the prompt and input in front of it. Readline's own commands stay
# bound to their functions (Tab Tab, yank-pop, kill accumulation, incremental
# search and numeric arguments depend on that); only Enter and history
# movement first drop the suggestion.
case $- in *i*) ;; *) return 0 ;; esac
((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1))) || return 0
[[ -z ${__cmux_ghost_loaded-} && -t 2 && $TERM != dumb ]] || return 0
__cmux_ghost_loaded=1

__cmux_ghost_color=${CMUX_GHOST_COLOR-$'\e[38;5;245m'}
__cmux_ghost_shown=      # suffix painted after the cursor, empty when none
__cmux_ghost_prefix=     # input for which __cmux_ghost_match was computed
__cmux_ghost_match=      # full history line for that input, empty on a miss
__cmux_ghost_prompt_key= # prompt identity __cmux_ghost_prompt_width belongs to
__cmux_ghost_prompt_width=0
__cmux_ghost_prompt_text= # the prompt's last line, as drawn
__cmux_ghost_column=0    # screen column where the painted suggestion starts
__cmux_ghost_echoctl=2   # width of readline's ^C echo, 0 when it is off
__cmux_ghost_file=       # private per-shell file `fc` writes its answer to
__cmux_ghost_hold=       # set when readline's redraw ends the held update

# `fc` prints its answer. A per-shell file in the user's private directory
# carries it back without a command substitution's fork, and unlike a pipe it
# cannot fill up on a long history entry. The file is emptied after every
# read, so no history text outlives the lookup, and a later shell with the
# same pid reuses it instead of leaving another file behind.
__cmux_ghost_answer_file() {
  local directory=${TMPDIR:-/tmp}/cmux-ghost-$UID
  [[ $__cmux_ghost_file && -d $directory ]] && return 0
  if [[ ! -d $directory ]]; then mkdir -m 700 "$directory" 2>/dev/null || return 1; fi
  [[ -d $directory && ! -L $directory && -O $directory ]] || return 1
  chmod 700 "$directory" 2>/dev/null || return 1
  __cmux_ghost_file=$directory/answer.$$
}

# The most recent history entry that starts with $1, or empty. `fc` reads an
# argument that starts with a digit as an entry number, and a multi-line entry
# cannot be completed on one line, so both yield no suggestion.
__cmux_ghost_lookup() {
  __cmux_ghost_match=
  [[ $1 == [0-9]* || $1 == -[0-9]* ]] && return 0
  __cmux_ghost_answer_file || return 0
  fc -ln -- "$1" "$1" >| "$__cmux_ghost_file" 2>/dev/null || return 0
  local line count=0
  while IFS= read -r line; do
    count=$((count + 1))
    if ((count == 1)); then __cmux_ghost_match=$line; fi
  done < "$__cmux_ghost_file"
  : >| "$__cmux_ghost_file"
  if ((count != 1)); then
    __cmux_ghost_match=
    return 0
  fi
  __cmux_ghost_match=${__cmux_ghost_match#$'\t'}
  __cmux_ghost_match=${__cmux_ghost_match# }
  [[ $__cmux_ghost_match == "$1"* ]] || __cmux_ghost_match=
  return 0
}

# The prompt's last line as readline draws it, measured once per prompt.
# ${PS1@P} expands the prompt the way readline does; \[ \] spans become
# \001 \002, which are kept (without the markers) in the text and dropped
# from the width.
__cmux_ghost_measure_prompt() {
  local key="$PS1:$PWD:$COLUMNS"
  [[ $key == "$__cmux_ghost_prompt_key" ]] && return 0
  local prompt=${PS1@P} visible= text=
  prompt=${prompt##*$'\n'}
  while [[ $prompt == *$'\001'* ]]; do
    visible+=${prompt%%$'\001'*}
    text+=${prompt%%$'\001'*}
    prompt=${prompt#*$'\001'}
    if [[ $prompt == *$'\002'* ]]; then
      text+=${prompt%%$'\002'*}
      prompt=${prompt#*$'\002'}
    else
      prompt=
    fi
  done
  visible+=$prompt
  text+=$prompt
  __cmux_ghost_prompt_width=${#visible}
  __cmux_ghost_prompt_text=$text
  __cmux_ghost_prompt_key=$key
  return 0
}

# Choose the suggestion for the current input and draw the line with it.
__cmux_ghost_suggest() {
  __cmux_ghost_shown=
  local line=$READLINE_LINE ghost=
  if ((READLINE_POINT == ${#line})) && [[ $line && $line != *$'\n'* ]]; then
    # Typing along an earlier answer needs no lookup: a match that still
    # fits is still the newest one, and a miss stays a miss.
    if ! [[ $__cmux_ghost_prefix && $line == "$__cmux_ghost_prefix"* ]] \
      || [[ $__cmux_ghost_match && $__cmux_ghost_match != "$line"* ]]; then
      __cmux_ghost_lookup "$line"
    fi
    __cmux_ghost_prefix=$line
    ((${#__cmux_ghost_match} > ${#line})) && ghost=${__cmux_ghost_match:${#line}}
  fi
  __cmux_ghost_draw "$ghost"
}

# Bash writes each `bind -x` key in three pieces: it clears the input line,
# runs the command, then redraws the line. A frame shown between pieces is a
# blank line or a cursor at column 0 (flicker). Every handler therefore
# starts a synchronized update (DEC mode 2026) as its first output, and the
# invisible readline mode string that begins readline's redraw ends it, in
# the same write as the redrawn line, so each key shows as one frame. When
# that mode string could not be installed, the update is ended here instead.
#
# This draws the prompt's last line, the input and the suggestion, and leaves
# the cursor where the clear left it; readline then writes the same text over
# it. Readline draws on stderr, and so does this.
__cmux_ghost_draw() {
  local line=$READLINE_LINE ghost=$1
  # Control characters draw differently from their length; leave those
  # lines to readline alone.
  [[ $line == *[[:cntrl:]]* || $ghost == *[[:cntrl:]]* ]] && return 0
  __cmux_ghost_measure_prompt
  local columns=${COLUMNS:-80} end row column room up out
  end=$((__cmux_ghost_prompt_width + ${#line}))
  row=$((end / columns))
  column=$((end % columns))
  room=$((columns - column - 1))
  if ((room > 0)); then ghost=${ghost:0:room}; else ghost=; fi
  out=$'\r'$__cmux_ghost_prompt_text$line
  [[ $__cmux_ghost_hold ]] || out=$'\e[?2026h'$out
  if [[ $ghost ]]; then
    __cmux_ghost_shown=$ghost
    __cmux_ghost_column=$column
    printf -v out '%s%s%s\e[0m\e[%dD' "$out" "$__cmux_ghost_color" "$ghost" "${#ghost}"
    up=$row
  elif ((end > 0 && column == 0)); then
    # A line that ends exactly at the margin leaves the cursor on its last
    # row until the next character wraps it.
    up=$((row - 1))
  else
    up=$row
  fi
  out+=$'\r'
  if ((up > 0)); then printf -v out '%s\e[%dA' "$out" "$up"; fi
  [[ $__cmux_ghost_hold ]] || out+=$'\e[?2026l'
  printf '%s' "$out" >&2
  return 0
}

# Printable keys: insert the character at the cursor, then suggest.
__cmux_ghost_insert() {
  [[ $__cmux_ghost_hold ]] && printf '\e[?2026h' >&2
  READLINE_LINE=${READLINE_LINE:0:READLINE_POINT}$1${READLINE_LINE:READLINE_POINT}
  READLINE_POINT=$((READLINE_POINT + ${#1}))
  __cmux_ghost_suggest
}

# True when the painted suggestion still belongs to the line as it is now.
# Edits made outside these bindings (paste, Tab, yank, non-ASCII input) leave
# the cache describing an older line.
__cmux_ghost_current() {
  [[ $__cmux_ghost_shown && $READLINE_LINE == "$__cmux_ghost_prefix" \
    && $__cmux_ghost_match == "$READLINE_LINE"* ]] && ((READLINE_POINT == ${#READLINE_LINE}))
}

# Right, End, Ctrl-E, Ctrl-F: accept the suggestion, else move as usual.
__cmux_ghost_accept() {
  [[ $__cmux_ghost_hold ]] && printf '\e[?2026h' >&2
  if __cmux_ghost_current; then
    READLINE_LINE=$__cmux_ghost_match
    READLINE_POINT=${#READLINE_LINE}
  elif [[ $1 == end ]]; then
    READLINE_POINT=${#READLINE_LINE}
  elif ((READLINE_POINT < ${#READLINE_LINE})); then
    READLINE_POINT=$((READLINE_POINT + 1))
  fi
  __cmux_ghost_suggest
}

# Alt-F, Alt-Right: accept the next word of the suggestion, else move one
# word forward the way readline's forward-word does.
__cmux_ghost_accept_word() {
  [[ $__cmux_ghost_hold ]] && printf '\e[?2026h' >&2
  local rest accepting=
  if __cmux_ghost_current; then
    accepting=1
    rest=${__cmux_ghost_match:${#READLINE_LINE}}
  else
    rest=${READLINE_LINE:READLINE_POINT}
  fi
  [[ $rest =~ ^[^[:alnum:]]*[[:alnum:]]* ]]
  rest=${BASH_REMATCH[0]}
  if [[ $accepting ]]; then READLINE_LINE+=$rest; fi
  READLINE_POINT=$((READLINE_POINT + ${#rest}))
  __cmux_ghost_suggest
}

# Before Enter and history movement: drop the painted suggestion (the
# `bind -x` redraw erases it) and forget the cached answer, since the history
# is about to change or the line is about to be replaced.
__cmux_ghost_clear() {
  [[ $__cmux_ghost_hold ]] && printf '\e[?2026h' >&2
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
    printf '\e[A\e[%dG\e[K\e[B\r' "$((__cmux_ghost_column + __cmux_ghost_echoctl + 1))" >&2
  fi
  __cmux_ghost_clear
  __cmux_ghost_prompt_key=
  return "$status"
}

__cmux_ghost_bind() {
  local binding key function code octal char seq index=9110
  local -A self_insert=() routed=() privates=()
  # Printable keys a user's inputrc bound to something else (magic-space,
  # for example) keep that binding.
  while IFS= read -r binding; do
    [[ $binding == \"*\":\ * ]] || continue
    key=${binding%\": *}
    key=${key#\"}
    function=${binding##*\": }
    case $function in
      self-insert) self_insert[$key]=1 ;;
      accept-line | operate-and-get-next | previous-history | next-history | \
        beginning-of-history | end-of-history) routed[$key]=$function ;;
    esac
  done < <(bind -m emacs -p 2>/dev/null)

  for ((code = 32; code < 127; code++)); do
    printf -v octal %03o "$code"
    printf -v char "\\$octal"
    key=$char
    [[ $char == [\"\\] ]] && key=\\$char
    [[ ${self_insert[$key]-} ]] || continue
    printf -v char %q "$char"
    bind -m emacs -x "\"$key\": __cmux_ghost_insert $char"
  done
  for seq in '\e[C' '\eOC' '\C-f'; do bind -m emacs -x "\"$seq\": __cmux_ghost_accept char"; done
  for seq in '\e[F' '\eOF' '\e[4~' '\e[8~' '\C-e'; do bind -m emacs -x "\"$seq\": __cmux_ghost_accept end"; done
  for seq in '\ef' '\e[1;3C' '\e[1;9C'; do bind -m emacs -x "\"$seq\": __cmux_ghost_accept_word"; done

  # Enter and history movement run their readline function behind a private
  # key that drops the suggestion first. Private keys are CSI sequences no
  # terminal sends, one per readline function.
  bind -m emacs -x '"\e[9101~": __cmux_ghost_clear'
  for key in "${!routed[@]}"; do
    function=${routed[$key]}
    if [[ -z ${privates[$function]-} ]]; then
      privates[$function]="\\e[$index~"
      bind -m emacs "\"\\e[$index~\": $function"
      index=$((index + 1))
    fi
    bind -m emacs "\"$key\": \"\\e[9101~${privates[$function]}\""
  done
  local variables
  variables=$(bind -v 2>/dev/null)
  [[ $variables == *'set echo-control-characters off'* ]] && __cmux_ghost_echoctl=0
  # Readline prints the mode string first whenever it redraws the prompt's
  # last line, so an invisible one ends the update each handler started.
  # A user's own mode strings are left alone.
  if [[ $variables == *'set show-mode-in-prompt off'* ]]; then
    bind 'set emacs-mode-string "\1\e[?2026l\2"'
    bind 'set vi-ins-mode-string "\1\e[?2026l\2"'
    bind 'set vi-cmd-mode-string "\1\e[?2026l\2"'
    bind 'set show-mode-in-prompt on'
    __cmux_ghost_hold=1
  fi

  PROMPT_COMMAND=(__cmux_ghost_prompt "${PROMPT_COMMAND[@]}")
  return 0
}

__cmux_ghost_bind
unset -f __cmux_ghost_bind
