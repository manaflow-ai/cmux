
# cmux-tui: oh-my-zsh never checks for updates in a cmux terminal (Lawrence,
# 2026-11-23: "make oh-my-zsh never check for updates again"). Its check
# (tools/check_for_upgrade.sh, which oh-my-zsh.sh sources from .zshrc) forks
# git at startup and can stop before the first prompt to ask "Would you like
# to update? [Y/n]": the question takes the first keys typed and holds a
# restored terminal's resume command, which waits for a marked prompt
# (terminal_respawn prefill). The check reads the `:omz:update` `mode`
# style, so this file sets it to `disabled` before .zshrc runs, and until the
# first prompt a .zshrc that sets another mode (or deletes the style) leaves
# it `disabled`. After that, `zstyle` is the builtin again; `omz update`
# still updates when asked. The app's layer
# (Resources/cmux-cli-path/zsh/.zshenv) carries the same functions; both
# running leaves one hook.
if [[ -o interactive ]]; then
    'builtin' 'zstyle' ':omz:update' mode disabled
    zstyle() {
        'builtin' 'zstyle' "$@"
        'builtin' 'local' '-i' ret=$?
        'builtin' 'zstyle' ':omz:update' mode disabled
        'builtin' 'return' ret
    }
    'builtin' 'typeset' -g _cmux_omz_update_zstyle="${functions[zstyle]}"
    _cmux_omz_update_done() {
        # Only this file's wrapper goes; a zstyle function of the user's stays.
        [[ ${functions[zstyle]-} != "${_cmux_omz_update_zstyle-}" ]] || 'builtin' 'unfunction' zstyle
        precmd_functions=("${(@)precmd_functions:#_cmux_omz_update_done}")
        'builtin' 'unset' _cmux_omz_update_zstyle
        'builtin' 'unfunction' _cmux_omz_update_done
    }
    'builtin' 'typeset' -ag precmd_functions
    precmd_functions=(_cmux_omz_update_done "${(@)precmd_functions:#_cmux_omz_update_done}")
fi
