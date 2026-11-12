# Sourced by the shell tests that build scratch git repositories.
#
# Keeps git from leaving a background writer in them: since git 2.47, commit,
# fetch and clone start `git maintenance run --auto --detach`, and git 2.55's
# default maintenance packs a fixture's loose objects and deletes them while
# the test's next `git clone` of that repository is still copying them
# ("fatal: failed to copy file to .../objects/96/...: No such file or
# directory", exit 128 in 0 s on the CI runners). Same design as
# tests/git_fixture_env.py (its docstring says why each of the three is needed):
#
# 1. git_fixture_init / git_fixture_clone write maintenance.auto=false,
#    gc.auto=0 and receive.autogc=false into the new repository's own config.
#    Every bare remote goes through them: git clears GIT_CONFIG_COUNT before
#    receive-pack, which then runs its own maintenance in the bare repository.
# 2. The same three as exported GIT_CONFIG_KEY/VALUE pairs, for the git the
#    scripts under test run.
# 3. GIT_CONFIG_GLOBAL (when unset; an empty value is kept) names a file in a
#    fresh private mktemp -d folder that holds exactly what
#    `python3 -I tests/git_fixture_env.py --global-config-text` prints: the
#    person's global config files in the order git itself reads them, then the
#    three. One rule for Python and shell, asked of git, not re-implemented here.
#
# The folder is removed at exit by this file's EXIT trap, which also runs any
# EXIT trap set before sourcing. A test that wants its own exit cleanup calls
# `git_fixture_trap_exit 'CMD'` (check-test-determinism.py rule
# git-fixture-exit-trap fails a direct `trap 'CMD' EXIT`). A direct one still
# keeps the cleanup: this file's `trap` wrapper (cmux#41021) hands an EXIT
# action to git_fixture_trap_exit, so both build the same chain.

_git_fixture_opt_out=(maintenance.auto=false gc.auto=0 receive.autogc=false)

# Variables that point git at another repository, index, object store or config file (GIT_DIR, GIT_INDEX_FILE,
# GIT_CONFIG and so on): a test run from inside a git hook inherits them, and a fixture's `git -C "$tmp" commit`
# then writes the hook's repository. Same rule as tests/git_fixture_env.py REPO_REDIRECTS: git's own list
# (`git rev-parse --local-env-vars`) without the -c pairs (GIT_CONFIG_PARAMETERS, GIT_CONFIG_COUNT), unset here
# for everything this shell runs.
_git_fixture_redirects=()
if _git_fixture_names=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git rev-parse --local-env-vars 2>/dev/null) \
  && [[ -n "$_git_fixture_names" ]]; then
  read -r -d '' -a _git_fixture_redirects <<<"$_git_fixture_names" || true
else
  _git_fixture_redirects=(GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_OBJECT_DIRECTORY GIT_DIR GIT_WORK_TREE
    GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_INDEX_FILE GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE GIT_PREFIX
    GIT_SHALLOW_FILE GIT_COMMON_DIR)
fi
for _git_fixture_name in "${_git_fixture_redirects[@]}"; do
  case "$_git_fixture_name" in
    GIT_CONFIG_PARAMETERS | GIT_CONFIG_COUNT) ;;
    *) unset "$_git_fixture_name" ;;
  esac
done
unset _git_fixture_names _git_fixture_name _git_fixture_redirects

_git_fixture_count=${GIT_CONFIG_COUNT:-0}
for _git_fixture_pair in "${_git_fixture_opt_out[@]}"; do
  export "GIT_CONFIG_KEY_${_git_fixture_count}=${_git_fixture_pair%%=*}" \
    "GIT_CONFIG_VALUE_${_git_fixture_count}=${_git_fixture_pair#*=}"
  _git_fixture_count=$((_git_fixture_count + 1))
done
export GIT_CONFIG_COUNT=$_git_fixture_count
unset _git_fixture_count _git_fixture_pair

# git_fixture_trap_exit CMD: run CMD at exit, as `trap CMD EXIT` would (it replaces the previous CMD), and still
# remove this file's folder first. The script's exit status is kept for CMD ($?) and for the shell.
# The caller's action lives in its own variable, never in the trap text, and the dispatcher evals that variable.
# `trap -p` (the wrapper below) prints the caller's action, not the dispatcher, so `saved=$(trap -p EXIT); trap -
# EXIT; eval "$saved"` brings the cleared action back (review of hq#9715 F2: printing the dispatcher lost it). The
# dispatcher text itself, saved through `builtin trap -p`, is never kept as the action: the trap would eval itself
# until bash segfaulted (review of hq#9676 F1); that restore keeps the current action.
# An action and whether one is set are kept apart: `trap '' EXIT` sets an empty (ignored) action, which `trap -p EXIT`
# prints as `trap -- '' EXIT`, and a saved ignored trap must come back as one (review of hq#9715 F1 follow-up: one
# empty string stood for both, so the ignored trap printed nothing and a save/restore lost it).
# The ignored mark is bash's too: a special trap ignored and then reset keeps it, and a later `trap '' EXIT` does
# nothing (`trap '' EXIT; trap - EXIT; trap '' EXIT; trap -p EXIT` prints nothing). Only a real action clears it, so
# a non-empty CMD clears it here and an empty one does nothing while it is set (review of cmux#41772 F1: an action
# set here left the mark, and the next `trap '' EXIT` kept the action, which still ran at exit).
git_fixture_trap_exit() {
  [[ "$1" == "$_git_fixture_exit_trap" ]] && return 0
  if [[ -n "$1" ]]; then
    _git_fixture_exit_ignored=
  elif [[ -n "${_git_fixture_exit_ignored-}" ]]; then
    return 0
  else
    _git_fixture_exit_ignored=1
  fi
  _git_fixture_caller_exit=$1
  _git_fixture_caller_exit_set=1
}
_git_fixture_clear_exit() {
  _git_fixture_caller_exit=
  _git_fixture_caller_exit_set=
}

# The pid of the shell that calls `$(_git_fixture_pid)`, what bash 4+ calls $BASHPID. macOS's /bin/bash is 3.2, which
# has no BASHPID, and a `set -u` caller died sourcing this file (review of hq#9715 F1). The command substitution's
# process execs sh, so sh's parent is the calling shell, a subshell included.
_git_fixture_pid() { exec sh -c 'echo "$PPID"'; }

# Removes the folder; the caller's cleanup then runs from the trap itself (not inside this function), so it sees the
# script's own positional parameters, as a direct `trap CMD EXIT` would.
# Every folder this file made, as PID:PATH (_git_fixture_pid of the shell that made it): a second source after
# GIT_CONFIG_GLOBAL is unset adds one, and each is removed (cmux#41021 review F2). Only the shell that made a folder
# removes it: an EXIT trap a subshell sets must not delete it under us (cmux#41021). Never fails: a failed rm only
# warns.
_git_fixture_remove_dir() {
  local entry pid
  pid=$(_git_fixture_pid)
  for entry in ${_git_fixture_cleanup_dirs[@]+"${_git_fixture_cleanup_dirs[@]}"}; do
    [[ "${entry%%:*}" == "$pid" ]] || continue
    rm -rf -- "${entry#*:}" || echo "git-fixture.sh: could not remove ${entry#*:}" >&2
  done
  return 0
}
# _git_fixture_quote S prints S single-quoted, as `trap -p` quotes an action.
_git_fixture_quote() {
  local q="'\\''"
  printf "'%s'" "${1//\'/$q}"
}

# The exit trap. Its first step, _git_fixture_exit_prep, gets the script's status and the caller's DEBUG trap as
# arguments (expanded where the trap runs: inside a function bash hides DEBUG), turns errexit off (a test that failed
# under `set -e` would otherwise end the trap at its first failing step, before the caller's cleanup ran: Codex F1 on
# cmux#41195), removes the folders, and sets the DEBUG trap to ignored, so the caller's DEBUG trap does not run for
# the dispatcher's own steps (review of cmux#41772 F2: it ran seven times before the caller's action and once after).
# Then one eval runs _git_fixture_resume, which puts the caller's DEBUG trap back as it returns and returns the saved
# status, so the caller's action sees $? as the script's status (a function's return, not a subshell's exit:
# cmux#41021 review F1), then the caller's action, then `exit` with that status. A nonzero status is returned as
# `_git_fixture_resume N && :`, so it does not trip the caller's ERR trap (it did: three cmux tests set one, and a
# failed test printed a second "exited" line from the dispatcher). An `exit` in the caller's action still wins.
# When the caller's DEBUG trap is still set, the final `exit` is left out (bash keeps the script's status through the
# EXIT trap), and the trap runs once for the dispatcher's first step, which nothing can skip: the bound
# test_a_debug_trap_still_set_at_exit_sees_one_dispatcher_step holds.
_git_fixture_exit_prep() {
  _git_fixture_status=$1
  set +e
  _git_fixture_remove_dir
  _git_fixture_exit_debug=
  if [[ -n "$2" ]]; then
    _git_fixture_exit_debug=${2#trap -- }
    eval "_git_fixture_exit_debug=${_git_fixture_exit_debug% DEBUG}"
  fi
  _git_fixture_exit_eval="_git_fixture_resume $1"
  (( $1 == 0 )) || _git_fixture_exit_eval+=" && :"
  _git_fixture_exit_eval+=$'\n'"${_git_fixture_caller_exit-}"
  if [[ -n "$_git_fixture_exit_debug" ]]; then
    builtin trap '' DEBUG
  else
    _git_fixture_exit_eval+=$'\n'"exit $1"
  fi
  return 0
}
_git_fixture_resume() {
  if [[ -n "${_git_fixture_exit_debug-}" ]]; then
    builtin trap "builtin trap - RETURN; builtin trap -- $(_git_fixture_quote "$_git_fixture_exit_debug") DEBUG" RETURN
  fi
  return "$1"
}
_git_fixture_exit_trap='_git_fixture_exit_prep "$?" "$(builtin trap -p DEBUG)"; eval "$_git_fixture_exit_eval"'

# Arms EXIT in this shell and records which shell that is.
_git_fixture_arm_exit() {
  _git_fixture_armed_pid=$(_git_fixture_pid)
  builtin trap -- "$_git_fixture_exit_trap" EXIT
}

# Once per shell (a second source keeps the first folder and caller cleanup): the caller's exit cleanup starts as
# what was trapped on EXIT before sourcing, then git_fixture_trap_exit replaces it. "This shell" is its pid, not
# the trap text: a subshell still shows its parent's trap text but runs no EXIT trap until it sets one, so a guard on
# the text never armed `(unset GIT_CONFIG_GLOBAL; source lib)` and left that subshell's folder (review of hq#9676
# F2). The parent's action is not the subshell's: inherited dispatcher text starts it empty.
_git_fixture_shell_pid=$(_git_fixture_pid)
if [[ "${_git_fixture_armed_pid-}" != "$_git_fixture_shell_pid" ]]; then
  _git_fixture_previous_exit=$(builtin trap -p EXIT)
  _git_fixture_exit_ignored=
  if [[ "$_git_fixture_previous_exit" == *_git_fixture_remove_dir* || "$_git_fixture_previous_exit" == *_git_fixture_exit_prep* ]]; then
    _git_fixture_clear_exit
  elif [[ -z "$_git_fixture_previous_exit" ]]; then
    _git_fixture_clear_exit
    # An EXIT trap ignored and then reset keeps bash's "ignored" mark, so a later `trap '' EXIT` does nothing (see
    # the wrapper). Ask this shell (a subshell starts without the mark): the dispatcher replaces the probe below.
    builtin trap '' EXIT
    [[ -n "$(builtin trap -p EXIT)" ]] || _git_fixture_exit_ignored=1
  else
    _git_fixture_caller_exit=${_git_fixture_previous_exit#trap -- }
    eval "_git_fixture_caller_exit=${_git_fixture_caller_exit% EXIT}"
    _git_fixture_caller_exit_set=1
    [[ -n "$_git_fixture_caller_exit" ]] || _git_fixture_exit_ignored=1
  fi
  _git_fixture_cleanup_dirs=()
  _git_fixture_arm_exit
  unset _git_fixture_previous_exit
fi

# The caller's EXIT action as `trap -p` prints one (nothing when none is set; `trap -- '' EXIT` when it is ignored),
# so eval of it restores the action.
_git_fixture_print_exit() {
  local q="'\\''" action
  [[ -n "${_git_fixture_caller_exit_set-}" ]] || return 0
  action=${_git_fixture_caller_exit//\'/$q}
  printf "trap -- '%s' EXIT\n" "$action"
}

# _git_fixture_signal NAME prints what the builtin makes of NAME: exit, other or invalid. It asks the builtin in a
# command substitution, never re-implements it: EXIT, exit, 0 and 00 are all EXIT, while SIGEXIT and sigexit are
# invalid (the wrapper used to take SIGEXIT for EXIT, which plain bash refuses).
_git_fixture_signal() {
  local seen
  case "$1" in
    EXIT | 0) echo exit; return 0 ;;
  esac
  seen=$(builtin trap - EXIT; builtin trap - "$1" 2>/dev/null || { echo invalid; exit 0; }
    builtin trap -- : "$1" 2>/dev/null; builtin trap -p EXIT)
  case "$seen" in
    invalid) echo invalid ;;
    '') echo other ;;
    *) echo exit ;;
  esac
}

# `trap -p [SIGNAL...]`: the builtin's listing, with the caller's EXIT action in place of the helper's dispatcher.
# EXIT is signal 0, so the builtin always lists it first.
_git_fixture_trap_p() {
  local listing signal status=0 dispatcher="trap -- '$_git_fixture_exit_trap' EXIT"
  if (( $# == 0 )); then
    listing=$(builtin trap -p)
    case "$listing" in
      "$dispatcher") listing= ;;
      "$dispatcher"$'\n'*) listing=${listing#"$dispatcher"$'\n'} ;;
    esac
    _git_fixture_print_exit
    [[ -z "$listing" ]] || printf '%s\n' "$listing"
    return 0
  fi
  for signal in "$@"; do
    if [[ "$(_git_fixture_signal "$signal")" == exit ]]; then
      _git_fixture_print_exit
    else
      builtin trap -p -- "$signal" || status=$?
    fi
  done
  return "$status"
}

# Most tests used to set their own `trap ... EXIT` after sourcing this file, which replaced the cleanup above and
# left one folder per run (cmux#41021). So `trap` keeps it: an EXIT action goes to git_fixture_trap_exit (it runs
# right after the folder is removed), a reset clears only that action, and the helper's trap is set again (a
# subshell starts without it). Everything else is the builtin's, and the wrapper reads its arguments as the builtin
# does, so each form prints and does what plain bash does (tests: the differential row runs each form both ways):
# options -l, -p or both, `--` ends them (`trap -p --` lists everything: review of cmux#41713 F2 follow-up); no
# argument lists; a first argument of digits naming a signal, or one signal alone (outside posix mode), resets every
# signal named; otherwise the first argument is the action, '' ignores and - resets. An invalid signal fails the call
# (status 1) and the valid ones still take the action.
# The wrapper is a shell function, and a caller's DEBUG, RETURN and ERR traps see functions (review of cmux#41772 F2):
# a DEBUG trap set in a function runs for the function's remaining steps, and a RETURN trap set in one runs as it
# returns. So a DEBUG, RETURN or ERR action (or '') is set by a RETURN trap of the wrapper's own, as its last step,
# which resets itself (bash then puts the caller's RETURN trap back) and sets the caller's. A failed builtin returns
# its status through `|| return`, so under set -E the caller's ERR trap runs once, as for the builtin. Not matched,
# by any function: `trap -p` of DEBUG, RETURN or ERR prints nothing and `trap - DEBUG` (RETURN, ERR) is undone on
# return, unless set -T (set -E for ERR) is on; with set -T a DEBUG trap also runs for the wrapper's steps.
# shellcheck disable=SC2064  # the caller's own trap text, passed through unchanged
trap() {
  local _git_fixture_list=0 _git_fixture_print=0 _git_fixture_op=set _git_fixture_action= _git_fixture_signal_arg
  local _git_fixture_exit=0 _git_fixture_status=0 _git_fixture_set_on_return=
  local -a _git_fixture_other=() _git_fixture_on_return=()
  while (( $# > 0 )); do
    case "$1" in
      --) shift; break ;;
      -?*)
        case "${1#-}" in
          *[!lp]*) builtin trap "$1" || return; return 0 ;;
        esac
        case "$1" in *l*) _git_fixture_list=1 ;; esac
        case "$1" in *p*) _git_fixture_print=1 ;; esac
        shift ;;
      *) break ;;
    esac
  done
  if (( _git_fixture_list )); then
    builtin trap -l
    return
  fi
  if (( _git_fixture_print || $# == 0 )); then
    _git_fixture_trap_p "$@" || return
    return 0
  fi
  case "$1" in
    '' | *[!0-9]*) ;;
    *) [[ "$(_git_fixture_signal "$1")" == invalid ]] || _git_fixture_op=revert ;;
  esac
  if [[ "$_git_fixture_op" == set && $# == 1 && -n "$1" && "$1" != - ]] && ! shopt -qo posix \
    && [[ "$(_git_fixture_signal "$1")" != invalid ]]; then
    _git_fixture_op=revert
  fi
  if [[ "$_git_fixture_op" == set ]]; then
    _git_fixture_action=$1
    shift
    if (( $# == 0 )); then
      builtin trap -- "$_git_fixture_action" || return
      return 0
    fi
    if [[ -z "$_git_fixture_action" ]]; then
      _git_fixture_op=ignore
    elif [[ "$_git_fixture_action" == - ]]; then
      _git_fixture_op=revert
    fi
  fi
  for _git_fixture_signal_arg in "$@"; do
    if [[ "$(_git_fixture_signal "$_git_fixture_signal_arg")" == exit ]]; then
      _git_fixture_exit=1
      continue
    fi
    case "$_git_fixture_op:$_git_fixture_signal_arg" in
      set:[Dd][Ee][Bb][Uu][Gg] | set:[Rr][Ee][Tt][Uu][Rr][Nn] | set:[Ee][Rr][Rr] | ignore:[Dd][Ee][Bb][Uu][Gg] \
        | ignore:[Rr][Ee][Tt][Uu][Rr][Nn] | ignore:[Ee][Rr][Rr])
        _git_fixture_on_return+=("$_git_fixture_signal_arg") ;;
      *) _git_fixture_other+=("$_git_fixture_signal_arg") ;;
    esac
  done
  if (( ${#_git_fixture_other[@]} > 0 )); then
    case "$_git_fixture_op" in
      set) builtin trap -- "$_git_fixture_action" "${_git_fixture_other[@]}" || _git_fixture_status=$? ;;
      ignore) builtin trap -- '' "${_git_fixture_other[@]}" || _git_fixture_status=$? ;;
      *) builtin trap -- - "${_git_fixture_other[@]}" || _git_fixture_status=$? ;;
    esac
  fi
  if (( _git_fixture_exit )); then
    # git_fixture_trap_exit keeps bash's "ignored" mark (see there).
    case "$_git_fixture_op" in
      set) git_fixture_trap_exit "$_git_fixture_action" ;;
      ignore) git_fixture_trap_exit '' ;;
      *) _git_fixture_clear_exit ;;
    esac
    _git_fixture_arm_exit
  fi
  if (( ${#_git_fixture_on_return[@]} > 0 )); then
    _git_fixture_set_on_return="builtin trap -- $(_git_fixture_quote "$_git_fixture_action") ${_git_fixture_on_return[*]}"
    builtin trap "builtin trap - RETURN; $_git_fixture_set_on_return" RETURN
  fi
  return "$_git_fixture_status"
}

# Only when unset: an empty GIT_CONFIG_GLOBAL means "no global config" and is kept (Codex F2 on cmux#40871).
if [[ -z "${GIT_CONFIG_GLOBAL+x}" ]]; then
  # Written only inside a fresh private folder per process (mktemp -d: ours, mode 0700, an unpredictable name),
  # never a fixed name in the shared temp folder: another user could plant or swap that file and add
  # core.hooksPath (Codex F1 on cmux#40871).
  _git_fixture_py="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." 2>/dev/null && pwd)/tests/git_fixture_env.py"
  if ! _git_fixture_text=$(python3 -I "$_git_fixture_py" --global-config-text); then
    echo "git-fixture.sh: $_git_fixture_py --global-config-text failed; the fixture GIT_CONFIG_GLOBAL holds the opt-out alone" >&2
    _git_fixture_text=$'[maintenance]\n\tauto = false\n[gc]\n\tauto = 0\n[receive]\n\tautogc = false'
  fi
  if _git_fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/cmux-git-fixture.XXXXXXXX"); then
    _git_fixture_cleanup_dirs+=("$_git_fixture_shell_pid:$_git_fixture_dir")
    printf '%s\n' "$_git_fixture_text" >"$_git_fixture_dir/global.gitconfig"
    export GIT_CONFIG_GLOBAL="$_git_fixture_dir/global.gitconfig"
  else
    echo "git-fixture.sh: mktemp -d failed; no fixture GIT_CONFIG_GLOBAL (repo config and env still opt out)" >&2
  fi
  unset _git_fixture_text _git_fixture_py _git_fixture_dir
fi
unset _git_fixture_shell_pid

# Quiet git that still says why when it fails: a bare exit 128 told nobody which call broke.
git_q() {
  local err status=0
  err=$(git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" 2>&1 >/dev/null) || status=$?
  (( status == 0 )) || printf 'git_q %s: exit %d\n%s\n' "$*" "$status" "$err" >&2
  return "$status"
}

# git_fixture_init [git init options...] DIR: `git init -q`, then the opt-out in DIR's own config.
git_fixture_init() {
  local dir=${!#} pair
  git_q init -q "$@" || return
  for pair in "${_git_fixture_opt_out[@]}"; do
    _git_fixture_write_config "$dir" "${pair%%=*}" "${pair#*=}" || return
  done
}

# _git_fixture_write_config DIR KEY VALUE: `git config --local` in DIR with no redirect, no inherited -c pair and no
# global or system config (tests/git_fixture_env.py write_env), so nothing the caller set takes the write.
_git_fixture_write_config() {
  local name err status=0
  local -a strip=(-u GIT_CONFIG -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT -u GIT_DIR
    -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE)
  for name in $(compgen -e); do
    [[ "$name" == GIT_CONFIG_KEY_* || "$name" == GIT_CONFIG_VALUE_* ]] && strip+=(-u "$name")
  done
  err=$(env "${strip[@]}" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$1" config --local "$2" "$3" 2>&1 >/dev/null) || status=$?
  (( status == 0 )) || printf 'git config --local %s in %s: exit %d\n%s\n' "$2" "$1" "$status" "$err" >&2
  return "$status"
}

# git_fixture_clone [git clone options...] SOURCE DEST: the clone's config gets the opt-out before it runs.
git_fixture_clone() {
  local args=() pair
  for pair in "${_git_fixture_opt_out[@]}"; do args+=(-c "$pair"); done
  git_q clone -q "${args[@]}" "$@"
}
