#!/bin/sh
# cmux machine bootstrap: the repo step (cmux cloud new-machine --repo). It stores no secret
# anywhere: it uses the GitHub access the machine already has, or none (always none off GitHub).
set -u
d=$(cd "$(dirname "$0")" && pwd)
url='@URL@'; ref='@REF@'; dir="$HOME/@DIRECTORY@"; github=@GITHUB@
host='@HOST@'; key="credential.https://$host"
cred=none; helper=""; status=failed; sha=""; why=""; fresh=""
result() {
  printf '{"status":"%s","url":"%s","ref":"%s","dir":"%s","credential":"%s","sha":"%s"}\n' \
    "$status" "$url" "$ref" "$dir" "$cred" "$sha" >"$d/repo-status.json.tmp" && mv -f "$d/repo-status.json.tmp" "$d/repo-status.json"
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
  [ "$github" = 1 ] || die "$url cannot be cloned without credentials (private, not found, or offline); add a token for $host to this machine"
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
if [ -d "$dir/.git" ]; then
  net -C "$dir" fetch --quiet --tags origin
  status=updated
  # A checkout with local changes stays as it is.
  changes=$(g -C "$dir" status --porcelain) || die "cannot read $dir"
  if [ -n "$changes" ]; then status=kept; else switch && forward || die "$why"; fi
elif [ -e "$dir" ]; then
  die "$dir exists and is not a git checkout"
else
  mkdir -p "$(dirname "$dir")"
  fresh=1
  net clone --quiet --filter=blob:none "$url" "$dir"
  switch || { rm -rf "$dir"; die "$why"; }
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
result
