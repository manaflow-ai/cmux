
# cmux-tui: a prompt that the terminal cleared on a resize is always drawn
# again. The prompt mark (OSC 133;A;redraw=1) tells the terminal that zsh
# redraws its prompt on a resize, so the terminal (ghostty-vt
# Screen.clearPromptForRedraw) clears the prompt rows on every grid change.
# zsh redraws on SIGWINCH only when the size it reads differs from the size
# it read before (Src/utils.c adjustwinsize). When the size goes 34 -> 35 ->
# 34 before zsh reads it (both SIGWINCHes handled as one), zsh reads 34,
# draws nothing, and the cleared prompt never comes back: a new pane shows
# an empty screen with the cursor after the prompt (close-then-type P0).
# So when a SIGWINCH finds the size zsh drew at, this trap redraws the
# prompt itself. A real size change keeps zsh's own redraw, with no second
# one. No fork, no delay: a SIGWINCH with a new size only records it.
# The size note runs before each prompt, since zsh also reads the size when
# a foreground job ends (it gets no SIGWINCH while the job runs). Installed
# from the first precmd, after .zshrc; a TRAPWINCH of the user's startup
# files still runs, first.
_cmux_tui_prompt_size=
_cmux_tui_prompt_size_note() {
    builtin local -i ret=$?
    _cmux_tui_prompt_size=$COLUMNS:$LINES
    builtin return ret
}
_cmux_tui_prompt_winch() {
    builtin emulate -L zsh -o no_aliases
    # adjustwinsize has set COLUMNS and LINES before the trap runs.
    builtin local size=$COLUMNS:$LINES
    if [[ $size == "$_cmux_tui_prompt_size" ]] && zle; then
        zle .reset-prompt
    fi
    _cmux_tui_prompt_size=$size
}
_cmux_tui_prompt_redraw_install() {
    builtin local -i ret=$?
    builtin emulate -L zsh -o no_aliases
    builtin typeset -ag precmd_functions
    precmd_functions=("${(@)precmd_functions:#_cmux_tui_prompt_redraw_install}")
    # First, so the integration's own precmd stays last (it puts its marks
    # in PS1 only then).
    precmd_functions=(_cmux_tui_prompt_size_note "${(@)precmd_functions:#_cmux_tui_prompt_size_note}")
    if (( $+functions[TRAPWINCH] )) && [[ $functions[TRAPWINCH] != *_cmux_tui_prompt_winch* ]]; then
        functions[_cmux_tui_user_trapwinch]=$functions[TRAPWINCH]
    fi
    # A trap function's non-zero status makes zsh act as if interrupted, so
    # the trap returns the user's status only.
    TRAPWINCH() {
        builtin local -i ret=0
        if (( $+functions[_cmux_tui_user_trapwinch] )); then
            _cmux_tui_user_trapwinch "$@"
            ret=$?
        fi
        _cmux_tui_prompt_winch
        builtin return ret
    }
    _cmux_tui_prompt_size_note
    builtin unfunction _cmux_tui_prompt_redraw_install
    builtin return ret
}
if [[ -o interactive ]]; then
    () {
        builtin emulate -L zsh -o no_aliases
        builtin typeset -ag precmd_functions
        precmd_functions+=(_cmux_tui_prompt_redraw_install)
    }
fi
