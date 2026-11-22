
# cmux-tui: a terminal of an incognito workspace ($CMUX_TUI_INCOGNITO) keeps
# no history. This runs after the user's startup files, which may have set
# HISTFILE again; bash writes the history list to /dev/null.
if [[ -n "${CMUX_TUI_INCOGNITO-}" ]]; then
    HISTFILE=/dev/null
fi
