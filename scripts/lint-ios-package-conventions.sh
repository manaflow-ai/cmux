#!/usr/bin/env bash
# lint-ios-package-conventions.sh
#
# Mechanical enforcement of the modular-refactor conventions (CLAUDE.md
# "Modern Swift concurrency" + "Package design discipline") over the iOS
# line: the mobile packages and the iOS app shell. ios/CmuxiOS (the rewritten
# app package) is not in scope yet.
#
# A finding is suppressed when the offending line, or one of the two lines
# above it, contains one of:
#   lint:allow            explicit, reviewed exception
#   TRANSITIONAL          marked migration shim (must die in a later wave)
# or, for the carve-out classes only (locks/dispatch/timer), a one-line
# justification comment mentioning "carve-out" or "justification".
#
# Exit codes: 0 clean, 1 violations found.
set -uo pipefail

NAMESPACE_FIX=()
FILES_FROM=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --namespace-fix) NAMESPACE_FIX=(--fix); shift ;;
    --files-from)
      [ "$#" -ge 2 ] || { echo "error: --files-from needs a path" >&2; exit 2; }
      FILES_FROM="$2"
      shift 2
      ;;
    -h|--help)
      echo "usage: $0 [--namespace-fix] [--files-from PATH]"
      exit 0
      ;;
    *) echo "error: unknown option: $1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET_FILES=()
if [ -n "$FILES_FROM" ]; then
  [ -f "$FILES_FROM" ] || { echo "error: files-from list does not exist: $FILES_FROM" >&2; exit 2; }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      Packages/*.swift|ios/cmux/*.swift) [ -f "$path" ] || { echo "error: file does not exist: $path" >&2; exit 2; } ;;
      *) echo "error: scoped lint only accepts Packages/*.swift or ios/cmux/*.swift: $path" >&2; exit 2 ;;
    esac
    TARGET_FILES+=("$path")
  done < "$FILES_FROM"
  [ "${#TARGET_FILES[@]}" -gt 0 ] || exit 0
fi

BASELINE_FILE="scripts/lint-ios-package-conventions-baseline.txt"
SCOPES=()
for d in Packages/Shared/CMUXMobileCore Packages/iOS/CmuxMobile* Packages/Shared/CmuxSyncStore ios/cmux; do
  [ -d "$d" ] && SCOPES+=("$d")
done

fail=0
baselined() { # rule, file, fingerprint
  local key
  [ -f "$BASELINE_FILE" ] || return 1
  key="$(printf '%s\t%s\t%s' "$1" "$2" "$3")"
  grep -Fxq "$key" "$BASELINE_FILE"
}

report() { # rule, severity, file, line, text
  baselined "$1" "$3" "$5" && return 1
  printf '%-7s %-28s %s:%s  %s\n' "$2" "$1" "$3" "$4" "$5"
  return 0
}

suppressed() { # file lineno
  local f="$1" n="$2" start=$(( $2 > 2 ? $2 - 2 : 1 ))
  sed -n "${start},${n}p" "$f" | grep -qE 'lint:allow|TRANSITIONAL' && return 0
  return 1
}

carveout_ok() { # file lineno — carve-out classes may also justify inline
  local f="$1" n="$2" start=$(( $2 > 3 ? $2 - 3 : 1 ))
  sed -n "${start},${n}p" "$f" | grep -qiE 'lint:allow|TRANSITIONAL|carve-out|justification|sanctioned' && return 0
  return 1
}

scan() { # rule severity pattern carveout(0/1) pathspec...
  local rule="$1" sev="$2" pat="$3" carve="$4"; shift 4
  local paths=("$@")
  if [ -n "$FILES_FROM" ]; then paths=("${TARGET_FILES[@]}"); fi
  local grep_args
  if [ -n "$FILES_FROM" ]; then
    grep_args=(-nHE "$pat" "${paths[@]}")
  else
    grep_args=(-rnE "$pat" "${paths[@]}" --include='*.swift' --exclude-dir=.build)
  fi
  while IFS=: read -r f n text; do
    [ -z "$f" ] && continue
    case "$f" in */Tests/*|*Tests.swift|*/.build/*) continue ;; esac
    # skip pure comment lines (doc comments mentioning a banned API are fine)
    echo "$text" | grep -qE '^[[:space:]]*//' && continue
    if [ "$carve" = 1 ]; then carveout_ok "$f" "$n" && continue
    else suppressed "$f" "$n" && continue; fi
    if report "$rule" "$sev" "$f" "$n" "$(echo "$text" | sed 's/^[[:space:]]*//' | cut -c1-90)"; then
      [ "$sev" = ERROR ] && fail=1
    fi
  done < <(grep "${grep_args[@]}" 2>/dev/null)
}

echo "== singletons (no shared-singleton accessors) =="
scan singleton ERROR 'static (let|var) (shared|standard|default)\b' 0 "${SCOPES[@]}"

echo "== combine / old observation =="
scan combine ERROR '(^|[^.])\b(import Combine|@Published|ObservableObject|PassthroughSubject|CurrentValueSubject)\b' 0 "${SCOPES[@]}"

echo "== locks (use actors) =="
scan lock ERROR '\b(NSLock|NSRecursiveLock|OSAllocatedUnfairLock|os_unfair_lock|pthread_mutex_t|DispatchSemaphore|Mutex\()' 1 "${SCOPES[@]}"

echo "== dispatch as sync / timer hacks =="
scan dispatch WARN '\bDispatchQueue\.(main\.async|global)|DispatchQueue\(label' 1 "${SCOPES[@]}"
scan timer ERROR '\b(Timer\.scheduledTimer|asyncAfter)\b' 1 "${SCOPES[@]}"

echo "== KVO =="
scan kvo ERROR 'addObserver\([^)]*forKeyPath' 0 "${SCOPES[@]}"

echo "== untyped wire payloads =="
scan untyped WARN '\[String: Any\]' 1 "${SCOPES[@]}"

echo "== hardcoded global state in packages (inject instead) =="
scan global WARN '\b(UserDefaults\.standard|FileManager\.default|Bundle\.main)\b' 1 Packages/Shared/CMUXMobileCore Packages/iOS/CmuxMobile* 2>/dev/null || true

echo "== free functions (scope functionality to a type) =="
scan free-function ERROR '^(@[A-Za-z()_ ]+ )?(public |internal |package |private |fileprivate )?func [a-zA-Z]' 0 "${SCOPES[@]}"

echo "== namespace-enums and namespace-types =="
NS_TYPE_ROOTS=()
for d in Packages/*/*/Sources ios/cmux; do
  [ -d "$d" ] && NS_TYPE_ROOTS+=("$d")
done
NAMESPACE_FILES=()
if [ -n "$FILES_FROM" ]; then
  NAMESPACE_FILES=(--files-from "$FILES_FROM")
fi
if ! python3 scripts/lint_swift_namespaces.py \
  --baseline scripts/lint-namespace-types-baseline.txt \
  --general-baseline "$BASELINE_FILE" \
  --ratchet scripts/lint-namespace-types-ratchet.txt \
  ${NAMESPACE_RATCHET_UPDATE:+--update-ratchet} \
  "${NAMESPACE_FIX[@]}" \
  "${NAMESPACE_FILES[@]}" \
  --enum-roots "${SCOPES[@]}" \
  --type-roots "${NS_TYPE_ROOTS[@]}"; then
  fail=1
fi

echo
if [ "$fail" = 1 ]; then
  echo "FAIL: convention violations found (ERROR lines above)."
  exit 1
fi
echo "OK: no unjustified convention violations."
