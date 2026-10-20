#!/usr/bin/env bash
# Warn when a git remote fetches from one place and pushes to another.
#
# On 2026-10-19 ~/Projects/cmux's origin fetched from a local mirror
# (~/Projects/cmux-merge-remote-nightly.git) while pushing to GitHub. Fetches
# silently returned a stale main, and every agent based work on it.
#
# For each remote this compares the effective fetch URL (after url.*.insteadOf)
# with every effective push URL (after pushurl and url.*.pushInsteadOf). It warns
# when the fetch URL is a local path and a push URL is not, or when they name
# different repositories. Silence a deliberate split with:
#   git config remote.<name>.cmuxSplitOk true
#
# The cmux pre-commit and post-merge hooks run this as a warning only (installed
# by scripts/install-git-hooks.sh). Run it by hand as a doctor check:
#   scripts/git-hooks/check-git-remotes.sh [--strict]   (--strict exits 1 on a warning)
set -uo pipefail

strict=0
[ "${1:-}" = --strict ] && strict=1

# Prints "local <path>" or "net <host>/<path>", lowercased, without .git or a trailing /.
identity() {
  local url="$1" kind rest host
  case "$url" in
    file://*) kind=local; rest="${url#file://}" ;;
    /*|./*|../*|~*) kind=local; rest="$url" ;;
    *://*)
      kind=net
      rest="${url#*://}"
      rest="${rest#*@}"
      host="${rest%%/*}"
      host="${host%%:*}"
      rest="$host/${rest#*/}"
      ;;
    *:*)
      # scp-like user@host:path, unless the part before ':' has a '/', which makes it a path.
      if [[ "${url%%:*}" == */* ]]; then
        kind=local; rest="$url"
      else
        kind=net
        rest="${url#*@}"
        rest="${rest%%:*}/${rest#*:}"
      fi
      ;;
    *) kind=local; rest="$url" ;;
  esac
  rest="${rest%/}"
  rest="${rest%.git}"
  printf '%s %s\n' "$kind" "$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')"
}

warned=0
while IFS= read -r remote; do
  [ -n "$remote" ] || continue
  [ "$(git config --bool --get "remote.$remote.cmuxSplitOk" 2>/dev/null)" = true ] && continue
  fetch_url="$(git remote get-url "$remote" 2>/dev/null)" || continue
  fetch_id="$(identity "$fetch_url")"
  while IFS= read -r push_url; do
    [ -n "$push_url" ] || continue
    push_id="$(identity "$push_url")"
    [ "$fetch_id" = "$push_id" ] && continue
    if [ "${fetch_id%% *}" = local ] && [ "${push_id%% *}" = net ]; then
      why="fetches from a local path but pushes to $push_url, so fetches can return a stale copy"
    else
      why="fetches and pushes different repositories"
    fi
    {
      printf '\nwarning: git remote %s %s.\n' "$remote" "$why"
      printf '  fetch: %s\n  push:  %s\n' "$fetch_url" "$push_url"
      if [ "${fetch_id%% *}" = local ] && [ "${push_id%% *}" = net ]; then
        printf '  Fix: git remote set-url %s %s' "$remote" "$push_url"
        [ -n "$(git config --get "remote.$remote.pushurl" 2>/dev/null)" ] && printf ' && git config --unset-all remote.%s.pushurl' "$remote"
        printf '\n'
      else
        printf '  Fix: point both at one repository (git remote set-url %s URL; git config --unset-all remote.%s.pushurl)\n' "$remote" "$remote"
      fi
      printf '  (check url.*.insteadOf rules too: git config --get-regexp %s)\n' "'^url\\.'"
      printf '  If the split is deliberate: git config remote.%s.cmuxSplitOk true\n\n' "$remote"
    } >&2
    warned=1
  done < <(git remote get-url --push --all "$remote" 2>/dev/null)
done < <(git remote 2>/dev/null)

if [ "$warned" = 1 ] && [ "$strict" = 1 ]; then
  exit 1
fi
exit 0
