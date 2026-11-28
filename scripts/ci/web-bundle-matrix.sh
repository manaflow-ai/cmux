#!/usr/bin/env bash
# Every way the cmux-next web bundles can break, run at once on a few cores, failing with file:line.
#
#   scripts/ci/web-bundle-matrix.sh [--jobs N] [--out DIR] [--no-install] [--skip JOB]... [--list]
#
# Why: 2026-11-26 and -27 the nightly died for hours at "Build the web bundles (cmux-next)" on a duplicate
# `layoutGeometry` import in VirtualTranscript.tsx: two pull requests each added the import, each was green
# alone, and nothing built the merged tree's bundles before the nightly did. Seven lanes opened a fix.
# Leo: "you guys can think of every possible way bundles can break and just run all that shit in parallel
# or some shit on a couple cores".
#
# It is a build check of what ships, not a policy: it runs the nightly's own builders (every one
# scripts/cmux-next/build-web-bundles.sh runs) into a scratch directory, and beside them the checks that
# say a bundle will not build or will not load:
#   bundle:agent-pane, bundle:pages, bundle:agent-activity, bundle:webviews-app   the four esbuild/Vite builds,
#                       react-compiler plugin (a compile error fails the build) and CSS/asset resolution included
#   inspector           the committed Chief memory inspector page equals a fresh build
#   typecheck           the type errors that redeclare a name in shipped code (scripts/ci/web_bundle_typecheck.py, from `vp check`);
#                       the rest stays `bun run typecheck`'s
#   lint-redeclare      oxlint no-redeclare on src/ (webviews/scripts/lint/bundle-breakers.json)
#   router-security     the pinned TanStack Router build the app ships (verify-tanstack-router-security.mjs)
#   store-packages      the App Store packages the app bundles copy in (sync-app-runtime.sh --store, as every in-tree build runs it)
# After one serial prelude (bun install, page strings, protocol codegen) the jobs run N at a time (default 3,
# CMUX_WEB_MATRIX_JOBS). The first red stops the rest; its log's first error is printed as FILE:LINE.
#
# Exit 0 green, 1 red (the failing job, FILE:LINE and message on stderr, and in OUT/failure.tsv:
# job TAB file TAB line TAB message), 2 usage or a missing tool. Needs bun and node on PATH, as the builders do.
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
JOBS="${CMUX_WEB_MATRIX_JOBS:-3}"
OUT=""
INSTALL=1
LIST=0
SKIP=" "
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) JOBS="${2:-}"; shift ;;
    --out) OUT="${2:-}"; shift ;;
    --no-install) INSTALL=0 ;;
    --list) LIST=1 ;;
    --skip) SKIP="$SKIP${2:-} "; shift ;;
    -h|--help) sed -n '2,/^set -uo pipefail$/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "usage: $0 [--jobs N] [--out DIR] [--no-install] [--skip JOB]... [--list]" >&2; exit 2 ;;
  esac
  shift
done
case "$JOBS" in ''|*[!0-9]*|0) echo "error: --jobs wants a positive number, got '$JOBS'" >&2; exit 2 ;; esac

# Cheap checks first, so a red they find comes back in seconds; then the builds, longest first. Commands run from the repository root.
W='cd webviews && export PATH="$PWD/node_modules/.bin:$PATH" &&'
JOB_NAMES=(lint-redeclare router-security store-packages inspector typecheck bundle:webviews-app bundle:pages bundle:agent-pane bundle:agent-activity)
JOB_CMDS=(
  "$W vp lint --config scripts/lint/bundle-breakers.json src"
  "$W node scripts/verify-tanstack-router-security.mjs"
  '[ ! -f scripts/cmux-next/sync-app-runtime.sh ] || scripts/cmux-next/sync-app-runtime.sh --store'
  'scripts/cmux-next/build-optchat-inspector-web.sh --check'
  "$W python3 -I ../scripts/ci/web_bundle_typecheck.py"
  'scripts/build-webviews-app.sh --skip-checks --out "$OUT/bundles/webviews-app"'
  'scripts/cmux-next/build-pages-web.sh --out "$OUT/bundles/pages"'
  'scripts/cmux-next/build-agent-pane-web.sh --out "$OUT/bundles/agent-pane"'
  'scripts/cmux-next/build-agent-activity-web.sh --out "$OUT/bundles/agent-activity"'
)

if [ "$SKIP" != " " ]; then
  keep_names=(); keep_cmds=()
  for i in "${!JOB_NAMES[@]}"; do
    case "$SKIP" in *" ${JOB_NAMES[$i]} "*) continue ;; esac
    keep_names+=("${JOB_NAMES[$i]}"); keep_cmds+=("${JOB_CMDS[$i]}")
  done
  JOB_NAMES=("${keep_names[@]}"); JOB_CMDS=("${keep_cmds[@]}")
fi

if [ "$LIST" = 1 ]; then
  for i in "${!JOB_NAMES[@]}"; do printf '%s\t%s\n' "${JOB_NAMES[$i]}" "${JOB_CMDS[$i]}"; done
  exit 0
fi

command -v bun >/dev/null 2>&1 || { echo "error: the web bundle matrix needs bun (webviews/package.json pins it)" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "error: the web bundle matrix needs node 22.18 or newer" >&2; exit 2; }
[ -n "$OUT" ] || OUT="$(mktemp -d "${TMPDIR:-/tmp}/web-bundle-matrix.XXXXXX")"
mkdir -p "$OUT/logs" "$OUT/bundles"
export OUT
cd "$ROOT"
started="$(date +%s)"

# The serial prelude: what every job reads and some would write at once (strings tables, protocol codegen).
prelude() {
  if [ "$INSTALL" = 1 ]; then
    (cd webviews && bun install --frozen-lockfile) || return 1
  fi
  (cd webviews && bun scripts/pages/gen-strings.mjs && bun run protocol:codegen) || return 1
}
if ! prelude > "$OUT/logs/prelude.log" 2>&1; then
  summarize() { :; }
  echo "web bundle matrix: the prelude (bun install, page strings, protocol codegen) failed:" >&2
  tail -n 30 "$OUT/logs/prelude.log" >&2
  printf 'prelude\t\t\tsee %s\n' "$OUT/logs/prelude.log" > "$OUT/failure.tsv"
  exit 1
fi

# First FILE:LINE a log names, and the error line around it. esbuild and Vite print `path:line:col`, Babel
# `msg (line:col)` after the file in its message, Oxlint `,-[path:line:col]`, tsc `path(line,col)`.
FILE_RE='[A-Za-z0-9_@./+-]+\.(tsx|ts|jsx|js|mjs|cjs|css|json|html|sh|py):[0-9]+'
first_error() { # <log>: prints "file<TAB>line<TAB>message"
  local log="$1" loc file line msg
  loc="$(grep -Eo "$FILE_RE" "$log" | grep -v '^node_modules/\|/node_modules/' | head -n 1)"
  if [ -n "$loc" ]; then
    file="${loc%:*}"; line="${loc##*:}"
  else
    file=""; line=""
    # `Identifier 'x' has already been declared. (55:2)` and tsc's `path(55,2)`.
    loc="$(grep -Eo "[A-Za-z0-9_@./+-]+\.(tsx|ts|jsx|js|mjs)\([0-9]+,[0-9]+\)" "$log" | head -n 1)"
    if [ -n "$loc" ]; then file="${loc%%(*}"; line="${loc#*(}"; line="${line%%,*}"; fi
  fi
  # The message: the first line that is an error by form (Oxlint ` x rule`, esbuild `[ERROR]`, tsc/Babel/Vite `error`
  # and `has already been declared`), else the log's last line.
  msg="$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E '^[[:space:]]*(x |[✘×] |error|Error|\[ERROR\]|.*\[ERROR\]|.*already been declared|.*error TS[0-9]+|.*TS[0-9]{4}:)' | head -n 1 | sed 's/^[[:space:]]*//' | cut -c1-300)"
  [ -n "$msg" ] || msg="$(tail -n 1 "$log" | cut -c1-300)"
  printf '%s|%s|%s\n' "$file" "$line" "$msg"
}

set -m # one process group per job, so the first red can stop the rest
PIDS=(); RUNNING=(); NEXT=0; FAILED=""; TOTAL="${#JOB_NAMES[@]}"
SLOTS=()
start_job() { # <index>
  local i="$1" name="${JOB_NAMES[$1]}" log
  log="$OUT/logs/${name//[:\/]/-}.log"
  (
    cd "$ROOT" || exit 2
    s="$(date +%s)"
    bash -c "${JOB_CMDS[$i]}" > "$log" 2>&1
    rc=$?
    echo "$rc $(( $(date +%s) - s ))" > "$OUT/logs/${name//[:\/]/-}.status"
    exit "$rc"
  ) &
  PIDS[$i]=$!
  RUNNING+=("$i")
}
stop_all() {
  local i
  for i in "${RUNNING[@]:-}"; do
    [ -n "$i" ] || continue
    kill -TERM -- "-${PIDS[$i]}" 2>/dev/null || kill -TERM "${PIDS[$i]}" 2>/dev/null || true
  done
}
trap 'stop_all' INT TERM

while [ "$NEXT" -lt "$TOTAL" ] || [ "${#RUNNING[@]}" -gt 0 ]; do
  while [ -z "$FAILED" ] && [ "$NEXT" -lt "$TOTAL" ] && [ "${#RUNNING[@]}" -lt "$JOBS" ]; do
    start_job "$NEXT"; NEXT=$((NEXT + 1))
  done
  still=()
  for i in "${RUNNING[@]:-}"; do
    [ -n "$i" ] || continue
    if kill -0 "${PIDS[$i]}" 2>/dev/null; then
      still+=("$i")
    else
      wait "${PIDS[$i]}"; rc=$?
      if [ "$rc" -ne 0 ] && [ -z "$FAILED" ]; then FAILED="$i"; fi
    fi
  done
  RUNNING=("${still[@]:-}"); [ -n "${RUNNING[0]:-}" ] || RUNNING=()
  if [ -n "$FAILED" ]; then
    stop_all
    for i in "${RUNNING[@]:-}"; do [ -n "$i" ] && wait "${PIDS[$i]}" 2>/dev/null; done
    RUNNING=()
    NEXT="$TOTAL"
    break
  fi
  [ "${#RUNNING[@]}" -eq 0 ] && [ "$NEXT" -ge "$TOTAL" ] && break
  sleep 0.2
done

elapsed=$(( $(date +%s) - started ))
if [ -n "$FAILED" ]; then
  name="${JOB_NAMES[$FAILED]}"
  log="$OUT/logs/${name//[:\/]/-}.log"
  IFS='|' read -r file line msg < <(first_error "$log")
  printf '%s\t%s\t%s\t%s\n' "$name" "$file" "$line" "$msg" > "$OUT/failure.tsv"
  echo "web bundle matrix: RED in ${elapsed}s: $name" >&2
  if [ -n "$file" ]; then echo "  ${file}:${line}: $msg" >&2; else echo "  $msg" >&2; fi
  echo "  log: $log" >&2
  echo "::error file=${file:-webviews/package.json},line=${line:-1},title=web bundle matrix ($name)::$msg"
  tail -n 25 "$log" >&2
  exit 1
fi
for i in "${!JOB_NAMES[@]}"; do
  s="$OUT/logs/${JOB_NAMES[$i]//[:\/]/-}.status"
  printf '  %-26s %ss\n' "${JOB_NAMES[$i]}" "$( [ -f "$s" ] && cut -d' ' -f2 "$s" || echo - )"
done
echo "web bundle matrix: green in ${elapsed}s ($TOTAL jobs, $JOBS at a time)"
