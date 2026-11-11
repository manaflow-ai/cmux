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
#    fresh private mktemp -d folder, removed at exit (also when the test sets
#    its own EXIT trap later: see `trap` below), that includes the person's
#    global config in plain git's order (${XDG_CONFIG_HOME:-~/.config}/git/config,
#    then ~/.gitconfig), then sets the three.

_git_fixture_opt_out=(maintenance.auto=false gc.auto=0 receive.autogc=false)

_git_fixture_count=${GIT_CONFIG_COUNT:-0}
for _git_fixture_pair in "${_git_fixture_opt_out[@]}"; do
  export "GIT_CONFIG_KEY_${_git_fixture_count}=${_git_fixture_pair%%=*}" \
    "GIT_CONFIG_VALUE_${_git_fixture_count}=${_git_fixture_pair#*=}"
  _git_fixture_count=$((_git_fixture_count + 1))
done
export GIT_CONFIG_COUNT=$_git_fixture_count
unset _git_fixture_count _git_fixture_pair

# Only when unset: an empty GIT_CONFIG_GLOBAL means "no global config" and is kept (Codex F2 on cmux#40871).
if [[ -z "${GIT_CONFIG_GLOBAL+x}" ]]; then
  # The person's global config in plain git's order (tests/git_fixture_env.py global_config_text):
  # $XDG_CONFIG_HOME/git/config (default ~/.config/git/config) first, ~/.gitconfig after it so it wins,
  # each by absolute [include] path (their own includes keep working; git skips a missing one), then the
  # opt-out last. Written only inside a fresh private folder per process (mktemp -d: ours, mode 0700, an
  # unpredictable name), never a fixed name in the shared temp folder: another user could plant or swap
  # that file and add core.hooksPath (Codex F1 on cmux#40871). Removed at exit, before any EXIT trap set before or after.
  _git_fixture_xdg=${XDG_CONFIG_HOME:-${HOME:+$HOME/.config}}
  _git_fixture_text=
  for _git_fixture_path in ${_git_fixture_xdg:+"$_git_fixture_xdg/git/config"} ${HOME:+"$HOME/.gitconfig"}; do
    # A config-file string: backslash and double quote escaped, the whole path quoted (spaces, '#', ';').
    _git_fixture_path=$(printf '%s' "$_git_fixture_path" | sed 's/[\\"]/\\&/g')
    _git_fixture_text+=$'[include]\n\tpath = "'"$_git_fixture_path"$'"\n'
  done
  _git_fixture_text+=$'[maintenance]\n\tauto = false\n[gc]\n\tauto = 0\n[receive]\n\tautogc = false'
  if _git_fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/cmux-git-fixture.XXXXXXXX"); then
    printf '%s\n' "$_git_fixture_text" >"$_git_fixture_dir/global.gitconfig"
    export GIT_CONFIG_GLOBAL="$_git_fixture_dir/global.gitconfig"
    _git_fixture_owned_dir=$_git_fixture_dir
    _git_fixture_owner_depth=$BASH_SUBSHELL
    # Only the shell that made the folder removes it: an EXIT trap a subshell sets must not delete it under us.
    _git_fixture_cleanup() {
      [[ "$BASH_SUBSHELL" == "$_git_fixture_owner_depth" ]] || return 0
      rm -rf -- "$_git_fixture_owned_dir"
    }
    _git_fixture_trap=$(trap -p EXIT)  # before the wrapper below exists
    _git_fixture_trap=${_git_fixture_trap#trap -- }
    eval "_git_fixture_trap=${_git_fixture_trap% EXIT}"
    _git_fixture_nl=$'\n'
    builtin trap -- "_git_fixture_cleanup${_git_fixture_trap:+$_git_fixture_nl$_git_fixture_trap}" EXIT
    unset _git_fixture_trap _git_fixture_nl
    # Most tests set their own `trap ... EXIT` after sourcing this file, which replaced the cleanup above and
    # left one folder per run (33 in the suite). So `trap` keeps it: an EXIT action set later runs right after
    # the cleanup (git reads no global config once it is gone; the repos' own config still opts out), and
    # `trap - EXIT` or `trap '' EXIT` leaves the cleanup alone. Every other use goes straight to the builtin.
    trap() {
      local _git_fixture_action _git_fixture_signal _git_fixture_exit=0
      local -a _git_fixture_other=()
      case "${1-}" in
        -p | -l | -lp | -pl) builtin trap "$@"; return ;;
        --) shift ;;
      esac
      if (( $# == 1 )); then
        case "$1" in
          EXIT | 0 | SIGEXIT) builtin trap -- _git_fixture_cleanup EXIT; return ;;
          *) builtin trap -- "$@"; return ;;
        esac
      fi
      (( $# >= 2 )) || { builtin trap "$@"; return; }
      _git_fixture_action=$1
      shift
      for _git_fixture_signal in "$@"; do
        case "$_git_fixture_signal" in
          EXIT | 0 | SIGEXIT) _git_fixture_exit=1 ;;
          *) _git_fixture_other+=("$_git_fixture_signal") ;;
        esac
      done
      if (( ${#_git_fixture_other[@]} > 0 )); then
        builtin trap -- "$_git_fixture_action" "${_git_fixture_other[@]}" || return
      fi
      (( _git_fixture_exit )) || return 0
      case "$_git_fixture_action" in
        - | '') builtin trap -- _git_fixture_cleanup EXIT ;;
        *) builtin trap -- "_git_fixture_cleanup"$'\n'"$_git_fixture_action" EXIT ;;
      esac
    }
  else
    echo "git-fixture.sh: mktemp -d failed; no fixture GIT_CONFIG_GLOBAL (repo config and env still opt out)" >&2
  fi
  unset _git_fixture_dir _git_fixture_text _git_fixture_xdg _git_fixture_path
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
