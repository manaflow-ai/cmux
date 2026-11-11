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
# `git_fixture_trap_exit 'CMD'` instead of `trap 'CMD' EXIT`: a direct trap
# replaces this one and leaks the folder (check-test-determinism.py rule
# git-fixture-exit-trap fails such a test).

_git_fixture_opt_out=(maintenance.auto=false gc.auto=0 receive.autogc=false)

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
git_fixture_trap_exit() {
  _git_fixture_caller_exit=$1
}

# Removes the folder; the caller's cleanup then runs from the trap itself (not inside this function), so it sees the
# script's own positional parameters, as a direct `trap CMD EXIT` would.
_git_fixture_remove_dir() {
  [[ -z "$_git_fixture_cleanup_dir" ]] || rm -rf -- "$_git_fixture_cleanup_dir"
}
_git_fixture_exit_trap='_git_fixture_status=$?; _git_fixture_remove_dir; (exit "$_git_fixture_status"); eval "${_git_fixture_caller_exit:-:}"'

# Once per shell (a second source keeps the first folder and caller cleanup): the caller's exit cleanup starts as
# what was trapped on EXIT before sourcing, then git_fixture_trap_exit replaces it.
_git_fixture_previous_exit=$(trap -p EXIT)
if [[ "$_git_fixture_previous_exit" != *_git_fixture_remove_dir* ]]; then
  _git_fixture_caller_exit=${_git_fixture_previous_exit#trap -- }
  eval "_git_fixture_caller_exit=${_git_fixture_caller_exit% EXIT}"
  _git_fixture_cleanup_dir=
  # shellcheck disable=SC2064  # expand the variable now: it holds the trap text, whose $? expands at exit
  trap "$_git_fixture_exit_trap" EXIT
fi
unset _git_fixture_previous_exit

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
  if _git_fixture_cleanup_dir=$(mktemp -d "${TMPDIR:-/tmp}/cmux-git-fixture.XXXXXXXX"); then
    printf '%s\n' "$_git_fixture_text" >"$_git_fixture_cleanup_dir/global.gitconfig"
    export GIT_CONFIG_GLOBAL="$_git_fixture_cleanup_dir/global.gitconfig"
  else
    _git_fixture_cleanup_dir=
    echo "git-fixture.sh: mktemp -d failed; no fixture GIT_CONFIG_GLOBAL (repo config and env still opt out)" >&2
  fi
  unset _git_fixture_text _git_fixture_py
fi

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
    git_q -C "$dir" config "${pair%%=*}" "${pair#*=}" || return
  done
}

# git_fixture_clone [git clone options...] SOURCE DEST: the clone's config gets the opt-out before it runs.
git_fixture_clone() {
  local args=() pair
  for pair in "${_git_fixture_opt_out[@]}"; do args+=(-c "$pair"); done
  git_q clone -q "${args[@]}" "$@"
}
