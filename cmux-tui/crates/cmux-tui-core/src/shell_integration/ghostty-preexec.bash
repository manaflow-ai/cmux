
# cmux: interim, delete with the ghostty-next bump that takes the root fix
# (ghostty-next 72578da; PL-ghostty bumps the gitlink). Appended to Ghostty's ghostty.bash in every copy cmux
# ships: the daemon's (shell_integration.rs SCRIPTS) and the app bundle's
# (scripts/cmux-next/bundle-ghostty-resources.sh), so every bash cmux-next
# integrates gets it, with or without the app's cmux-cli-path layer.
#
# Ghostty's preexec hook reads the command line with `cmd=$(builtin history 1)`,
# a fork before every command. bash 5.3 captures a builtin's output in the shell
# itself with `${ ...; }`, and Ghostty already runs this hook from PS0 that way
# there. Older bash has no fork-free capture and keeps Ghostty's hook. eval keeps
# older bash from parsing the 5.3 syntax. No temporary LC_ALL=C: inside `${ }`
# it would switch the shell's own locale to C and back on every command, and the
# digit strip below runs in the caller's locale anyway.
# scripts/cmux-next/shell-integration-bench.py counts the forks.
if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )) \
  && builtin declare -F __ghostty_preexec_hook >/dev/null; then
  builtin eval '__ghostty_preexec_hook() {
    builtin local cmd
    cmd=${ HISTTIMEFORMAT= builtin history 1; }
    cmd="${cmd#*[[:digit:]][* ] }"
    [[ -n "$cmd" ]] && __ghostty_preexec "$cmd"
  }'
fi
