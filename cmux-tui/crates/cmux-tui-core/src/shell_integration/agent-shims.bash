
# cmux-tui: keep the agent shim directory ($CMUX_TUI_AGENT_SHIMS) first on
# PATH. Startup files commonly prepend a directory that holds the real `codex`
# or `claude` (`export PATH="$HOME/.local/bin:$PATH"`), which would start the
# agent without the terminal's hooks. Codex runs its hooks in a shared daemon
# that cannot see this terminal's environment, so only the shim can route
# them here. The startup files ran above; the prompt hook repairs later
# changes, and runs after every hook the startup files installed.
_cmux_tui_agent_shims_first() {
  builtin local ret=$? dir="${CMUX_TUI_AGENT_SHIMS-}"
  if [[ -n "$dir" && -d "$dir" && "$PATH" != "$dir" && "$PATH" != "$dir:"* ]]; then
    builtin local rest=":$PATH:"
    while [[ "$rest" == *":$dir:"* ]]; do
      rest="${rest/":$dir:"/:}"
    done
    rest="${rest#:}"
    rest="${rest%:}"
    PATH="$dir${rest:+:$rest}"
  fi
  builtin return "$ret"
}
# The app's cmux-cli-path layer carries the same block over Ghostty's script;
# whichever runs first registers the hook.
if [[ -n "${CMUX_TUI_AGENT_SHIMS-}" && -z "${_cmux_tui_agent_shims_registered-}" ]]; then
  _cmux_tui_agent_shims_registered=1
  _cmux_tui_agent_shims_first || builtin true
  # Not a bash-preexec preexec hook: a non-zero return there (the previous
  # command's status, kept for the prompt) skips the command under extdebug.
  # A nested shell can inherit PROMPT_COMMAND without the function, hence
  # the redirection, as Ghostty does for its own hook. bash runs the entries of
  # an array PROMPT_COMMAND from 5.1 on (before, only its first element, which
  # the string branch extends); `@a` reads the type without the fork of
  # `$(declare -p)`.
  if [[ -n "${bash_preexec_imported-}${__bp_imported-}" ]]; then
    precmd_functions+=(_cmux_tui_agent_shims_first)
  elif (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )) \
    && [[ ${PROMPT_COMMAND@a} == *a* ]]; then
    PROMPT_COMMAND+=("_cmux_tui_agent_shims_first 2>/dev/null")
  elif [[ -z "${PROMPT_COMMAND-}" ]]; then
    PROMPT_COMMAND="_cmux_tui_agent_shims_first 2>/dev/null"
  else
    [[ "${PROMPT_COMMAND}" =~ (\;[[:space:]]*|$'\n')$ ]] || PROMPT_COMMAND+=";"
    PROMPT_COMMAND+="_cmux_tui_agent_shims_first 2>/dev/null"
  fi
fi
