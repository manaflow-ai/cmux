# cmux-tui: a terminal of an incognito workspace ($CMUX_TUI_INCOGNITO) keeps
# no history. The daemon also exports fish_private_mode; this keeps it on for
# a fish that starts without it, and turns it on again at every prompt, after
# config.fish and anything a command changed (fish reads it per command).
if set -q CMUX_TUI_INCOGNITO; and test -n "$CMUX_TUI_INCOGNITO"
    set -g fish_private_mode 1
    function __cmux_tui_incognito_history --on-event fish_prompt
        set -g fish_private_mode 1
    end
end
