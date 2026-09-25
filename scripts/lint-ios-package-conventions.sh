#!/usr/bin/env bash
# lint-ios-package-conventions.sh
#
# Mechanical enforcement of the modular-refactor conventions (CLAUDE.md
# "Modern Swift concurrency" + "Package design discipline") over the iOS
# line: the mobile packages, the cmuxFeature package, and the iOS app shell.
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BASELINE_FILE="scripts/lint-ios-package-conventions-baseline.txt"
SCOPES=()
for d in Packages/Shared/CMUXMobileCore Packages/iOS/CmuxMobile* Packages/Shared/CmuxAgentChat Packages/iOS/CmuxAgentChatUI Packages/Shared/CmuxSyncStore ios/cmuxPackage/Sources ios/cmux; do
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
  done < <(grep -rnE "$pat" "$@" --include='*.swift' --exclude-dir=.build 2>/dev/null)
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
for d in Packages/*/*/Sources ios/cmuxPackage/Sources ios/cmux; do
  [ -d "$d" ] && NS_TYPE_ROOTS+=("$d")
done
if ! python3 scripts/lint_swift_namespaces.py \
  --baseline scripts/lint-namespace-types-baseline.txt \
  --general-baseline "$BASELINE_FILE" \
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
