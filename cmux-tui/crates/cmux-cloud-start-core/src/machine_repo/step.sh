#!/bin/sh
# cmux machine bootstrap: the repo step (cmux cloud new-machine --repo). It stores no secret
# anywhere: it uses the GitHub access the machine already has, or none (always none off GitHub).
set -u
d=$(cd "$(dirname "$0")" && pwd)
url='@URL@'; ref='@REF@'; dir="$HOME/@DIRECTORY@"; github=@GITHUB@
host='@HOST@'; key="credential.https://$host"
cred=none; helper=""; status=failed; sha=""; why=""; fresh=""; tip=""; fill=none
result() {
  printf '{"status":"%s","url":"%s","ref":"%s","dir":"%s","credential":"%s","sha":"%s","fill":"%s"}\n' \
    "$status" "$url" "$ref" "$dir" "$cred" "$sha" "$fill" >"$d/repo-status.json.tmp" && mv -f "$d/repo-status.json.tmp" "$d/repo-status.json"
}
die() { status=failed; result; echo "cmux repo: $1" >&2; exit 1; }
# Nothing inherited or configured may ask another credential source or log a request (git's
# stderr goes to the bootstrap log). Trace2 reads its config before any -c, so it is off here.
export GIT_TERMINAL_PROMPT=0 GIT_TRACE_REDACT=1 GIT_TRACE=0 GIT_TRACE_CURL=0 GIT_TRACE_PACKET=0 GIT_TRACE_SETUP=0 \
  GIT_TRACE_PERFORMANCE=0 GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0
unset GIT_ASKPASS SSH_ASKPASS GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CURL_VERBOSE GIT_TRACE_CURL_NO_DATA
# The machine's own GitHub paths, in order: the lane broker's helper (exactly the value
# leo-workspace tools/lane-vm-bootstrap installs), the Cloud agent's, none.
lane="!$HOME/.local/bin/lane-gh-credential"
creds=""
if [ "$github" = 1 ] && [ -x "$HOME/.local/bin/lane-gh-credential" ] &&
  git config --global --includes --get-all credential.https://github.com.helper 2>/dev/null | grep -qxF -- "$lane"; then
  creds="lane-gh"
fi
if [ "$github" = 1 ] && [ -S /run/cmux-vm-agent/agent.sock ] && cm=$(command -v cmux); then creds="$creds cmux-github"; fi
# Off GitHub: the person's token for this host, sealed to the machine (`cmux gitlab credential`).
if [ "$github" = 0 ] && [ -f "$HOME/.config/cmux/git-hosts/$host" ] && cm=$(command -v cmux); then creds="cmux-gitlab"; fi
creds="$creds anonymous"
# From here git reads no user or system config (a username that is a secret, an askpass, a
# helper, a trace target): the chosen helper comes on the command line.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
use() {
  cred=$1
  case "$1" in
    lane-gh) helper=$lane ;;
    cmux-github) helper="!'$cm' github credential" ;;
    cmux-gitlab) helper="!'$cm' gitlab credential" ;;
    *) helper="" ;;
  esac
}
# An empty credential.helper on the command line drops every helper git read before it (a
# checkout's own config may hold one); the chosen one comes after it, so only it is asked.
# The usernames are emptied for the same reason.
g() {
  if [ -n "$helper" ]; then
    set -- -c "$key.helper=$helper" -c "$key.useHttpPath=true" "$@"
  fi
  git -c credential.helper= -c core.askPass= -c credential.username= -c "$key.username=" "$@"
}
# A clone or fetch with each path until one works; the checkout after it keeps that path.
# A clone that failed half way (its checkout) is removed before the next path tries.
net() {
  for c in $creds; do
    use "$c"; g "$@" && return 0
    [ -n "$fresh" ] && rm -rf "$dir"
  done
  cred=none
  [ "$github" = 1 ] || die "$url cannot be cloned without credentials (private, not found, or offline); give this machine access to $host first"
  status=needs_github; result
  echo "cmux repo: $url needs access this machine does not have (private, not found, or offline)" >&2
  exit @NEEDS_GITHUB_EXIT@
}
# Switch to $ref: a local or remote branch (tracked), else a tag or commit (detached).
switch() {
  [ -n "$ref" ] || return 0
  if g -C "$dir" show-ref --verify --quiet "refs/heads/$ref"; then
    g -C "$dir" checkout --quiet "$ref" --
  elif g -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
    g -C "$dir" checkout --quiet -b "$ref" --track "origin/$ref" --
  elif commit=$(g -C "$dir" rev-parse --verify --quiet "$ref^{commit}"); then
    g -C "$dir" checkout --quiet --detach "$commit" --
  else
    why="no branch, tag or commit $ref in $url"; return 1
  fi || { why="cannot check out $ref"; return 1; }
}
root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }
# A clone of the default branch is cloned head first: one commit's trees, the root files
# (AGENTS.md, CLAUDE.md, lockfiles) and the harness folders, in about a second where the whole
# clone takes tens (microsoft/vscode: 1.0 s against 28 s). The rest of the tree comes in the
# background (`fill`) under `cmux repo hold`, which keeps every agent tool waiting until the tree
# is whole while a Claude start goes ahead at the head. A machine whose cmux has no `repo hold`,
# or no systemd-run, clones the whole repository as before. So does a start with a bootstrap
# script (anything but machine_bootstrap.rs `NO_SCRIPT`): the runner runs it right after this
# step, and nothing holds it at the barrier.
head_dirs=".claude .codex .cursor .gemini .github .vscode .devcontainer"
# The start runs no bootstrap script of its own (machine_bootstrap.rs `NO_SCRIPT`).
no_script() { printf '#!/bin/sh\nexit 0\n' | cmp -s - "$d/script"; }
holder() {
  no_script &&
    { hx=$(command -v cmux-tui) || hx=$(command -v cmux); } && "$hx" repo hold --help >/dev/null 2>&1 &&
    command -v systemd-run >/dev/null 2>&1
}
# The checkout's barrier, by `cmux repo wait DIR 0` (`repo_hold.rs`): `ready` (or no barrier),
# `failed` (a fill that died: the tree may be whole but no tool may run), `busy` (a fill holds it),
# or `none` on a machine whose cmux has no `repo wait`.
wx=$(command -v cmux-tui || command -v cmux) || wx=""
barrier() {
  [ -n "$wx" ] || { echo none; return; }
  c=0; "$wx" repo wait "$dir" 0 >/dev/null 2>&1 || c=$?
  case $c in 0) echo ready ;; 1) echo failed ;; 124) echo busy ;; *) echo none ;; esac
}
# The history fetch (`unshallow`) holds this while it runs, so a later start leaves it alone.
history_lock="$dir/.git/cmux-history.lock"
history_busy() { [ -f "$history_lock" ] && ! flock -n "$history_lock" true; }
# The whole tree and the history, now. A checkout whose barrier failed is filled under it
# (`repo hold-run`, which opens it only when the fill succeeds), so its tools may run again.
fill_now() {
  if [ "$state" = failed ] && [ -n "$wx" ] && "$wx" repo hold --help >/dev/null 2>&1; then
    "$wx" repo hold-run "$dir" -- "$d/repo" fill-now "$cred" >&2
  else
    "$d/repo" fill-now "$cred"
  fi
}
# The fill, in its own scope: the bootstrap's unit ends with this runner, and the hold outlives it.
# The hold is taken before this returns, so no chat starts on the folder before it.
fill_later() {
  if root systemd-run --scope --quiet --collect --unit="cmux-repo-fill-$(date +%s)-$$" \
    runuser -u "$(id -un)" -- env HOME="$HOME" PATH="$PATH" "$hx" repo hold "$dir" -- "$d/repo" fill "$cred"; then
    fill=background
  else
    echo "cmux repo: cannot fill $dir in the background; filling it now" >&2
    fill_now || die "cannot check out all of $url"
    fill=done
  fi
}
# Run by `cmux repo hold` (`fill_later`): the whole tree, then, once the barrier is open, the history.
# The fill takes the history lock before the barrier opens and hands it (fd 9) to the history
# fetch, so no later start finds the checkout open with the fetch not yet holding it.
if [ "${1:-}" = fill ]; then
  use "${2:-anonymous}"
  # Appended to, never truncated: a symlink planted there is removed, not followed.
  { [ ! -L "$history_lock" ] || rm -f "$history_lock"; } && exec 9>>"$history_lock" || exit 1
  if command -v flock >/dev/null 2>&1; then flock 9 || exit 1; fi
  g -C "$dir" sparse-checkout disable || exit 1
  setsid "$d/repo" unshallow "${2:-anonymous}" </dev/null >>"$d/bootstrap.log" 2>&1 &
  exit 0
fi
# Run by `fill`, with the history lock it holds on fd 9.
if [ "${1:-}" = unshallow ]; then
  use "${2:-anonymous}"
  [ "$(g -C "$dir" rev-parse --is-shallow-repository)" = true ] || exit 0
  g -C "$dir" fetch --quiet --unshallow --filter=blob:none origin
  exit
fi
# `fill_now`'s fill, run by itself or under `repo hold-run`.
if [ "${1:-}" = fill-now ]; then
  use "${2:-anonymous}"
  g -C "$dir" sparse-checkout disable || exit 1
  [ "$(g -C "$dir" rev-parse --is-shallow-repository)" = true ] || exit 0
  g -C "$dir" fetch --quiet --unshallow --filter=blob:none origin
  exit
fi
# Fast-forward the checked-out branch to its upstream; a branch with local commits is kept.
forward() {
  up=$(g -C "$dir" rev-parse --verify --quiet '@{u}') || return 0
  if g -C "$dir" merge-base --is-ancestor HEAD "$up"; then
    g -C "$dir" merge --quiet --ff-only "$up" || { why="cannot fast-forward to $up"; return 1; }
  else
    status=kept
  fi
}
if [ -d "$dir/.git" ]; then
  [ "$(git -C "$dir" remote get-url origin 2>/dev/null)" = "$url" ] || die "$dir holds another repository"
  # A clone cut short (no commit checked out) is cloned again.
  if ! g -C "$dir" rev-parse --verify --quiet HEAD >/dev/null; then
    [ -z "$(ls -A "$dir" | grep -vx .git)" ] || die "$dir has no commit checked out and holds files"
    rm -rf "$dir"
  fi
fi
state=none
if [ -d "$dir/.git" ]; then
  state=$(barrier)
  # A fill or history fetch from an earlier start still runs in it: nothing here fetches, switches
  # or fills beside it (its git locks would fail this start). A start that needs nothing more than
  # the checkout as it is (no ref, no script of its own) leaves it to that one: its chat's tools
  # wait at the barrier. Any other waits for it first (a script runs on the tree right after this
  # step, and a ref skipped now would be skipped by every identical start after it). So does one
  # whose barrier failed: a history fetch can outlive its fill, and only a start opens the barrier.
  if [ "$state" = busy ] || history_busy; then
    if [ "$state" != failed ] && [ -z "$ref" ] && no_script; then
      echo "cmux repo: $dir is still being filled by an earlier start; it is left to that one" >&2
      [ "$state" = busy ] && fill=background
      status=kept; sha=$(git -C "$dir" rev-parse --verify --quiet HEAD) || die "no commit checked out in $dir"
      result; exit 0
    fi
    echo "cmux repo: waiting for an earlier start's fill of $dir" >&2
    if [ "$state" = busy ]; then
      c=0; "$wx" repo wait "$dir" 1800 >/dev/null 2>&1 || c=$?
      case $c in 0) state=ready ;; 1) state=failed ;; *) die "$dir is still being filled after 30 min" ;; esac
    fi
    [ ! -f "$history_lock" ] || flock -w 1800 "$history_lock" true || die "$dir is still fetching its history after 30 min"
  fi
  net -C "$dir" fetch --quiet --tags origin
  status=updated
  # A checkout with local changes stays as it is.
  changes=$(g -C "$dir" status --porcelain) || die "cannot read $dir"
  if [ -n "$changes" ]; then status=kept; else switch && forward || die "$why"; fi
  # A head-first clone whose fill did not finish (still sparse, or a barrier its fill left failed
  # after the tree was whole): fill it again, under the barrier.
  if { [ "$(git -C "$dir" config --bool core.sparseCheckout 2>/dev/null)" = true ] && [ -f "$dir/.git/info/sparse-checkout" ]; } ||
    [ "$state" = failed ]; then
    if holder; then tip=1; else
      fill_now || die "cannot check out all of $url"
      fill=done
    fi
  fi
elif [ -e "$dir" ]; then
  die "$dir exists and is not a git checkout"
else
  mkdir -p "$(dirname "$dir")"
  fresh=1
  if [ -z "$ref" ] && holder; then
    net clone --quiet --depth 1 --filter=blob:none --sparse "$url" "$dir"
    # A depth-1 clone fetches only the default branch from then on; every branch, as a whole
    # clone has, so the history fill and a later start's `@branch` see them all.
    g -C "$dir" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' ||
      { rm -rf "$dir"; die "cannot track the branches of $url"; }
    # shellcheck disable=SC2086 # one word per folder
    if g -C "$dir" sparse-checkout add $head_dirs; then
      tip=1
    else
      # A harness folder that is a symlink or a file is no sparse folder: the whole tree, now.
      g -C "$dir" sparse-checkout disable && g -C "$dir" fetch --quiet --unshallow --filter=blob:none origin ||
        { rm -rf "$dir"; die "cannot check out all of $url"; }
      fill=done
    fi
  else
    net clone --quiet --filter=blob:none "$url" "$dir"
    switch || { rm -rf "$dir"; die "$why"; }
  fi
  status=cloned
fi
# The checkout keeps the cmux path it cloned with, so the agent's own push and pull there
# work (the token is minted or read per git process, never written to the checkout), unless
# it has a helper of its own for the host. The empty value first drops a global helper for
# the host in this checkout only.
if { [ "$cred" = cmux-github ] || [ "$cred" = cmux-gitlab ]; } && ! git -C "$dir" config --local --get-all "$key.helper" >/dev/null; then
  git -C "$dir" config --local --add "$key.helper" "" &&
    git -C "$dir" config --local --add "$key.helper" "$helper" &&
    git -C "$dir" config --local "$key.useHttpPath" true ||
    echo "cmux repo: cannot keep the $host path in $dir, so a push there needs credentials" >&2
fi
sha=$(g -C "$dir" rev-parse --verify --quiet HEAD) || die "no commit checked out in $dir"
[ -z "$tip" ] || fill_later
result
