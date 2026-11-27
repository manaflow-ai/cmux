
# cmux-tui: a terminal of an incognito workspace ($CMUX_TUI_INCOGNITO) keeps
# no history. The daemon starts zsh with HISTFILE=/dev/null, but startup
# files set HISTFILE again (macOS /etc/zshrc does, unconditionally), so each
# prompt unsets it and SAVEHIST: zsh then writes no history file, at a
# command (inc_append_history, share_history) or at exit. zshaddhistory
# keeps each line in memory only, for a framework that sets HISTFILE again
# between prompts.
_cmux_tui_incognito_history() {
    builtin unset HISTFILE
    builtin typeset -g SAVEHIST=0
}
_cmux_tui_incognito_addhistory() {
    _cmux_tui_incognito_history
    builtin return 2
}
if [[ -o interactive && -n ${CMUX_TUI_INCOGNITO-} ]]; then
    () {
        builtin emulate -L zsh -o no_aliases
        builtin typeset -ag precmd_functions zshaddhistory_functions
        # The app's layer (Resources/cmux-cli-path/zsh/.zshenv) registers the
        # same functions; registering twice leaves one hook.
        precmd_functions=("${(@)precmd_functions:#_cmux_tui_incognito_history}" _cmux_tui_incognito_history)
        zshaddhistory_functions=("${(@)zshaddhistory_functions:#_cmux_tui_incognito_addhistory}" _cmux_tui_incognito_addhistory)
    }
fi
