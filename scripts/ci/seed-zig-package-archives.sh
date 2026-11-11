#!/usr/bin/env bash
# Pre-downloads the hashed packages a Zig source's build.zig.zon files name,
# with curl, into Zig's global cache as p/<hash>.tar.gz, so `zig build
# --fetch=all` unpacks them with no network. Zig's own HTTP read has no retry,
# resume or speed floor: a mid-stream "ReadFailed" from deps.files.ghostty.org
# failed every attempt of a job (cmux-tui publisher run 40651931144, freetype).
# Zig 0.16 unpacks a cached p/<hash>.tar.gz before it fetches the URL and checks
# the package hash of what it unpacked, so a seeded archive cannot bring in
# other bytes than the build.zig.zon pins. A .tar.xz or .tar.zst download is
# re-compressed to gzip, the one format Zig reads from p/.
#
# Best effort: a package that cannot be seeded is left for Zig to fetch, and
# this script exits 0. Packages that only a dependency's own build.zig.zon
# names (inside zig-pkg/) are not known before the first fetch and are left to
# Zig too, with one exception: a git dependency. A package this seed has (in p/
# or zig-pkg/) can pin a git repository in its own build.zig.zon (translate_c
# pins aro at git+https://codeberg.org/ziglang/arocc), and a git host outage
# then fails every build (codeberg on 2026-11-11: ProtocolError in runs
# 42995220980, 43000201905, 42998352626). Each such pin needs a line
# "<hash> <tarball url>" in scripts/ci/zig-git-package-mirrors.txt (or the file
# CMUX_ZIG_GIT_MIRRORS names); it is seeded from that tarball like any other
# package. A pin with no line makes this script exit 3 after seeding the rest,
# so a new git-only dependency is named at once instead of failing later at the
# git host.
#
# usage: seed-zig-package-archives.sh CACHE_DIR [SOURCE_DIR]
# CMUX_ZIG_SEED_PARALLEL (default 16) downloads run at once, and the whole seed
# stops after CMUX_ZIG_SEED_TIMEOUT seconds (default 300), leaving the rest to Zig.
set -euo pipefail

if [[ "${1:-}" == --one ]]; then
  # One package: --one CACHE HASH URL. Written under a name with no archive
  # suffix, checked, then renamed into place, so a cut-short download never
  # takes the final name.
  cache="$2" hash="$3" url="$4"
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
  mv -f "$part" "$final"
  exit 0
fi

cache="${1:?usage: seed-zig-package-archives.sh CACHE_DIR [SOURCE_DIR]}"
source_dir="${2:-.}"
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
# Every `.url = "..."` and its `.hash = "..."` in the build.zig.zon files given, one
# "hash url" line each.
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
  ' "$@"
}
pairs="$(find "$source_dir" -name build.zig.zon -not -path '*/zig-pkg/*' -not -path '*/.zig-cache/*' -print \
  | while IFS= read -r zon; do zon_pairs "$zon"; done | sort -u)"

todo="" total=0 present=0
while read -r hash url; do
  [[ -n "$hash" ]] || continue
  total=$((total + 1))
  if [[ -e "$source_dir/zig-pkg/$hash" || -e "$cache/p/$hash.tar.gz" || -e "$cache/p/$hash" ]]; then
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
pool="" watchdog="" list="" one=""
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
  if [[ -n "$one" ]]; then kill -TERM "$one" 2>/dev/null || true; wait "$one" 2>/dev/null || true; fi
  if [[ -n "$pool" ]]; then
    kill -TERM -- "-$pool" 2>/dev/null || true
    drain_pool "$pool"
  fi
  if [[ -n "$list" ]]; then rm -f "$list"; fi
}
trap stop_seed EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
if (( wanted > 0 )); then
  # In a process group of its own, so the deadline stops every download.
  set -m
  list="$(mktemp "${TMPDIR:-/tmp}/zig-seed.XXXXXX")"
  printf '%s' "$todo" > "$list"
  # One process (not a pipeline), so its pid is the group's id.
  xargs -n 2 -P "$parallel" "$0" --one "$cache" < "$list" &
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
fi
seeded=0
while read -r hash _url; do
  [[ -n "$hash" && -e "$cache/p/$hash.tar.gz" ]] && seeded=$((seeded + 1))
done <<<"$todo"
echo "Seeded $seeded of $wanted Zig package archives with curl ($present of $total already here)."

# Git pins in the own build.zig.zon of each package this machine has: seeded from
# the listed tarball, or named and exit 3 when the list has no line for one.
mirrors="${CMUX_ZIG_GIT_MIRRORS:-$(cd "$(dirname "$0")" && pwd)/zig-git-package-mirrors.txt}"
have() { [[ -e "$source_dir/zig-pkg/$1" || -e "$cache/p/$1.tar.gz" || -e "$cache/p/$1" ]]; }
# The package's own build.zig.zon (the shallowest one, not an example's), or nothing.
own_manifest() {
  local hash=$1 archive entry
  for entry in "$source_dir/zig-pkg/$hash/build.zig.zon" "$cache/p/$hash/build.zig.zon"; do
    if [[ -f "$entry" ]]; then cat "$entry"; return 0; fi
  done
  archive="$cache/p/$hash.tar.gz"
  [[ -f "$archive" ]] || return 0
  entry="$(tar -tzf "$archive" 2>/dev/null | grep -E '^(\./)?([^/]+/)?build\.zig\.zon$' \
    | awk -F/ '{ print NF, $0 }' | sort -n | head -1 | cut -d' ' -f2-)" || entry=""
  [[ -n "$entry" ]] && tar -xzOf "$archive" "$entry" 2>/dev/null || true
}
queue="$(while read -r hash _url; do if [[ -n "$hash" ]] && have "$hash"; then echo "$hash"; fi; done <<<"$pairs")"
seen="" unlisted="" git_seeded=0
while [[ -n "$queue" ]]; do
  parent="${queue%%$'\n'*}"
  if [[ "$queue" == *$'\n'* ]]; then queue="${queue#*$'\n'}"; else queue=""; fi
  case " $seen " in *" $parent "*) continue ;; esac
  seen="$seen $parent"
  manifest="$(mktemp "${TMPDIR:-/tmp}/zig-seed-zon.XXXXXX")"
  own_manifest "$parent" > "$manifest"
  inner="$(zon_pairs "$manifest" | sort -u)"
  rm -f "$manifest"
  while read -r hash url; do
    [[ -n "$hash" ]] || continue
    if [[ "$url" == git+* ]] && ! have "$hash"; then
      tarball="$(awk -v h="$hash" '$1 == h { print $2; exit }' "$mirrors" 2>/dev/null || true)"
      if [[ -z "$tarball" ]]; then
        unlisted="$unlisted  $hash $url (pinned by $parent)"$'\n'
        continue
      fi
      # In the background with `wait`, so a TERM to this script is not held until curl ends.
      "$0" --one "$cache" "$hash" "$tarball" &
      one=$!
      if wait "$one"; then
        one=""
        git_seeded=$((git_seeded + 1))
      else
        one=""
        echo "seed: could not seed the git pin $hash from $tarball; Zig fetches $url" >&2
      fi
    fi
    if have "$hash"; then queue="$queue${queue:+$'\n'}$hash"; fi
  done <<<"$inner"
done
(( git_seeded == 0 )) || echo "Seeded $git_seeded git-pinned Zig packages from their listed tarballs."
if [[ -n "$unlisted" ]]; then
  {
    echo "error: a Zig package pins a git dependency that $mirrors has no tarball for:"
    printf '%s' "$unlisted"
    echo "Add a line \"<hash> <tarball url of that commit>\" to scripts/ci/zig-git-package-mirrors.txt"
    echo "(deps.files.ghostty.org/<name>-<commit>.tar.gz often has it; Zig checks the hash, so a wrong tarball fails, never builds)."
  } >&2
  exit 3
fi
exit 0
