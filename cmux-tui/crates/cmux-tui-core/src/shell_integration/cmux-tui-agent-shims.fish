# cmux-tui: keep the agent shim directory ($CMUX_TUI_AGENT_SHIMS) first on
# PATH. config.fish commonly prepends a directory that holds the real `codex`
# or `claude`, which would start the agent without the terminal's hooks. Codex
# runs its hooks in a shared daemon that cannot see this terminal's
# environment, so only the shim can route them here. fish_preexec runs after
# config.fish and right before each command line is resolved.
function __cmux_tui_agent_shims_first --on-event fish_preexec
    set -l dir "$CMUX_TUI_AGENT_SHIMS"
    if test -n "$dir" -a -d "$dir"; and test "$PATH[1]" != "$dir"
        set -l rest
        for entry in $PATH
            test "$entry" = "$dir"; or set -a rest $entry
        end
        set -gx PATH $dir $rest
    end
end
