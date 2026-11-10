# Sourced by the shell tests that build scratch git repositories.
#
# Keeps git from leaving a background writer in them: since git 2.47, commit,
# fetch and clone start `git maintenance run --auto --detach`, and git 2.55's
# default maintenance packs a fixture's loose objects and deletes them while
# the test's next `git clone` of that repository is still copying them
# ("fatal: failed to copy file to .../objects/96/...: No such file or
# directory", exit 128 in 0 s on the CI runners). The Python fixtures do the
# same through tests/git_fixture_env.py. Exported, so it also covers the git
# the scripts under test run.
_git_fixture_count=${GIT_CONFIG_COUNT:-0}
export "GIT_CONFIG_KEY_${_git_fixture_count}=maintenance.auto" "GIT_CONFIG_VALUE_${_git_fixture_count}=false"
export GIT_CONFIG_COUNT=$((_git_fixture_count + 1))
unset _git_fixture_count

# Quiet git that still says why when it fails: a bare exit 128 told nobody which call broke.
git_q() {
  local err status=0
  err=$(git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" 2>&1 >/dev/null) || status=$?
  (( status == 0 )) || printf 'git_q %s: exit %d\n%s\n' "$*" "$status" "$err" >&2
  return "$status"
}
