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

# Prints "local <resolved path>" or "net <host[:port]>/<path>". Local paths keep
# their case and .git suffix and are resolved (relative ones against the
# checkout), so two spellings of one directory match and two directories never
# do. Hosts are lowercased and a protocol's default port dropped; other ports
# stay. Only github.com paths are compared case-insensitively.
identity() {
  local url="$1" scheme="" rest host port path
  case "$url" in
    file://*) printf 'local %s\n' "$(resolve_local "${url#file://}")"; return ;;
    /*|./*|../*|~*) printf 'local %s\n' "$(resolve_local "$url")"; return ;;
    *://*)
      scheme="${url%%://*}"
      rest="${url#*://}"
      host="${rest%%/*}"
      path="${rest#"$host"}"
      host="${host##*@}"
      port=""
      if [[ "$host" == *:* ]]; then port="${host##*:}"; host="${host%:*}"; fi
      case "$scheme:$port" in
        ssh:22|git+ssh:22|ssh+git:22|https:443|http:80|git:9418) port="" ;;
      esac
      ;;
    *:*)
      # scp-like user@host:path, unless the part before ':' has a '/', which makes it a path.
      if [[ "${url%%:*}" == */* ]]; then
        printf 'local %s\n' "$(resolve_local "$url")"; return
      fi
      rest="${url#*@}"
      host="${rest%%:*}"
      path="/${rest#*:}"
      port=""
      ;;
    *) printf 'local %s\n' "$(resolve_local "$url")"; return ;;
  esac
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  path="${path%/}"
  path="${path%.git}"
  path="/${path#/}"
  [ "$host" = github.com ] && path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  printf 'net %s%s%s\n' "$host" "${port:+:$port}" "$path"
}

resolve_local() {
  local path="$1"
  case "$path" in \~|\~/*) path="$HOME${path#\~}" ;; esac
  python3 -c 'import os, sys; print(os.path.realpath(os.path.join(sys.argv[2], sys.argv[1])).rstrip("/") or "/")' \
    "$path" "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
}

# Prints each url.<base>.insteadOf rule that rewrites URL, as "<config file> <key> <value>".
rewrites_of() {
  local url="$1" origin key value
  while read -r origin key value; do
    [ -n "$value" ] && [ "${url#"$value"}" != "$url" ] && printf '%s %s %s\n' "${origin#file:}" "$key" "$value"
  done < <(git config --show-origin --get-regexp '^url\..*\.insteadof$' 2>/dev/null)
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
      configured="$(git config --get "remote.$remote.url" 2>/dev/null || true)"
      rules="$(rewrites_of "$configured")"
      if [ -n "$rules" ]; then
        # The fetch URL comes from an insteadOf rewrite; set-url alone would not change it.
        printf '  The fetch URL is rewritten by url.*.insteadOf. Fix: remove the rule:\n'
        while read -r file key value; do
          printf '    git config --file %q --unset %q %q\n' "$file" "$key" "$value"
        done <<<"$rules"
      elif [ "${fetch_id%% *}" = local ] && [ "${push_id%% *}" = net ]; then
        printf '  Fix: git remote set-url %q %q' "$remote" "$push_url"
        [ -n "$(git config --get "remote.$remote.pushurl" 2>/dev/null)" ] && printf ' && git config --unset-all %q' "remote.$remote.pushurl"
        printf '\n'
      else
        printf '  Fix: point both at one repository (git remote set-url %q URL; git config --unset-all %q)\n' "$remote" "remote.$remote.pushurl"
      fi
      printf '  If the split is deliberate: git config %q true\n\n' "remote.$remote.cmuxSplitOk"
    } >&2
    warned=1
  done < <(git remote get-url --push --all "$remote" 2>/dev/null)
done < <(git remote 2>/dev/null)

if [ "$warned" = 1 ] && [ "$strict" = 1 ]; then
  exit 1
fi
exit 0
