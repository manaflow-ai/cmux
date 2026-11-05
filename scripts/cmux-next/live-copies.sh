#!/usr/bin/env bash
# Live copies: several live copies of cmux's web UI at once, one per worktree, side by side, so several
# agents (or you) can each try a version of one change and you keep the best one.
#
#   live-copies.sh start 3                        # 3 copies of origin/feat-cmux-next, each on a branch of its own
#   live-copies.sh start 3 --from my-branch       # 3 copies of one branch (or sha, tag)
#   live-copies.sh start --from 36378 --from 36340 --from lane/x
#                                                 # one copy per PR (number or URL) or branch
#     [--set NAME]      the set's name (default: live-<time>); `start` again with it adds copies
#     [--page PATH]     what the compare page shows (default /agent-pane/?mock; /settings/?mock, /gallery/, ...)
#     [--windows]       also open each copy as a projection window of your running NIGHTLY or DEV
#                       (projection.sh open): the real app, its glass and settings, that copy's web files
#     [--open]          open the compare page in a cmux browser tab
#   live-copies.sh compare [SET] [--open]         # rewrite the compare page (each copy's changed files) and print it
#   live-copies.sh keep [SET] K [--push] [--stop-others] [--open]
#                                                 # the copy you keep: its worktree, branch and PR (or the URL that
#                                                 # opens one once pushed; --push pushes it first)
#   live-copies.sh status [SET] [--json]          # the copies, their URLs, worktrees and servers
#   live-copies.sh stop [SET]                     # stop the set's dev servers (worktrees stay)
#   live-copies.sh rm [SET] [--force]             # stop them and remove the worktrees (refuses unsaved work without --force)
#
# Each copy is a git worktree of this clone under the set's folder ($CMUX_LIVE_COPIES_DIR, default
# ~/Library/Caches/cmux-next/live-copies on macOS, ~/.cache/cmux-next/live-copies elsewhere), with its own
# webviews dev server on its own port (projection.sh serve, 4290-4389) and its own state folder
# (CMUX_WEBVIEWS_DEV_STATE_DIR: the agent pane's git and file reads see that worktree). Save a web file in a
# copy and only that copy's frame and window reload (Vite HMR). The compare page puts every copy side by
# side, live, with "Keep this one" on each. Point one agent at each worktree that `start` prints.
# node_modules comes from this checkout as a copy-on-write clone when the lockfiles match, so a copy starts
# in seconds instead of a `bun install`. SET defaults to the newest set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECTION="$ROOT/scripts/cmux-next/projection.sh"
REPO_SLUG="${CMUX_LIVE_COPIES_REPO:-manaflow-ai/cmux}"
BASE_BRANCH="${CMUX_LIVE_COPIES_BASE:-feat-cmux-next}"
if [[ "$(uname)" == Darwin ]]; then default_dir="$HOME/Library/Caches/cmux-next/live-copies"; else default_dir="${XDG_CACHE_HOME:-$HOME/.cache}/cmux-next/live-copies"; fi
DIR="${CMUX_LIVE_COPIES_DIR:-$default_dir}"
cli="${CMUX_CLI:-cmux}"

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }
die() { echo "live-copies: $*" >&2; exit 1; }

# A set's name is one plain folder name under $DIR: never a path, never ".." or a dot folder.
valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
newest_set() {
  local name
  # shellcheck disable=SC2045  # newest first; set names are plain (valid_name)
  for name in $(ls -1t "$DIR" 2>/dev/null); do
    if valid_name "$name" && [[ -d "$DIR/$name" ]]; then echo "$name"; return; fi
  done
  die "no live copies yet; run: live-copies.sh start 3"
}
set_dir() {
  valid_name "$1" || die "not a set name: $1 (letters, digits, . _ and -)"
  [[ -d "$DIR/$1" ]] || die "no set $1 in $DIR"
  echo "$DIR/$1"
}

# Whether origin's branch has the copy's HEAD: its tip is HEAD or comes after it.
pushed() {
  local tree="$1" branch="$2" remote
  remote="$(git -C "$tree" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)"
  [[ -n "$remote" ]] || return 1
  [[ "$remote" == "$(git -C "$tree" rev-parse HEAD)" ]] || git -C "$tree" merge-base --is-ancestor HEAD "$remote" 2>/dev/null
}
copies_of() {
  local f
  for f in "$1"/*/; do f="$(basename "$f")"; if [[ "$f" =~ ^[0-9]+$ ]]; then echo "$f"; fi; done | sort -n
}
meta() { cat "$1/$2" 2>/dev/null || true; }

# The copy's dev server state (projection.sh keys it by worktree under CMUX_PROJECTION_STATE_DIR).
pstate() { CMUX_PROJECTION_STATE_DIR="$1/server" "$PROJECTION" "${@:2}"; }

# "36378", "#36378" or a pull URL -> 36378; anything else -> empty.
pr_number() {
  local s="${1#\#}"
  [[ "$s" =~ ^[0-9]+$ ]] && { echo "$s"; return; }
  [[ "$s" =~ /pull/([0-9]+) ]] && { echo "${BASH_REMATCH[1]}"; return; }
  return 0
}

# Copy-on-write clone of this checkout's node_modules when the lockfiles match (APFS clonefile, reflink on
# Linux, else a plain copy is skipped and projection.sh runs bun install).
seed_node_modules() {
  local tree="$1" src="$ROOT/webviews/node_modules"
  [[ -d "$src" && ! -e "$tree/webviews/node_modules" ]] || return 0
  cmp -s "$ROOT/webviews/bun.lock" "$tree/webviews/bun.lock" 2>/dev/null || return 0
  if [[ "$(uname)" == Darwin ]]; then cp -cR "$src" "$tree/webviews/node_modules" 2>/dev/null || rm -rf "$tree/webviews/node_modules"
  else cp -R --reflink=always "$src" "$tree/webviews/node_modules" 2>/dev/null || rm -rf "$tree/webviews/node_modules"; fi
}

add_copy() {
  local setd="$1" k="$2" source="$3" set_name="$4" copy="$1/$2" tree pr branch ref
  tree="$copy/tree"
  mkdir -p "$copy/state"
  pr="$(pr_number "$source")"
  branch="live-copy/$set_name/$k"
  if [[ -n "$pr" ]]; then
    # Its own branch at the PR's head: keeping it never pushes onto the PR, whoever owns that.
    git -C "$ROOT" fetch -q origin "pull/$pr/head" || die "could not fetch PR #$pr"
    ref="$(git -C "$ROOT" rev-parse FETCH_HEAD)"
    echo "https://github.com/$REPO_SLUG/pull/$pr" >"$copy/pr"
  else
    # A ref this clone has (a sha, HEAD, a tag, a local or origin/ branch), else origin's branch of that name.
    if git -C "$ROOT" rev-parse -q --verify "$source^{commit}" >/dev/null 2>&1; then ref="$source"
    elif git -C "$ROOT" fetch -q origin "refs/heads/$source:refs/remotes/origin/$source" 2>/dev/null; then ref="origin/$source"
    else die "no such PR, branch or ref: $source"; fi
  fi
  git -C "$ROOT" worktree add -q -b "$branch" "$tree" "$ref"
  echo "$branch" >"$copy/branch"
  git -C "$tree" rev-parse HEAD >"$copy/base"
  echo "$source" >"$copy/source"
  echo "$tree" >"$copy/state/cwd"   # the agent pane's dev host reads git and files here (agentGitHost.ts)
  seed_node_modules "$tree"
}

serve_copy() {
  local copy="$1" out port
  out="$(CMUX_WEBVIEWS_DEV_STATE_DIR="$copy/state" pstate "$copy" serve "$copy/tree")" || return 1
  port="$(printf '%s\n' "$out" | sed -nE 's#.*http://127\.0\.0\.1:([0-9]+)/.*#\1#p' | head -1)"
  [[ -n "$port" ]] || die "no port from projection.sh serve: $out"
  echo "$port" >"$copy/port"
}

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

# copies.json: what the compare page and agents read.
write_json() {
  local setd="$1" name first=1 k copy
  name="$(basename "$setd")"
  {
    printf '{"set": %s, "page": %s, "repo": %s, "base": %s, "copies": [' "$(json_str "$name")" "$(json_str "$(meta "$setd" page)")" "$(json_str "$REPO_SLUG")" "$(json_str "$BASE_BRANCH")"
    for k in $(copies_of "$setd"); do
      copy="$setd/$k"
      [[ $first == 1 ]] || printf ','; first=0
      printf '\n  {"index": %s, "source": %s, "branch": %s, "worktree": %s, "port": %s, "pr": %s, "base": %s, "head": %s, "changed": %s}' \
        "$k" "$(json_str "$(meta "$copy" source)")" "$(json_str "$(meta "$copy" branch)")" "$(json_str "$copy/tree")" \
        "$(port="$(meta "$copy" port)"; [[ "$port" =~ ^[0-9]+$ ]] && echo "$port" || echo null)" "$(json_str "$(meta "$copy" pr)")" "$(json_str "$(meta "$copy" base)")" \
        "$(json_str "$(git -C "$copy/tree" rev-parse --short HEAD 2>/dev/null)")" \
        "$(json_str "$(git -C "$copy/tree" status --short 2>/dev/null; git -C "$copy/tree" diff --stat "$(meta "$copy" base)" HEAD 2>/dev/null | tail -1)")"
    done
    printf '\n]}\n'
  } >"$setd/copies.json"
}

write_compare() {
  local setd="$1" data
  write_json "$setd"
  data="$(sed 's#</#<\\/#g' "$setd/copies.json")"   # no "</script>" inside the page's script
  cat >"$setd/compare.html" <<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Live copies: $(basename "$setd" | html_escape)</title>
<style>
  :root { color-scheme: light dark; font: 13px -apple-system, system-ui, sans-serif; }
  body { margin: 0; height: 100vh; display: flex; flex-direction: column; background: Canvas; color: CanvasText; }
  header { display: flex; gap: 8px; align-items: center; padding: 8px 12px; border-bottom: 1px solid color-mix(in srgb, CanvasText 15%, transparent); }
  header input { flex: 1; font: inherit; padding: 4px 8px; }
  main { flex: 1; display: grid; grid-auto-flow: column; grid-auto-columns: 1fr; gap: 1px; background: color-mix(in srgb, CanvasText 15%, transparent); min-height: 0; }
  main.grid { grid-auto-flow: row; grid-template-columns: repeat(2, 1fr); grid-auto-columns: unset; }
  section { display: flex; flex-direction: column; background: Canvas; min-width: 0; min-height: 0; }
  section.kept { outline: 3px solid #2f9e44; outline-offset: -3px; }
  .bar { display: flex; gap: 8px; align-items: baseline; padding: 6px 10px; flex-wrap: wrap; }
  .bar b { font-size: 14px; }
  .bar code { font-size: 11px; opacity: .75; overflow-wrap: anywhere; }
  .bar .changed { font-size: 11px; opacity: .75; white-space: pre-wrap; width: 100%; margin: 0; }
  .bar button { margin-left: auto; font: inherit; }
  iframe { flex: 1; border: 0; width: 100%; background: Canvas; }
</style></head>
<body>
<header>
  <b>Live copies</b><span id="set"></span>
  <input id="page" aria-label="Path every copy shows" spellcheck="false">
  <button id="layout">Grid</button>
</header>
<main id="copies"></main>
<script>
const data = $data;
const pageInput = document.getElementById("page");
document.getElementById("set").textContent = data.set;
const page = () => decodeURIComponent(location.hash.slice(1)) || data.page;
const compareURL = (c) => "https://github.com/" + data.repo + "/compare/" + data.base + "..." + encodeURIComponent(c.branch) + "?expand=1";
function render() {
  pageInput.value = page();
  const main = document.getElementById("copies");
  main.replaceChildren(...data.copies.map((c) => {
    const s = document.createElement("section");
    const bar = document.createElement("div"); bar.className = "bar";
    const title = document.createElement("b"); title.textContent = "Copy " + c.index;
    const src = document.createElement("span"); src.textContent = c.source + " @ " + c.head;
    const where = document.createElement("code"); where.textContent = c.worktree; where.title = "Worktree; click to copy"; where.onclick = () => navigator.clipboard?.writeText(c.worktree);
    const keep = document.createElement("button"); keep.textContent = "Keep this one";
    keep.title = c.pr ? "Open its pull request" : "Open the pull request form for " + c.branch + " (push it first: live-copies.sh keep " + data.set + " " + c.index + " --push)";
    keep.onclick = () => {
      document.querySelectorAll("section").forEach((x) => x.classList.toggle("kept", x === s));
      navigator.clipboard?.writeText("scripts/cmux-next/live-copies.sh keep " + data.set + " " + c.index);
      window.open(c.pr || compareURL(c), "_blank");
    };
    const changed = document.createElement("pre"); changed.className = "changed"; changed.textContent = c.changed || "no changes yet";
    bar.append(title, src, where, keep, changed);
    const frame = document.createElement("iframe");
    frame.src = "http://127.0.0.1:" + c.port + page();
    frame.title = "Copy " + c.index;
    s.append(bar, frame);
    return s;
  }));
}
pageInput.onchange = () => { location.hash = encodeURIComponent(pageInput.value); };
document.getElementById("layout").onclick = (e) => { const m = document.getElementById("copies"); m.classList.toggle("grid"); e.target.textContent = m.classList.contains("grid") ? "Columns" : "Grid"; };
addEventListener("hashchange", render);
render();
</script>
</body></html>
HTML
  echo "file://$setd/compare.html"
}

open_page() {
  local url="$1" name="$2"
  if command -v "$cli" >/dev/null 2>&1; then
    "$cli" browser open "$url" --name "$name" >/dev/null || echo "live-copies: could not open a cmux browser tab; open $url" >&2
  else
    echo "live-copies: no cmux CLI here; open $url yourself" >&2
  fi
}


cmd="${1:-}"; [[ -n "$cmd" ]] || usage 1; shift
case "$cmd" in
  start)
    count="" sources=() set_name="" page="/agent-pane/?mock" windows=0 open=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --from) sources+=("${2:?--from needs a PR, branch or ref}"); shift 2 ;;
        --set) set_name="${2:?--set needs a name}"; shift 2 ;;
        --page) page="${2:?--page needs a path}"; shift 2 ;;
        --windows) windows=1; shift ;;
        --open) open=1; shift ;;
        -h|--help) usage ;;
        [0-9]*) count="$1"; shift ;;
        *) usage 1 ;;
      esac
    done
    [[ "$page" == /* ]] || page="/$page"
    if [[ ${#sources[@]} -eq 0 ]]; then
      git -C "$ROOT" fetch -q origin "refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" || true
      sources=("origin/$BASE_BRANCH")
    fi
    if [[ -n "$count" && ${#sources[@]} -eq 1 ]]; then
      one="${sources[0]}"; sources=(); for ((i = 0; i < count; i++)); do sources+=("$one"); done
    elif [[ -n "$count" && "$count" != "${#sources[@]}" ]]; then
      die "$count copies but ${#sources[@]} --from; give one --from per copy or one for all"
    fi
    set_name="${set_name:-live-$(date +%Y%m%d-%H%M%S)}"
    valid_name "$set_name" || die "not a set name: $set_name (letters, digits, . _ and -)"
    setd="$DIR/$set_name"; mkdir -p "$setd"; echo "$page" >"$setd/page"
    last="$(copies_of "$setd" | tail -1)"; k="${last:-0}"
    for source in "${sources[@]}"; do
      k=$((k + 1))
      add_copy "$setd" "$k" "$source" "$set_name"
      echo "copy $k: $source -> $setd/$k/tree (branch $(meta "$setd/$k" branch))"
    done
    # Servers one at a time: projection.sh picks the next free port as each one listens.
    for k in $(copies_of "$setd"); do
      serve_copy "$setd/$k"
      echo "copy $k: http://127.0.0.1:$(meta "$setd/$k" port)$page"
      if [[ $windows == 1 ]]; then
        "$cli" action run debug.projection --server "http://127.0.0.1:$(meta "$setd/$k" port)/" --worktree "$setd/$k/tree" >/dev/null \
          || echo "live-copies: no projection window for copy $k (a NIGHTLY or DEV must be running)" >&2
      fi
    done
    url="$(write_compare "$setd")"
    echo "compare: $url"
    echo "set: $set_name   (live-copies.sh keep $set_name K when you pick one)"
    if [[ $open == 1 ]]; then open_page "$url" "live copies: $set_name"; fi
    ;;
  compare)
    if [[ $# -gt 0 && "$1" != -* ]]; then set_name="$1"; shift; else set_name="$(newest_set)"; fi
    url="$(write_compare "$(set_dir "$set_name")")"
    echo "$url"
    if [[ "${1:-}" == --open ]]; then open_page "$url" "live copies: $set_name"; fi
    ;;
  keep)
    if [[ $# -gt 1 && "$2" != -* ]]; then set_name="$1"; shift; else set_name="$(newest_set)"; fi
    k="${1:?keep needs the copy number}"; shift
    [[ "$k" =~ ^[0-9]+$ ]] || die "keep: $k is not a copy number"
    setd="$(set_dir "$set_name")"; copy="$setd/$k"; [[ -d "$copy/tree" ]] || die "no copy $k in $set_name"
    push=0 stop_others=0 open=0
    for a in "$@"; do case "$a" in --push) push=1 ;; --stop-others) stop_others=1 ;; --open) open=1 ;; *) usage 1 ;; esac; done
    branch="$(meta "$copy" branch)" pr="$(meta "$copy" pr)"
    if [[ $push == 1 ]]; then
      git -C "$copy/tree" push -u origin "HEAD:refs/heads/$branch"
    fi
    url="https://github.com/$REPO_SLUG/compare/$BASE_BRANCH...$branch?expand=1"
    edited="$(git -C "$copy/tree" rev-list --count "$(meta "$copy" base)..HEAD")"
    if [[ -n "$pr" && "$edited" == 0 ]]; then url="$pr"; fi
    echo "kept copy $k of $set_name"
    echo "worktree: $copy/tree"
    echo "branch:   $branch ($edited commits on $(meta "$copy" source))"
    if [[ -n "$(git -C "$copy/tree" status --porcelain -- . ':!webviews/node_modules')" ]]; then echo "note:     uncommitted changes in the worktree; commit them before you push"; fi
    if [[ "$url" == "$pr" ]]; then echo "pr:       $pr (unchanged copy of it)"
    elif pushed "$copy/tree" "$branch"; then echo "open a PR: $url"
    else echo "open a PR: push first (live-copies.sh keep $set_name $k --push), then $url"; fi
    if [[ $stop_others == 1 ]]; then
      for o in $(copies_of "$setd"); do [[ "$o" == "$k" ]] || pstate "$setd/$o" stop "$setd/$o/tree" >/dev/null; done
      echo "stopped the other copies' servers"
    fi
    echo "$k" >"$setd/kept"
    if [[ $open == 1 ]]; then open_page "$url" "kept: $set_name copy $k"; fi
    ;;
  status)
    if [[ $# -gt 0 && "$1" != -* ]]; then set_name="$1"; shift; else set_name="$(newest_set)"; fi
    setd="$(set_dir "$set_name")"
    if [[ "${1:-}" == --json ]]; then write_json "$setd"; cat "$setd/copies.json"; exit 0; fi
    echo "set $set_name (page $(meta "$setd" page))"
    for k in $(copies_of "$setd"); do
      s="$(pstate "$setd/$k" status "$setd/$k/tree")"
      printf 'copy %s  %-40s %s\n         %s\n' "$k" "$(meta "$setd/$k" branch)" "${s#dev server: }" "$setd/$k/tree"
    done
    if [[ -f "$setd/kept" ]]; then echo "kept: copy $(cat "$setd/kept")"; fi
    echo "compare: file://$setd/compare.html"
    ;;
  stop)
    if [[ $# -gt 0 && "$1" != -* ]]; then set_name="$1"; shift; else set_name="$(newest_set)"; fi
    setd="$(set_dir "$set_name")"
    for k in $(copies_of "$setd"); do pstate "$setd/$k" stop "$setd/$k/tree"; done
    ;;
  rm)
    if [[ $# -gt 0 && "$1" != -* ]]; then set_name="$1"; shift; else set_name="$(newest_set)"; fi
    force=0; [[ "${1:-}" == --force ]] && force=1
    setd="$(set_dir "$set_name")"
    for k in $(copies_of "$setd"); do
      tree="$setd/$k/tree"
      [[ -d "$tree" ]] || continue
      if [[ $force == 0 && -n "$(git -C "$tree" status --porcelain --untracked-files=normal -- . ':!webviews/node_modules' 2>/dev/null)" ]]; then
        die "copy $k has unsaved work ($tree); commit it, or rm --force"
      fi
      branch="$(meta "$setd/$k" branch)"
      if [[ $force == 0 && -n "$(git -C "$tree" log --oneline "$(meta "$setd/$k" base)..HEAD" 2>/dev/null)" ]] \
        && ! pushed "$tree" "$branch"; then
        die "copy $k has commits that are not pushed ($branch); keep $set_name $k --push, or rm --force"
      fi
    done
    for k in $(copies_of "$setd"); do
      pstate "$setd/$k" stop "$setd/$k/tree" >/dev/null 2>&1 || true
      rm -rf "$setd/$k/tree/webviews/node_modules"
      git -C "$ROOT" worktree remove --force "$setd/$k/tree" 2>/dev/null || true
      branch="$(meta "$setd/$k" branch)"
      [[ "$branch" == live-copy/* ]] && git -C "$ROOT" branch -D "$branch" >/dev/null 2>&1 || true
    done
    rm -rf "$setd"
    echo "removed $set_name"
    ;;
  -h|--help) usage ;;
  *) usage 1 ;;
esac
