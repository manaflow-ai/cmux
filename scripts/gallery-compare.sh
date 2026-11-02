#!/usr/bin/env bash
# Before/after of a pushed branch's webview change, as one URL: every gallery state the change reaches,
# loaded live from the merge-base build (before) and the branch build (after), side by side.
#
#   scripts/gallery-compare.sh                 # the current branch (pushed; HEAD must match its upstream)
#   scripts/gallery-compare.sh fix/my-branch   # any pushed branch of manaflow-ai/cmux
#   scripts/gallery-compare.sh --open          # also open the page in a cmux browser tab
#   scripts/gallery-compare.sh --entry agent-pane.composer   # the page filtered to one entry (a substring)
#   scripts/gallery-compare.sh --background busy   # states over a picture: none|light|dark|busy (env.ts BACKGROUNDS)
#
# It asks the gallery host (cmux-lawrence, manaflow-ai/cmux-gallery `gallery compare`) to build the branch
# and its merge-base and prints https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/compare/<name>/
# (tailnet only). Open it right away: it says what is still building and fills in by itself, usually in
# 1 to 2 minutes after the push. No Swift build and no browser run anywhere: the page loads each state's
# gallery frame from both builds.
set -euo pipefail

host="${CMUX_GALLERY_HOST:-cmux-lawrence}"
branch="" open=0 entry="" background=""
while [ $# -gt 0 ]; do
  case "$1" in
    --open) open=1; shift ;;
    --entry) entry="${2:?--entry needs an entry id}"; shift 2 ;;
    --background)
      background="${2:?--background needs none, light, dark or busy}"; shift 2
      case "$background" in none|light|dark|busy) ;; *) echo "gallery-compare: no background $background (none, light, dark, busy)" >&2; exit 2 ;; esac ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "gallery-compare: unknown option $1" >&2; exit 2 ;;
    *) branch="$1"; shift ;;
  esac
done

if [ -z "$branch" ]; then
  local_branch="$(git rev-parse --abbrev-ref HEAD)"
  [ "$local_branch" != HEAD ] || { echo "gallery-compare: detached HEAD; name the branch" >&2; exit 2; }
  # The branch on GitHub is the upstream's name (origin/<name>), which may differ from the local one.
  upstream_ref="$(git rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null || true)"
  [ -n "$upstream_ref" ] || { echo "gallery-compare: $local_branch has no upstream; push it (git push -u origin HEAD) or name the branch" >&2; exit 1; }
  branch="${upstream_ref#*/}"
  if [ "$(git rev-parse "$upstream_ref")" != "$(git rev-parse HEAD)" ]; then
    echo "gallery-compare: HEAD differs from $upstream_ref; the gallery builds what is on GitHub. Push first." >&2
    exit 1
  fi
fi

quoted="$(printf '%q' "$branch")"
remote="GALLERY_ON_HOST=1 ~/cmux-gallery-host/gallery compare $quoted"
if ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" true 2>/dev/null; then
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" "$remote")" || { printf '%s\n' "$out" >&2; echo "gallery-compare: gallery compare failed on $host" >&2; exit 1; }
elif command -v reach >/dev/null 2>&1; then
  out="$(reach "$host" "$remote")" || { echo "gallery-compare: reach $host failed" >&2; printf '%s\n' "$out" >&2; exit 1; }
else
  echo "gallery-compare: cannot reach $host over ssh (set CMUX_GALLERY_HOST, or install reach)" >&2
  exit 1
fi
url="$(printf '%s\n' "$out" | grep -E '^https://' | tail -1)"
[ -n "$url" ] || { echo "gallery-compare: the host printed no URL" >&2; printf '%s\n' "$out" >&2; exit 1; }
if [ -n "$entry" ]; then url="$url?entry=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$entry")"; fi
# The gallery's own query key (webviews/src/gallery/env.ts): each state's frame over that picture.
if [ -n "$background" ] && [ "$background" != none ]; then
  case "$url" in *\?*) url="$url&background=$background" ;; *) url="$url?background=$background" ;; esac
fi
echo "$url"
if [ "$open" = 1 ]; then
  if command -v cmux >/dev/null 2>&1; then
    cmux browser open "$url" --name "before/after: $branch" >/dev/null || echo "gallery-compare: could not open a cmux browser tab" >&2
  else
    echo "gallery-compare: no cmux CLI here; open the URL yourself" >&2
  fi
fi
