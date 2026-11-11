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
# 3. GIT_CONFIG_GLOBAL (when unset) names a file that includes ~/.gitconfig
#    and ~/.config/git/config, then sets the three.

_git_fixture_opt_out=(maintenance.auto=false gc.auto=0 receive.autogc=false)

_git_fixture_count=${GIT_CONFIG_COUNT:-0}
for _git_fixture_pair in "${_git_fixture_opt_out[@]}"; do
  export "GIT_CONFIG_KEY_${_git_fixture_count}=${_git_fixture_pair%%=*}" \
    "GIT_CONFIG_VALUE_${_git_fixture_count}=${_git_fixture_pair#*=}"
  _git_fixture_count=$((_git_fixture_count + 1))
done
export GIT_CONFIG_COUNT=$_git_fixture_count
unset _git_fixture_count _git_fixture_pair

if [[ -z "${GIT_CONFIG_GLOBAL:-}" ]]; then
  # One file per user, rewritten only when its text differs; the text never changes, so tests share it.
  _git_fixture_global="${TMPDIR:-/tmp}/cmux-git-fixture-$(id -u)-v1.gitconfig"
  _git_fixture_text=$'[include]\n\tpath = ~/.gitconfig\n\tpath = ~/.config/git/config\n[maintenance]\n\tauto = false\n[gc]\n\tauto = 0\n[receive]\n\tautogc = false'
  if [[ "$(cat "$_git_fixture_global" 2>/dev/null)" != "$_git_fixture_text" ]]; then
    printf '%s\n' "$_git_fixture_text" >"$_git_fixture_global.$$" && mv -f "$_git_fixture_global.$$" "$_git_fixture_global"
  fi
  export GIT_CONFIG_GLOBAL=$_git_fixture_global
  unset _git_fixture_global _git_fixture_text
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
