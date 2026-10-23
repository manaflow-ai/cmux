# cmux: an interim copy of Ghostty's __ghostty_preexec_hook with the bash 5.3
# fix from ghostty-next 72578da (src/shell-integration/bash/ghostty.bash).
# Ghostty's script is based on Kitty's bash integration, which is distributed
# under GPLv3, so this file is also distributed under GPLv3:
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# DELETE with the ghostty-next gitlink bump to 72578da or later (the bump
# also needs a GhosttyNextKit release of that revision; tracked in
# plans/cmux-next/perf-lead.md row 20). Delete together: this file, its
# include in shell_integration.rs SCRIPTS, the append in
# scripts/cmux-next/bundle-ghostty-resources.sh, BASH_FIX in
# scripts/cmux-next/shell-integration-bench.py, and the ghostty.bash exception
# in scripts/cmux-next/tests/bundle-ghostty-resources.test.sh.
#
# Appended to Ghostty's ghostty.bash in every copy cmux ships: the daemon's
# (shell_integration.rs SCRIPTS) and the app bundle's
# (scripts/cmux-next/bundle-ghostty-resources.sh), so every bash cmux-next
# integrates gets it, with or without the app's cmux-cli-path layer.
#
# Ghostty's preexec hook (at the pin) reads the command line with
# `cmd=$(builtin history 1)`, a fork before every command. bash 5.3 captures a
# builtin's output in the shell itself with `${ ...; }`, and Ghostty already
# runs this hook from PS0 that way there. Older bash has no fork-free capture
# and keeps Ghostty's hook. eval keeps older bash from parsing the 5.3 syntax.
# No temporary LC_ALL=C: inside `${ }` it would switch the shell's own locale
# to C and back on every command, and the digit strip below runs in the
# caller's locale anyway. The startup fork of Ghostty's
# `$(builtin declare -p PROMPT_COMMAND)` runs before this file and stays until
# the bump. shell_integration/fork_count_tests.rs counts the daemon's forks;
# scripts/cmux-next/shell-integration-bench.py counts every spawn path's.
if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )) \
  && builtin declare -F __ghostty_preexec_hook >/dev/null; then
  builtin eval '__ghostty_preexec_hook() {
    builtin local cmd
    cmd=${ HISTTIMEFORMAT= builtin history 1; }
    cmd="${cmd#*[[:digit:]][* ] }"
    [[ -n "$cmd" ]] && __ghostty_preexec "$cmd"
  }'
fi
