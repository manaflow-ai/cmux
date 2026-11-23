# The Python the cmux hooks run, picked on this host each time (sourced, never run). scripts/install-git-hooks.sh
# sources the checkout's copy and installs it beside the hooks; scripts/git-hooks/pre-push sources that installed copy.
#
# One host's interpreter path is not another's. The install records the python3 it found (python3-path), and on
# 2026-11-16 a fleet Mac's recorded /Users/cmux/.local/python-3.13.15/bin/python3.13 had no PyYAML: the gate refused
# with a pip command for that one interpreter, whatever else the Mac had. So each candidate is tried in order, and the
# first that runs Python 3.9+ under -I and imports yaml is used. With none importing yaml, the first that runs is used,
# and a check that needs PyYAML refuses, naming every candidate tried (CMUX_HOOK_PYTHON_TRIED) and the command that
# fixes the first. With none that runs, hook_python_pick returns 1 and the hook refuses. No check is skipped.
#
# The candidates: the recorded one first, then HOOK_PYTHON_CANDIDATES. One is passed over, without running it, when
# it or the file it resolves to lies inside a ROOT (the checkout, its git dir): that python would run code a push
# controls. On macOS /usr/bin/python3 without the Command Line Tools is a stub that opens an install dialog: passed over.
# bash 3.2 (macOS /bin/bash): no associative arrays, no empty "${a[@]}" under set -u.

HOOK_PYTHON_CANDIDATES=("${HOME:-/nonexistent}/.local/bin/python3" /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3)
# Exit 0: runs, imports yaml. 4: runs, no PyYAML. 3: older than 3.9. Free of single quotes (a single-quoted string).
HOOK_PYTHON_PROBE='import sys
if sys.version_info < (3, 9):
    sys.exit(3)
try:
    import yaml
except Exception:
    sys.exit(4)'

# hook_python_pick NEED_YAML RECORDED [ROOT...]: sets HOOK_PYTHON (the resolved path of the pick; empty when none runs)
# and HOOK_PYTHON_TRIED ("path (why); ..." for each candidate passed over, in order). Returns 1 when none runs.
hook_python_pick() {
    local need_yaml="$1" recorded="$2" candidate real root why status nl seen fallback=""
    printf -v nl '\n'
    seen="$nl"
    shift 2
    HOOK_PYTHON=""
    HOOK_PYTHON_TRIED=""
    for candidate in "$recorded" "${HOOK_PYTHON_CANDIDATES[@]}"; do
        [[ -n "$candidate" ]] || continue
        real="$candidate"
        why=""
        if [[ "$candidate" != /* ]]; then
            why="not an absolute path"
        elif [[ ! -x "$candidate" || -d "$candidate" ]]; then
            why="missing"
        else
            real="$(/bin/realpath "$candidate" 2>/dev/null || true)"
            if [[ -z "$real" ]]; then
                real="$candidate"
                why="missing"
            fi
        fi
        if [[ -z "$why" ]]; then
            case "$seen" in *"$nl$real$nl"*) continue ;; esac
            seen="$seen$real$nl"
            for root in "$@"; do
                [[ -n "$root" ]] || continue
                case "$candidate/" in "$root"/*) why="inside the checkout" ;; esac
                case "$real/" in "$root"/*) why="inside the checkout" ;; esac
            done
        fi
        if [[ -z "$why" && "$real" == /usr/bin/python3 && "${OSTYPE:-}" == darwin* ]] \
                && ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
            why="the Command Line Tools stub, with no tools installed"
        fi
        if [[ -z "$why" ]]; then
            status=0
            "$real" -I -c "$HOOK_PYTHON_PROBE" </dev/null >/dev/null 2>&1 || status=$?
            if (( status == 0 )) || { (( status == 4 )) && [[ "$need_yaml" != 1 ]]; }; then
                HOOK_PYTHON="$real"
                return 0
            elif (( status == 4 )); then
                why="no PyYAML"
                [[ -n "$fallback" ]] || fallback="$real"
            elif (( status == 3 )); then
                why="older than 3.9"
            else
                why="does not run: exit $status"
            fi
        fi
        if [[ "$real" != "$candidate" ]]; then
            candidate="$candidate -> $real"
        fi
        HOOK_PYTHON_TRIED="${HOOK_PYTHON_TRIED:+$HOOK_PYTHON_TRIED; }$candidate ($why)"
    done
    HOOK_PYTHON="$fallback"
    [[ -n "$HOOK_PYTHON" ]]
}
