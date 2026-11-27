
# cmux-tui: a freed (parked) terminal comes back with the shell state the
# person left, not only its directory (shell_state.rs).
#
# $CMUX_TUI_SHELL_STATE is a path prefix in the daemon's private state
# directory, one per terminal. Save: the daemon writes a nonce to
# PREFIX.request and sends this shell SIGWINCH (ignored by default, so a
# program without this script is unharmed); the trap writes PREFIX.history, then
# PREFIX.state, whose last line `# end NONCE` is the ack. Restore: before the
# new shell starts, the daemon renames them to PREFIX.restore and
# PREFIX.restore-history; this script sources them after the startup files
# ran (their state first, the saved state wins), deletes them and prints
# nothing. Nothing runs on a prompt: the only cost per shell is the trap.
# Sourced at top level, so the saved declarations stay global.
if [[ -n "${CMUX_TUI_SHELL_STATE-}" ]] \
  && (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then

  # The fds open once the startup files ran: theirs, which the new shell's
  # startup files open again. Any other fd at save time is one the person
  # opened, which no restore can give back. Read in the same redirection the
  # trap runs under, so bash's own saved stderr copy is in it.
  _cmux_tui_state_fd_baseline() {
    _cmux_tui_state_fds=""
    builtin local fd
    for (( fd = 3; fd < 64; fd++ )); do
      [[ -e /dev/fd/$fd ]] && _cmux_tui_state_fds+=" $fd "
    done
  }

  # Why this shell cannot be saved (empty: it can): an fd the person opened.
  _cmux_tui_state_unsaveable_fd() {
    _cmux_tui_state_why=""
    builtin local fd
    for (( fd = 3; fd < 64; fd++ )); do
      if [[ -e /dev/fd/$fd && "$_cmux_tui_state_fds" != *" $fd "* ]]; then
        _cmux_tui_state_why="open-fd-$fd"
        builtin return
      fi
    done
  }

  # Jobs (a coproc is one): a stopped or background program would end with
  # the shell. The list goes through the state file, so no fork.
  _cmux_tui_state_unsaveable_jobs() {
    builtin jobs -p >|"$CMUX_TUI_SHELL_STATE.state" 2>/dev/null
    if [[ -s "$CMUX_TUI_SHELL_STATE.state" ]]; then
      _cmux_tui_state_why="jobs"
    fi
  }

  # The variables a restore must not set: bash's own and per-process ones,
  # the terminal's identity and integration (the new shell has its own),
  # and the integration's state.
  _cmux_tui_state_skip_var() {
    case "$1" in
      BASH_COMPAT|BASH_ENV) builtin return 1 ;;
      BASH*|COMP_CWORD|COMP_KEY|COMP_LINE|COMP_POINT|COMP_TYPE|COMP_WORDS|COPROC*|READLINE_*) ;;
      _|COLUMNS|LINES|DIRSTACK|EPOCHREALTIME|EPOCHSECONDS|EUID|UID|FUNCNAME|GROUPS|HISTCMD) ;;
      HOSTNAME|HOSTTYPE|MACHTYPE|OSTYPE|LINENO|PIPESTATUS|PPID|PWD|RANDOM|SRANDOM|SECONDS) ;;
      SHELLOPTS|SHLVL|OPTIND|OPTARG|PS1|PS2|ENV) ;;
      TERM|TERMINFO|TERM_PROGRAM|TERM_PROGRAM_VERSION|COLORTERM) ;;
      CMUX_*|GHOSTTY_*|_GHOSTTY_*|_ghostty_*|__ghostty_*|_cmux_tui_*|__cmux_*|__bp_*) ;;
      bash_preexec_imported) ;;
      *) builtin return 1 ;;
    esac
  }

  _cmux_tui_state_skip_function() {
    case "$1" in
      _cmux_tui_*|__ghostty_*|_ghostty_*|__bp_*) ;;
      *) builtin return 1 ;;
    esac
  }

  # The SIGWINCH handler: write the state for the request in PREFIX.request.
  # SIGWINCH because readline catches it, so bash runs the trap at once
  # while it waits at the prompt (a signal readline does not catch waits
  # for the next command line), and its default is to be ignored, so a
  # program without this trap is unharmed. A real resize finds no request
  # and costs one file test. Its stderr goes nowhere (the trap's
  # redirection), so no error and no xtrace line reaches the screen.
  _cmux_tui_state_save() {
    [[ -r "$CMUX_TUI_SHELL_STATE.request" ]] || builtin return 0
    builtin local - _cmux_tui_nonce="" _cmux_tui_name _cmux_tui_attrs _cmux_tui_i _cmux_tui_umask _cmux_tui_flags=$-
    local -a _cmux_tui_vars=() _cmux_tui_local=() _cmux_tui_funcs=()
    # The person's -e, -u and -x, before this function turns them off (`local -`
    # gives them back when it returns).
    builtin set +e +u +x
    # Before any redirection or substitution opens an fd of its own.
    _cmux_tui_state_unsaveable_fd
    builtin read -r _cmux_tui_nonce <"$CMUX_TUI_SHELL_STATE.request" || [[ -n "$_cmux_tui_nonce" ]] \
      || builtin return 0
    _cmux_tui_umask=$(builtin umask)
    builtin umask 077
    [[ -n "$_cmux_tui_state_why" ]] || _cmux_tui_state_unsaveable_jobs
    if [[ -n "$_cmux_tui_state_why" ]]; then
      builtin printf '# cmux-tui shell state 1 bash unsaveable %s\n# end %s\n' \
        "$_cmux_tui_state_why" "$_cmux_tui_nonce" >|"$CMUX_TUI_SHELL_STATE.state"
      builtin umask "$_cmux_tui_umask"
      builtin return 0
    fi
    # History: the user's file gets this session's lines, as a clean exit
    # does; the restore gets the in-memory list. An incognito terminal
    # writes none.
    if [[ -z "${CMUX_TUI_INCOGNITO-}" && "$-" == *i* ]]; then
      if [[ -n "${HISTFILE-}" && "$HISTFILE" != /dev/null ]]; then
        builtin history -a 2>/dev/null
      fi
      builtin history -w "$CMUX_TUI_SHELL_STATE.history" 2>/dev/null
    else
      builtin command rm -f -- "$CMUX_TUI_SHELL_STATE.history" 2>/dev/null
    fi
    while IFS= builtin read -r _cmux_tui_name; do
      _cmux_tui_state_skip_var "$_cmux_tui_name" && continue
      _cmux_tui_attrs=${!_cmux_tui_name@a}
      [[ "$_cmux_tui_attrs" == *r* ]] && continue
      _cmux_tui_vars+=("$_cmux_tui_name")
      [[ "$_cmux_tui_attrs" == *x* ]] || _cmux_tui_local+=("$_cmux_tui_name")
    done < <(builtin compgen -v)
    while IFS= builtin read -r _cmux_tui_name; do
      _cmux_tui_state_skip_function "$_cmux_tui_name" || _cmux_tui_funcs+=("$_cmux_tui_name")
    done < <(builtin compgen -A function)
    {
      builtin printf '# cmux-tui shell state 1 bash ok\n'
      builtin printf 'builtin cd -- %q\n' "$PWD"
      builtin printf 'builtin dirs -c\n'
      for (( _cmux_tui_i = ${#DIRSTACK[@]} - 1; _cmux_tui_i >= 1; _cmux_tui_i-- )); do
        builtin printf 'builtin pushd -n -- %q\n' "${DIRSTACK[_cmux_tui_i]}"
      done
      builtin printf 'builtin umask %s\n' "$_cmux_tui_umask"
      # login_shell and restricted_shell cannot be set: their lines fail
      # quietly.
      builtin shopt -p
      # Not `history`: set during startup, it would put the rest of this
      # file into the history list (bash turns it on after startup).
      while IFS= builtin read -r _cmux_tui_name; do
        [[ "$_cmux_tui_name" == *" history" ]] || builtin printf '%s\n' "$_cmux_tui_name"
      done < <(builtin set +o)
      # Functions before aliases: an alias would expand in a definition.
      builtin printf 'builtin unalias -a\n'
      (( ${#_cmux_tui_funcs[@]} )) && builtin declare -f -- "${_cmux_tui_funcs[@]}"
      (( ${#_cmux_tui_vars[@]} )) && builtin declare -p -- "${_cmux_tui_vars[@]}"
      (( ${#_cmux_tui_local[@]} )) && builtin printf 'builtin export -n -- %s\n' "${_cmux_tui_local[@]}"
      # The prompt the person set, without the marks the integration adds
      # at each prompt (the new shell adds them again).
      if [[ "${_ghostty_executing-}" == 0 ]]; then
        builtin printf 'PS1=%q\nPS2=%q\n' "${_GHOSTTY_SAVE_PS1-$PS1}" "${_GHOSTTY_SAVE_PS2-$PS2}"
      else
        builtin printf 'PS1=%q\nPS2=%q\n' "$PS1" "$PS2"
      fi
      builtin trap -p
      builtin complete -p
      builtin alias -p
      # Last, so no line above runs under them; never -e, under which one
      # failing line of the startup that follows would end the shell.
      [[ "$_cmux_tui_flags" == *u* ]] && builtin printf 'builtin set -u\n'
      [[ "$_cmux_tui_flags" == *x* ]] && builtin printf 'builtin set -x\n'
      builtin printf '# end %s\n' "$_cmux_tui_nonce"
    } >|"$CMUX_TUI_SHELL_STATE.state" 2>/dev/null
    builtin umask "$_cmux_tui_umask"
  }

  builtin trap '_cmux_tui_state_save 2>/dev/null' WINCH
  _cmux_tui_state_fd_baseline 2>/dev/null

  # A freed terminal's new shell: the saved state, after the startup files.
  if [[ -f "$CMUX_TUI_SHELL_STATE.restore" && -O "$CMUX_TUI_SHELL_STATE.restore" ]]; then
    builtin source "$CMUX_TUI_SHELL_STATE.restore" >/dev/null 2>&1
    # The saved traps replaced this one if it differed.
    builtin trap '_cmux_tui_state_save 2>/dev/null' WINCH
    builtin command rm -f -- "$CMUX_TUI_SHELL_STATE.restore" 2>/dev/null
    # History: bash reads $HISTFILE into its list after this script, so the
    # saved list goes in that way (`history -r` here would get the user's
    # file appended after it). The person's HISTFILE comes back before the
    # first prompt, so lines typed from now on reach it as before; the
    # lines already in the list count as read from a file and are not
    # appended again (the save appended them, as an exit does).
    if [[ -z "${CMUX_TUI_INCOGNITO-}" && -f "$CMUX_TUI_SHELL_STATE.restore-history" ]]; then
      _cmux_tui_state_histfile_set=${HISTFILE+1}
      _cmux_tui_state_histfile=${HISTFILE-}
      HISTFILE=$CMUX_TUI_SHELL_STATE.restore-history
      # Once, first in PROMPT_COMMAND, keeping the status for the rest.
      _cmux_tui_state_after_restore() {
        builtin local status=$?
        if [[ -n "$_cmux_tui_state_histfile_set" ]]; then
          HISTFILE=$_cmux_tui_state_histfile
        else
          builtin unset HISTFILE
        fi
        builtin command rm -f -- "$CMUX_TUI_SHELL_STATE.restore-history" 2>/dev/null
        if [[ ${PROMPT_COMMAND@a} == *a* ]]; then
          [[ "${PROMPT_COMMAND[0]}" == _cmux_tui_state_after_restore ]] \
            && PROMPT_COMMAND=("${PROMPT_COMMAND[@]:1}")
        else
          PROMPT_COMMAND=${PROMPT_COMMAND#_cmux_tui_state_after_restore;}
        fi
        builtin unset _cmux_tui_state_histfile_set _cmux_tui_state_histfile
        builtin unset -f _cmux_tui_state_after_restore
        builtin return "$status"
      }
      if [[ ${PROMPT_COMMAND@a} == *a* ]]; then
        PROMPT_COMMAND=(_cmux_tui_state_after_restore "${PROMPT_COMMAND[@]}")
      else
        PROMPT_COMMAND="_cmux_tui_state_after_restore;${PROMPT_COMMAND-}"
      fi
    else
      builtin command rm -f -- "$CMUX_TUI_SHELL_STATE.restore-history" 2>/dev/null
    fi
  fi
fi
