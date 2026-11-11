#!/usr/bin/env bash
# Pre-downloads the hashed packages a Zig source's build.zig.zon files name,
# with curl, into Zig's global cache as p/<hash>.tar.gz, so `zig build
# --fetch=all` unpacks them with no network.
#
# First, from our mirror: every package scripts/ci/zig-packages.lock tags with
# the source's name (ghostty-next, ghostty, or CMUX_ZIG_LOCK_TAG), transitive
# ones included, each checked against the sha256 the lock pins. No build
# fetches from a third-party host (scripts/ci/zig_package_mirror.py). With
# CMUX_ZIG_MIRROR_ONLY=1 (the default when CI=true; 0 turns it off) the seed
# stops there, and Zig, given no route out by its caller, fails by name on a
# package the mirror lacks. Otherwise the upstream rounds below fill the rest.
# Zig's own HTTP read has no retry,
# resume or speed floor: a mid-stream "ReadFailed" from deps.files.ghostty.org
# failed every attempt of a job (cmux-tui publisher run 40651931144, freetype).
# Zig 0.16 unpacks a cached p/<hash>.tar.gz before it fetches the URL and checks
# the package hash of what it unpacked, so a seeded archive cannot bring in
# other bytes than the build.zig.zon pins. A .tar.xz or .tar.zst download is
# re-compressed to gzip, the one format Zig reads from p/.
#
# Best effort: a package that cannot be seeded is left for Zig to fetch, and
# this script exits 0.
#
# Packages a package names: after each round, the build.zig.zon of every package
# seeded or already here (its archive in p/, or its zig-pkg/<hash>/) is read the
# same way, and what it names is seeded in the next round (at most
# CMUX_ZIG_SEED_DEPTH rounds, default 4). Zig's own fetch of a git+ dependency
# has no retry or mirror: translate_c's git+https://codeberg.org/ziglang/arocc
# failed every attempt while codeberg's git server was down (cmux#41132, run
# 43001525569, "unable to discover remote git server capabilities"). A
# git+https://HOST/PATH#COMMIT is seeded as HOST/PATH/archive/COMMIT.tar.gz (the
# archive URL GitHub, Codeberg and other Forgejo or Gitea hosts serve), then from
# each mirror below in order. Zig checks the package hash of what it unpacks, so
# a mirror cannot bring in other bytes than the pinned commit's tree.
#
# usage: seed-zig-package-archives.sh CACHE_DIR [SOURCE_DIR]
# CMUX_ZIG_SEED_MIRRORS: more "FROM=TO" URL prefix rewrites, space-separated,
# tried after ZIG_SEED_MIRRORS's (a test serves its own).
# CMUX_ZIG_SEED_PARALLEL (default 16) downloads run at once, and the whole seed
# stops after CMUX_ZIG_SEED_TIMEOUT seconds (default 300), leaving the rest to Zig.
set -euo pipefail

if [[ "${1:-}" == --one ]]; then
  # One package: --one CACHE HASH URL. Written under a name with no archive
  # suffix, checked, then renamed into place, so a cut-short download never
  # takes the final name.
  # URLS is one URL or several joined by |, tried in order (a mirror after its origin).
  # SHA256, when given (a copy from our mirror), must match the downloaded bytes.
  cache="$2" hash="$3" urls="$4" want="${5:-}"
  final="$cache/p/$hash.tar.gz"
  [[ -e "$final" ]] && exit 0
  part="$cache/p/.seed-$hash-$$"
  trap 'rm -f "$part" "$part.raw"' EXIT
  trap 'exit 143' TERM
  IFS='|' read -r -a candidates <<<"$urls"
  for url in "${candidates[@]}"; do
    rm -f "$part" "$part.raw"
    # --retry-max-time caps a server's Retry-After too (it can ask for an hour).
    curl -fsSL --proto '=http,https' --retry 3 --retry-delay 3 --retry-all-errors --retry-max-time 60 \
      --connect-timeout 20 --speed-limit 51200 --speed-time 20 --max-time 120 \
      -o "$part.raw" "$url" 2>/dev/null || { echo "seed: could not download $url" >&2; continue; }
    case "$url" in
      *.tar.gz|*.tgz) mv "$part.raw" "$part" ;;
      *.tar.xz) xz -dc "$part.raw" | gzip -n > "$part" || continue ;;
      *.tar.zst) zstd -dcq "$part.raw" | gzip -n > "$part" || continue ;;
      *) continue ;;
    esac
    # A whole tar with entries, not only whole gzip: a host can answer 200 with a
    # gzipped error page (GNU tar lists a short non-tar as an empty archive, exit 0).
    # Counted, not kept: a listing can be long. pipefail keeps tar's own status.
    entries="$(tar -tzf "$part" 2>/dev/null | wc -l)" && (( entries > 0 )) \
      || { echo "seed: $url is not a whole tar archive" >&2; continue; }
    if [[ -n "$want" ]]; then
      if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$part" | cut -d' ' -f1)"
      else got="$(shasum -a 256 "$part" | cut -d' ' -f1)"; fi
      [[ "$got" == "$want" ]] || { echo "seed: $url has sha256 $got, the lock pins $want" >&2; continue; }
    fi
    mv -f "$part" "$final"
    exit 0
  done
  exit 1
fi

cache="${1:?usage: seed-zig-package-archives.sh CACHE_DIR [SOURCE_DIR]}"
source_dir="${2:-.}"
lock="${CMUX_ZIG_LOCK:-$(cd "$(dirname "$0")" && pwd)/zig-packages.lock}"
lock_tag="${CMUX_ZIG_LOCK_TAG:-$(basename "$(cd "$source_dir" && pwd)")}"
mirror_only="${CMUX_ZIG_MIRROR_ONLY:-}"
[[ -n "$mirror_only" ]] || { [[ "${CI:-}" == true ]] && mirror_only=1 || mirror_only=0; }
parallel="${CMUX_ZIG_SEED_PARALLEL:-16}"
seed_timeout="${CMUX_ZIG_SEED_TIMEOUT:-300}"
depth="${CMUX_ZIG_SEED_DEPTH:-4}"
for value in "$parallel" "$seed_timeout" "$depth"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "error: CMUX_ZIG_SEED_PARALLEL, CMUX_ZIG_SEED_TIMEOUT and CMUX_ZIG_SEED_DEPTH must be positive whole numbers" >&2; exit 2; }
done
command -v curl >/dev/null 2>&1 || { echo "seed: no curl; Zig fetches every package"; exit 0; }
mkdir -p "$cache/p"

# Every `.url = "..."` followed by its `.hash = "..."` in the source's own
# build.zig.zon files, one "hash url" line each. A line that starts with //
# is a comment (a URL's own // is not).

# Every `.url = "..."` followed by its `.hash = "..."` in the build.zig.zon text
# on stdin, one "hash url" line each. A line that starts with // is a comment
# (a URL's own // is not).
zon_pairs() {
  awk '
    # The line with any // comment outside a quoted string removed.
    function code(line,    out, i, c, quoted) {
      out = ""; quoted = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\\" && quoted) { out = out c substr(line, i + 1, 1); i++; continue }
        if (c == "\"") quoted = !quoted
        if (!quoted && c == "/" && substr(line, i + 1, 1) == "/") break
        out = out c
      }
      return out
    }
    # Every .url or .hash value on the line, in order, as "name value" lines.
    {
      line = code($0)
      while (match(line, "\\.(url|hash)[[:space:]]*=[[:space:]]*\"[^\"]*\"")) {
        item = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        name = item; sub(/[[:space:]]*=.*/, "", name); sub(/^\./, "", name)
        value = item; sub(/^[^"]*"/, "", value); sub(/"$/, "", value)
        if (name == "url") u = value
        else if (u != "") { print value, u; u = "" }
      }
      if (line ~ /^[[:space:]]*\}/ || code($0) ~ /^[[:space:]]*\}/) u = ""
    }
  '
}

# Mirrors: "FROM=TO" URL prefixes; a URL starting with FROM is also tried as TO + the rest.
# Only a package whose commit the mirror holds belongs here (Zig checks the hash anyway).
ZIG_SEED_MIRRORS="https://codeberg.org/ziglang/arocc/=https://github.com/Vexu/arocc/"
# The URLs to try for one dependency URL, joined by |, or nothing when curl cannot fetch it.
seed_urls() {
  local url="$1" out="" rule from to
  case "$url" in
    git+http://*|git+https://*)
      # git+https://HOST/PATH[.git][?ref=REF]#COMMIT: the commit's archive. A URL with
      # no commit pins nothing curl can fetch.
      [[ "$url" == *"#"* ]] || return 0
      local repo="${url#git+}" commit="${url##*#}"
      repo="${repo%%#*}"; repo="${repo%%\?*}"; repo="${repo%.git}"
      [[ "$commit" =~ ^[0-9a-f]{7,64}$ ]] || return 0
      url="$repo/archive/$commit.tar.gz" ;;
  esac
  case "$url" in
    http://*.tar.gz|https://*.tar.gz|http://*.tgz|https://*.tgz) ;;
    http://*.tar.xz|https://*.tar.xz) command -v xz >/dev/null 2>&1 || return 0 ;;
    http://*.tar.zst|https://*.tar.zst) command -v zstd >/dev/null 2>&1 || return 0 ;;
    *) return 0 ;;
  esac
  out="$url"
  for rule in $ZIG_SEED_MIRRORS ${CMUX_ZIG_SEED_MIRRORS:-}; do
    from="${rule%%=*}" to="${rule#*=}"
    if [[ -n "$from" && "$rule" == *=* && "$url" == "$from"* ]]; then out="$out|$to${url#"$from"}"; fi
  done
  printf '%s' "$out"
}
# The build.zig.zon of package HASH that is here: zig-pkg/HASH/, else the top of its
# archive in p/ (one folder, as Zig strips it, or none). Nothing when neither is here.
package_manifest() {
  local hash="$1" archive="$cache/p/$1.tar.gz" name
  if [[ -f "$source_dir/zig-pkg/$hash/build.zig.zon" ]]; then cat "$source_dir/zig-pkg/$hash/build.zig.zon"; return 0; fi
  if [[ -f "$cache/p/$hash/build.zig.zon" ]]; then cat "$cache/p/$hash/build.zig.zon"; return 0; fi
  [[ -f "$archive" ]] || return 0
  name="$(tar -tzf "$archive" 2>/dev/null | grep -E '^(\./)?([^/]+/)?build\.zig\.zon$' | head -n 1 || true)"
  [[ -n "$name" ]] && tar -xzOf "$archive" "$name" 2>/dev/null || true
}

pairs="$(find "$source_dir" -name build.zig.zon -not -path '*/zig-pkg/*' -not -path '*/.zig-cache/*' -print \
  | while IFS= read -r zon; do zon_pairs < "$zon"; done | sort -u)"

# Of the "hash url" PAIRS on stdin: the ones not here and fetchable become TODO
# ("hash urls" lines); total and present count them all.
plan_round() {
  local hash url urls
  todo=""
  while read -r hash url; do
    [[ -n "$hash" ]] || continue
    total=$((total + 1))
    if [[ -e "$source_dir/zig-pkg/$hash" || -e "$cache/p/$hash.tar.gz" || -e "$cache/p/$hash" ]]; then
      present=$((present + 1)); continue
    fi
    urls="$(seed_urls "$url")"
    [[ -z "$urls" ]] || todo="$todo$hash $urls"$'\n'
  done
  return 0
}

pool="" watchdog="" list=""
# Cancelled (the fetch, or the job, was stopped): stop the downloads too. They
# run in a process group of their own that a signal to ours does not reach.
# xargs can exit before a worker it was stopping has run its EXIT trap, and a
# KILLed worker runs none: wait (bounded) for the group to go, then remove the
# partial downloads of workers that are gone. A live writer's file stays (another
# seed on a reused machine).
drain_pool() {
  local _ part pid
  for _ in 1 2 3 4 5; do kill -0 -- "-$1" 2>/dev/null || break; sleep 1; done
  kill -KILL -- "-$1" 2>/dev/null || true
  # A KILLed worker can still show for a moment (not yet reaped): give it 2 s.
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- "-$1" 2>/dev/null || break; sleep 0.2; done
  for part in "$cache"/p/.seed-*; do
    [[ -e "$part" ]] || continue
    pid="${part%.raw}"; pid="${pid##*-}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then rm -f "$part"; fi
  done
}
stop_seed() {
  if [[ -n "$watchdog" ]]; then kill "$watchdog" 2>/dev/null || true; fi
  if [[ -n "$pool" ]]; then
    kill -TERM -- "-$pool" 2>/dev/null || true
    drain_pool "$pool"
  fi
  if [[ -n "$list" ]]; then rm -f "$list"; fi
}
trap stop_seed EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# Downloads TODO, deadlined at DEADLINE (SECONDS), in a process group of its own.
run_round() {
  local list_left=$((deadline - SECONDS))
  (( list_left > 0 )) || { echo "seed: stopped after ${seed_timeout}s; Zig fetches the rest" >&2; return 0; }
  # In a process group of its own, so the deadline stops every download.
  set -m
  list="$(mktemp "${TMPDIR:-/tmp}/zig-seed.XXXXXX")"
  printf '%s' "$todo" > "$list"
  # One process (not a pipeline), so its pid is the group's id.
  # One package per line: -L 1 keeps a mirror copy's sha256 with its package.
  xargs -L 1 -P "$parallel" "$0" --one "$cache" < "$list" &
  pool=$!
  set +m
  ( while kill -0 "$pool" 2>/dev/null; do
      if (( SECONDS >= deadline )); then
        echo "seed: stopped after ${seed_timeout}s; Zig fetches the rest" >&2
        kill -TERM -- "-$pool" 2>/dev/null; sleep 2; kill -KILL -- "-$pool" 2>/dev/null; exit 0
      fi
      sleep 1
    done ) &
  watchdog=$!
  wait "$pool" 2>/dev/null || true
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  watchdog=""
  drain_pool "$pool"
  pool=""
  rm -f "$list"; list=""
}

deadline=$((SECONDS + seed_timeout))

# Our mirror first: the lock's packages tagged with this source.
todo="" mirror_wanted=0 mirror_total=0 mirror_seeded=0
if [[ -f "$lock" ]]; then
  mirror="$(awk '$1 == "mirror" { print $2; exit }' "$lock")"
  while read -r hash sha tags _upstream _deps; do
    # A line that starts with # is a comment (a git+ URL's #commit is not).
    [[ -n "$hash" && "$hash" != mirror && "$hash" != \#* ]] || continue
    [[ ",$tags," == *",$lock_tag,"* ]] || continue
    mirror_total=$((mirror_total + 1))
    [[ -e "$source_dir/zig-pkg/$hash" || -e "$cache/p/$hash.tar.gz" || -e "$cache/p/$hash" ]] && continue
    todo="$todo$hash $mirror$hash.tar.gz $sha"$'\n'
    mirror_wanted=$((mirror_wanted + 1))
  done < "$lock"
fi
(( mirror_wanted > 0 )) && run_round
while read -r hash _url _sha; do
  [[ -n "$hash" && -e "$cache/p/$hash.tar.gz" ]] && mirror_seeded=$((mirror_seeded + 1))
done <<<"$todo"
echo "Seeded $mirror_seeded of $mirror_wanted Zig package archives from the mirror ($((mirror_total - mirror_wanted)) of $mirror_total tagged $lock_tag already here)."
if (( mirror_seeded < mirror_wanted )); then
  echo "seed: $((mirror_wanted - mirror_seeded)) mirrored package(s) could not be downloaded from $mirror" >&2
fi
if [[ "$mirror_only" == 1 ]]; then
  echo "Mirror only (CMUX_ZIG_MIRROR_ONLY): no package is fetched from its upstream host."
  exit 0
fi

todo="" total=0 present=0 wanted=0 seeded=0 deep_wanted=0 deep_seeded=0
seen="$(printf '%s\n' "$pairs" | awk 'NF { print $1 }')"
plan_round <<<"$pairs"
round=1 top_total=$total top_present=$present round_set="$seen"
while :; do
  count="$(printf '%s' "$todo" | grep -c . || true)"
  (( round == 1 )) && wanted=$count || deep_wanted=$((deep_wanted + count))
  (( count > 0 )) && run_round
  while read -r hash _urls; do
    [[ -n "$hash" && -e "$cache/p/$hash.tar.gz" ]] || continue
    (( round == 1 )) && seeded=$((seeded + 1)) || deep_seeded=$((deep_seeded + 1))
  done <<<"$todo"
  (( round <= depth && SECONDS < deadline )) || break
  # What the packages of this round name (those here: seeded now or already), once each.
  named="$(while read -r hash; do [[ -z "$hash" ]] || package_manifest "$hash" | zon_pairs; done <<<"$round_set" | sort -u)"
  new="$(printf '%s\n' "$named" | SEEN="$seen" awk 'BEGIN { n = split(ENVIRON["SEEN"], s, "\n"); for (i = 1; i <= n; i++) known[s[i]] = 1 }
    NF && !($1 in known) && !($1 in done) { done[$1] = 1; print }')"
  [[ -n "$new" ]] || break
  round_set="$(printf '%s\n' "$new" | awk 'NF { print $1 }')"
  seen="$seen"$'\n'"$round_set"
  total=0 present=0
  plan_round <<<"$new"
  round=$((round + 1))
done
echo "Seeded $seeded of $wanted Zig package archives with curl ($top_present of $top_total already here)."
(( deep_wanted == 0 )) || echo "Seeded $deep_seeded of $deep_wanted Zig package archives that other packages name (git dependencies as archives)."
exit 0
