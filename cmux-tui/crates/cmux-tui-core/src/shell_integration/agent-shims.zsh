
# cmux-tui: keep the agent shim directory ($CMUX_TUI_AGENT_SHIMS) first on
# PATH. Startup files commonly prepend a directory that holds the real `codex`
# or `claude` (`export PATH="$HOME/.local/bin:$PATH"`), which would start the
# agent without the terminal's hooks. Codex runs its hooks in a shared daemon
# that cannot see this terminal's environment, so only the shim can route
# them here. preexec runs after every startup file and every precmd hook (some
# tool managers re-prepend their own directories at each prompt), right before
# the command line is resolved, and keeps the command's status for the prompt.
_cmux_tui_agent_shims_first() {
    builtin local -i ret=$?
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    builtin local dir=${CMUX_TUI_AGENT_SHIMS-}
    if [[ -n $dir && -d $dir && ${path[1]-} != "$dir" ]]; then
        path=("$dir" "${(@)path:#${~${(b)dir}}}")
    fi
    builtin return ret
}
# Registered from the first precmd, after .zshrc: a framework that resets
# preexec_functions there would otherwise drop the hook.
_cmux_tui_agent_shims_install() {
    builtin local -i ret=$?
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    builtin typeset -ag precmd_functions preexec_functions
    precmd_functions=("${(@)precmd_functions:#_cmux_tui_agent_shims_install}")
    preexec_functions=("${(@)preexec_functions:#_cmux_tui_agent_shims_first}" _cmux_tui_agent_shims_first)
    builtin unfunction _cmux_tui_agent_shims_install
    builtin return ret
}
if [[ -o interactive && -n ${CMUX_TUI_AGENT_SHIMS-} ]]; then
    () {
        builtin emulate -L zsh -o no_aliases
        builtin typeset -ag precmd_functions
        precmd_functions+=(_cmux_tui_agent_shims_install)
    }
fi
