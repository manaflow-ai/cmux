#!/usr/bin/env bash
# Pre-downloads the hashed packages of a Zig source into Zig's global cache as
# p/<hash>.tar.gz, so `zig build` unpacks them with no network. Zig 0.16 and
# 0.17 read a cached p/<hash>.tar.gz before they fetch the URL and check the
# package hash of what they unpacked (lib/compiler/Maker/Fetch.zig), so a
# seeded archive cannot bring in other bytes than the build.zig.zon pins.
#
# First, from our mirror: every package scripts/ci/zig-packages.lock tags with
# the source's name (ghostty-next, ghostty), transitive ones included, each
# checked against the sha256 the lock pins. No build fetches from a third-party
# host: codeberg.org's outage on 2026-11-11 failed every cold libghostty-vt
# build (translate_c's aro is git+https://codeberg.org/ziglang/arocc).
# scripts/ci/zig_package_mirror.py check (ci-guards.yml) keeps the lock whole.
#
# Then, unless the mirror is the only source (CMUX_ZIG_MIRROR_ONLY: 1, the
# default when CI=true; 0 turns it off), the URLs the source's own
# build.zig.zon files name, for anything the mirror did not supply. Zig's own
# HTTP read has no retry, resume or speed floor: a mid-stream "ReadFailed" from
# deps.files.ghostty.org failed every attempt of a job (cmux-tui publisher run
# 40651931144, freetype). A .tar.xz or .tar.zst download is re-compressed to
# gzip, the one format Zig reads from p/.
#
# Best effort: a package that cannot be seeded is left for Zig (which, mirror
# only, fails naming it), and this script exits 0.
#
# usage: seed-zig-package-archives.sh CACHE_DIR [SOURCE_DIR]
# CMUX_ZIG_SEED_PARALLEL (default 16) downloads run at once, and each pass
# stops after CMUX_ZIG_SEED_TIMEOUT seconds (default 300), leaving the rest to
# Zig. CMUX_ZIG_LOCK (default scripts/ci/zig-packages.lock) and
# CMUX_ZIG_LOCK_TAG (default: the source directory's name) pick the mirror's
# packages.
set -euo pipefail

if [[ "${1:-}" == --one ]]; then
  # One package: --one CACHE HASH URL [SHA256]. Written under a name with no
  # archive suffix, checked, then renamed into place, so a cut-short download
  # never takes the final name. A mirror copy is checked against its sha256.
  cache="$2" hash="$3" url="$4" want="${5:-}"
  final="$cache/p/$hash.tar.gz"
  [[ -e "$final" ]] && exit 0
  part="$cache/p/.seed-$hash-$$"
  trap 'rm -f "$part" "$part.raw"' EXIT
  trap 'exit 143' TERM
  # --retry-max-time caps a server's Retry-After too (it can ask for an hour).
  curl -fsSL --proto '=http,https' --retry 3 --retry-delay 3 --retry-all-errors --retry-max-time 60 \
    --connect-timeout 20 --speed-limit 51200 --speed-time 20 --max-time 120 \
    -o "$part.raw" "$url" 2>/dev/null || { echo "seed: could not download $url" >&2; exit 1; }
  case "$url" in
    *.tar.gz|*.tgz) mv "$part.raw" "$part" ;;
    *.tar.xz) xz -dc "$part.raw" | gzip -n > "$part" ;;
    *.tar.zst) zstd -dcq "$part.raw" | gzip -n > "$part" ;;
    *) exit 1 ;;
  esac
  # A whole tar with entries, not only whole gzip: a host can answer 200 with a
  # gzipped error page (GNU tar lists a short non-tar as an empty archive, exit 0).
  # Counted, not kept: a listing can be long. pipefail keeps tar's own status.
  entries="$(tar -tzf "$part" 2>/dev/null | wc -l)" && (( entries > 0 )) \
    || { echo "seed: $url is not a whole tar archive" >&2; exit 1; }
  if [[ -n "$want" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$part" | cut -d' ' -f1)"
    else got="$(shasum -a 256 "$part" | cut -d' ' -f1)"; fi
    [[ "$got" == "$want" ]] || { echo "seed: $url has sha256 $got, the lock pins $want" >&2; exit 1; }
  fi
  mv -f "$part" "$final"
  exit 0
fi

cache="${1:?usage: seed-zig-package-archives.sh CACHE_DIR [SOURCE_DIR]}"
source_dir="${2:-.}"
lock="${CMUX_ZIG_LOCK:-$(cd "$(dirname "$0")" && pwd)/zig-packages.lock}"
lock_tag="${CMUX_ZIG_LOCK_TAG:-$(basename "$(cd "$source_dir" && pwd)")}"
mirror_only="${CMUX_ZIG_MIRROR_ONLY:-}"
[[ -n "$mirror_only" ]] || { [[ "${CI:-}" == true ]] && mirror_only=1 || mirror_only=0; }
parallel="${CMUX_ZIG_SEED_PARALLEL:-16}"
seed_timeout="${CMUX_ZIG_SEED_TIMEOUT:-300}"
for value in "$parallel" "$seed_timeout"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "error: CMUX_ZIG_SEED_PARALLEL and CMUX_ZIG_SEED_TIMEOUT must be positive whole numbers" >&2; exit 2; }
done
command -v curl >/dev/null 2>&1 || { echo "seed: no curl; Zig fetches every package"; exit 0; }
mkdir -p "$cache/p"

# Every `.url = "..."` followed by its `.hash = "..."` in the source's own
# build.zig.zon files, one "hash url" line each. A line that starts with //
# is a comment (a URL's own // is not).
pairs="$(find "$source_dir" -name build.zig.zon -not -path '*/zig-pkg/*' -not -path '*/.zig-cache/*' -print \
  | while IFS= read -r zon; do
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
      ' "$zon"
    done | sort -u)"

# A package already here: unpacked in this checkout or archived in p/.
have() { [[ -e "$source_dir/zig-pkg/$1" || -e "$cache/p/$1.tar.gz" || -e "$cache/p/$1" ]]; }

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

# Download every "hash url [sha256]" line of $1, $parallel at a time, under the
# deadline, in a process group of its own so the deadline stops every download.
run_pool() {
  [[ -n "$1" ]] || return 0
  set -m
  list="$(mktemp "${TMPDIR:-/tmp}/zig-seed.XXXXXX")"
  # One package per line: xargs -L 1 keeps an optional sha256 with its package.
  printf '%s' "$1" > "$list"
  # One process (not a pipeline), so its pid is the group's id.
  xargs -L 1 -P "$parallel" "$0" --one "$cache" < "$list" &
  pool=$!
  set +m
  ( deadline=$((SECONDS + seed_timeout))
    while kill -0 "$pool" 2>/dev/null; do
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

# Pass 1: our mirror, every package of the lock tagged with this source.
mirror_todo="" mirror_wanted=0 mirror_total=0
if [[ -f "$lock" ]]; then
  mirror="$(awk '$1 == "mirror" { print $2; exit }' "$lock")"
  while read -r hash sha tags _upstream _deps; do
    # A line that starts with # is a comment (a git+ URL's #commit is not).
    [[ -n "$hash" && "$hash" != mirror && "$hash" != \#* ]] || continue
    [[ ",$tags," == *",$lock_tag,"* ]] || continue
    mirror_total=$((mirror_total + 1))
    have "$hash" && continue
    mirror_todo="$mirror_todo$hash $mirror$hash.tar.gz $sha"$'\n'
    mirror_wanted=$((mirror_wanted + 1))
  done < "$lock"
fi
run_pool "$mirror_todo"
mirror_seeded=0
while read -r hash _url _sha; do
  [[ -n "$hash" && -e "$cache/p/$hash.tar.gz" ]] && mirror_seeded=$((mirror_seeded + 1))
done <<<"$mirror_todo"
echo "Seeded $mirror_seeded of $mirror_wanted Zig package archives from the mirror ($((mirror_total - mirror_wanted)) of $mirror_total tagged $lock_tag already here)."
if (( mirror_seeded < mirror_wanted )); then
  echo "seed: $((mirror_wanted - mirror_seeded)) mirrored package(s) could not be downloaded from $mirror" >&2
fi
if [[ "$mirror_only" == 1 ]]; then
  echo "Mirror only (CMUX_ZIG_MIRROR_ONLY): no package is fetched from its upstream host."
  exit 0
fi

# Pass 2: the upstream URLs, for what the mirror did not supply.
todo="" total=0 present=0
while read -r hash url; do
  [[ -n "$hash" ]] || continue
  total=$((total + 1))
  if have "$hash"; then
    present=$((present + 1)); continue
  fi
  case "$url" in
    http://*.tar.gz|https://*.tar.gz|http://*.tgz|https://*.tgz) ;;
    http://*.tar.xz|https://*.tar.xz) command -v xz >/dev/null 2>&1 || continue ;;
    http://*.tar.zst|https://*.tar.zst) command -v zstd >/dev/null 2>&1 || continue ;;
    *) continue ;;
  esac
  todo="$todo$hash $url"$'\n'
done <<<"$pairs"

wanted="$(printf '%s' "$todo" | grep -c . || true)"
run_pool "$todo"
seeded=0
while read -r hash _url; do
  [[ -n "$hash" && -e "$cache/p/$hash.tar.gz" ]] && seeded=$((seeded + 1))
done <<<"$todo"
echo "Seeded $seeded of $wanted Zig package archives with curl ($present of $total already here)."
exit 0
