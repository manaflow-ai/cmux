#!/usr/bin/env bash
# TEMPORARY (perf 24569 group 2): bisect the chat-switch bench over pane source commits on the CI runner.
# Delete before merge.
#   bench/bisect-chat-switch.sh SHA[:plain|god|both] ...
# For each point: extract that commit's webviews/ (and the xcstrings catalogs gen-strings reads), overlay this
# checkout's bench/ and test/support/ (the bench stays the tip's), link or install node_modules, build and run
# chat-switch.bench.ts. Prints "BISECT <sha> <mode> <PERF_ROW json>" lines and "REST <sha> <mode> ..." lines.
# PAR (default nproc/4) points run at once; ROUNDS (3), TURNS (300), CHURN (24), MAX_WARM (6).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"
work="${TMPDIR:-/tmp}/bisect-chat-switch"
rm -rf "$work"; mkdir -p "$work"
out="${FAST_CHECKS_OUT:-$work/out}"; mkdir -p "$out"
nproc_="$(nproc)"
PAR="${PAR:-$(( nproc_ / 4 > 0 ? nproc_ / 4 : 1 ))}"
echo "bisect: nproc=$nproc_ par=$PAR points=$*"

shas=()
for point in "$@"; do shas+=("${point%%:*}"); done
git fetch -q --no-tags --depth=1 origin "${shas[@]}" 2>&1 | tail -3 || true

# Untracked generated files of the tip's setup (strings, tokens), used where a commit's own generation fails.
mapfile -t generated < <(cd "$here" && git ls-files -oi --exclude-standard -- src | grep -v node_modules)

prepare() { # sha dir
  local sha="$1" dir="$2"
  mkdir -p "$dir"
  # webviews plus what the pane imports from outside it (repo-root schemas, model catalog, icons, specs, fixtures).
  local paths=(webviews)
  for p in schemas web/data design/icons clients/ts cmux-tui/spec; do
    git cat-file -e "$sha:$p" 2>/dev/null && paths+=("$p")
  done
  git archive "$sha" "${paths[@]}" ':(glob)Packages/**/*.xcstrings' ':(glob)Packages/**/*.json' \
    ':(glob)cmux-tui/crates/**/*.json' | tar -x -C "$dir" || return 1
  local w="$dir/webviews"
  rm -rf "$w/bench" "$w/test/support"
  cp -a "$here/bench" "$w/bench"
  mkdir -p "$w/test"; cp -a "$here/test/support" "$w/test/support"
  for f in "${generated[@]}"; do mkdir -p "$w/$(dirname "$f")"; cp -a "$here/$f" "$w/$f"; done
  if cmp -s "$w/package.json" "$here/package.json" && cmp -s "$w/bun.lock" "$here/bun.lock"; then
    ln -s "$here/node_modules" "$w/node_modules"
  else
    echo "  $sha: package.json or bun.lock differ, installing"
    (cd "$w" && bun install --frozen-lockfile --ignore-scripts >/dev/null 2>&1) || (cd "$w" && bun install --ignore-scripts >/dev/null 2>&1) || return 1
  fi
  (cd "$w" && node scripts/pages/gen-strings.mjs --best-effort >/dev/null 2>&1) || true
}

run_point() { # point
  local point="$1" sha="${1%%:*}" mode="both"
  [[ "$point" == *:* ]] && mode="${point#*:}"
  local dir="$work/$sha" log="$out/$sha"
  if ! prepare "$sha" "$dir" >"$log.prepare.log" 2>&1; then echo "FAIL $sha prepare"; tail -5 "$log.prepare.log"; return; fi
  local fixtures=()
  case "$mode" in plain) fixtures=(plain) ;; god) fixtures=(god) ;; *) fixtures=(plain god) ;; esac
  for fx in "${fixtures[@]}"; do
    local env=(ROUNDS_IGNORED=1)
    [[ "$fx" == god ]] && env=(FIXTURE=god)
    local start=$SECONDS
    (cd "$dir/webviews" && env "${env[@]}" CHURN="${CHURN:-24}" MAX_WARM="${MAX_WARM:-6}" TMPDIR="$dir" \
      timeout 900 bun bench/chat-switch.bench.ts "${ROUNDS:-3}" "${TURNS:-300}") >"$log.$fx.log" 2>&1
    local rc=$?
    echo "DONE $sha $fx rc=$rc $((SECONDS - start))s"
    [[ $rc -ne 0 ]] && tail -15 "$log.$fx.log" | sed "s/^/  $sha $fx | /"
    grep -h '^PERF_ROW' "$log.$fx.log" | sed "s/^PERF_ROW /BISECT $sha $fx /"
    grep -h 'at rest for 5 s\|^unread |^read ahead |^arm ' "$log.$fx.log" | sed "s/^/REST $sha $fx /"
  done
  rm -rf "$dir"
}

running=0
for point in "$@"; do
  run_point "$point" > "$out/${point%%:*}.result" &
  running=$((running + 1))
  if (( running >= PAR )); then wait -n; running=$((running - 1)); fi
done
wait
for point in "$@"; do cat "$out/${point%%:*}.result"; done
