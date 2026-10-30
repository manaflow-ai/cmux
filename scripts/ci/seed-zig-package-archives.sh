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
# Zig too.
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
  gzip -t "$part" 2>/dev/null || { echo "seed: $url is not a whole archive" >&2; exit 1; }
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
pool="" watchdog="" list=""
# Cancelled (the fetch, or the job, was stopped): stop the downloads too. They
# run in a process group of their own that a signal to ours does not reach.
stop_seed() {
  if [[ -n "$watchdog" ]]; then kill "$watchdog" 2>/dev/null || true; fi
  if [[ -n "$pool" ]] && kill -0 -- "-$pool" 2>/dev/null; then
    kill -TERM -- "-$pool" 2>/dev/null || true; sleep 1; kill -KILL -- "-$pool" 2>/dev/null || true
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
  watchdog="" pool=""
fi
seeded=0
while read -r hash _url; do
  [[ -n "$hash" && -e "$cache/p/$hash.tar.gz" ]] && seeded=$((seeded + 1))
done <<<"$todo"
echo "Seeded $seeded of $wanted Zig package archives with curl ($present of $total already here)."
exit 0
