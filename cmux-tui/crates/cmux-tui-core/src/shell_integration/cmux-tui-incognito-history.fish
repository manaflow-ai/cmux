# cmux-tui: a terminal of an incognito workspace ($CMUX_TUI_INCOGNITO) keeps
# no history. The daemon also exports fish_private_mode; this keeps it on for
# a fish that starts without it in its environment.
if set -q CMUX_TUI_INCOGNITO; and test -n "$CMUX_TUI_INCOGNITO"
    set -g fish_private_mode 1
end
