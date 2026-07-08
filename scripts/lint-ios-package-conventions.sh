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

SCOPES=()
for d in Packages/Shared/CMUXMobileCore Packages/iOS/CmuxMobile* Packages/Shared/CmuxSyncStore ios/cmuxPackage/Sources ios/cmux; do
  [ -d "$d" ] && SCOPES+=("$d")
done

fail=0
report() { # rule, severity, file, line, text
  printf '%-7s %-28s %s:%s  %s\n' "$2" "$1" "$3" "$4" "$5"
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
    report "$rule" "$sev" "$f" "$n" "$(echo "$text" | sed 's/^[[:space:]]*//' | cut -c1-90)"
    [ "$sev" = ERROR ] && fail=1
  done < <(grep -rnE "$pat" "$@" --include='*.swift' 2>/dev/null)
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

echo "== namespace-enums (caseless enum with static members) =="
while IFS= read -r f; do
  case "$f" in */Tests/*|*Tests.swift|*/.build/*) continue ;; esac
  python3 - "$f" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
for m in re.finditer(r'(?:public\s+|package\s+)?enum\s+(\w+)[^{]*\{', src):
    name = m.group(1)
    i, depth = m.end(), 1
    while i < len(src) and depth:
        depth += src[i] == '{'
        depth -= src[i] == '}'
        i += 1
    body = src[m.end():i]
    # Only DECLARATION-level cases count: strip nested {...} bodies first so
    # switch-statement cases inside member funcs don't mask a caseless enum.
    top, depth = [], 0
    for ch in body:
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
        elif depth == 0:
            top.append(ch)
    top_level = ''.join(top)
    if not re.search(r'(^|\n)\s*(indirect\s+)?case\s', top_level) and 'static' in body:
        head = src[:m.start()]
        ctx = head[head.rfind('\n', 0, head.rfind('\n'))+1:]
        if 'lint:allow' in ctx:
            continue
        line = head.count('\n') + 1
        print(f'ERROR   namespace-enum               {path}:{line}  enum {name} (caseless, static members) -> scope onto the owning type')
PY
done < <(grep -rlE '\benum [A-Z]' "${SCOPES[@]}" --include='*.swift' 2>/dev/null) | tee /tmp/.lint-ns-enum-$$
grep -q ERROR /tmp/.lint-ns-enum-$$ 2>/dev/null && fail=1
rm -f /tmp/.lint-ns-enum-$$

echo "== namespace-types (static-only public types; instantiate or extend the receiver) =="
# Owner rule: types must never act as namespaces. Flagged: a public
# struct/class/actor whose entire public surface is static members and which
# cannot be meaningfully instantiated (private init, or no instance surface at
# all), and a caseless public enum of statics. Receiver-natural pure
# transforms belong in an extension on the receiver type; dependency-bearing
# logic belongs on an instantiated value with the dependency injected.
# Statics that are constants/factories OF a real value type are never flagged
# because such a type has instance surface. SwiftUI static-requirement key
# conformances (PreferenceKey/EnvironmentKey/...) are exempt automatically.
# Sanctioned exceptions (C/FFI trampoline holders, GhosttyRuntimeCInterop-style
# seams) carry a one-line justification on the decl line or up to 3 lines
# above, e.g. "lint:allow namespace-type — <why>". Unlike the per-line rules
# above, this rule scans every package in the repo, not just the iOS line.
# Pre-existing offenders in packages owned by other refactor sessions are
# grandfathered in scripts/lint-namespace-types-baseline.txt; that list may
# only shrink.
NS_TYPE_ROOTS=()
for d in Packages/*/*/Sources ios/cmuxPackage/Sources ios/cmux; do
  [ -d "$d" ] && NS_TYPE_ROOTS+=("$d")
done
if ! python3 - scripts/lint-namespace-types-baseline.txt "${NS_TYPE_ROOTS[@]}" <<'PY'
import os
import re
import sys

baseline_path = sys.argv[1]
roots = sys.argv[2:]

baseline = set()
if os.path.exists(baseline_path):
    for raw in open(baseline_path, encoding="utf-8"):
        entry = raw.strip()
        if entry and not entry.startswith("#"):
            baseline.add(entry)

DECL = re.compile(
    r"(?m)^(?P<indent>[ \t]*)(?P<head>(?:@\w+(?:\([^)]*\))?[ \t]+)*"
    r"(?:(?:public|package|internal|open|final|private|fileprivate)[ \t]+)*"
    r"(?P<kind>struct|class|enum|actor)[ \t]+(?P<name>\w+))"
)
EXT = re.compile(r"(?m)^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]+)*"
                 r"(?:(?:public|package|internal|private|fileprivate)[ \t]+)?"
                 r"extension[ \t]+(?P<name>[\w.]+)")
MEMBER = re.compile(
    r"\b(case|init|func|var|let|subscript|struct|class|enum|actor|typealias)\b"
)
MARKER = re.compile(r"lint:allow|TRANSITIONAL|carve-out|justification|sanctioned", re.I)
# Protocols whose requirements are static by design; conformers are
# intentionally never instantiated.
STATIC_KEY_PROTOCOLS = re.compile(
    r"\b(PreferenceKey|EnvironmentKey|FocusedValueKey|LayoutValueKey|"
    r"TransactionKey|ContainerValueKey|EntryKey)\b"
)


def body_and_end(src, brace):
    depth, i = 1, brace + 1
    while i < len(src) and depth:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    return src[brace + 1:i - 1]


def depth_prefix(s):
    d, out = 0, []
    for ch in s:
        out.append(d)
        d += (ch == "{") - (ch == "}")
    return out


def tally(body, counts):
    dp = depth_prefix(body)
    for mm in MEMBER.finditer(body):
        if dp[mm.start()] != 0:
            continue
        kw = mm.group(0)
        line_start = body.rfind("\n", 0, mm.start()) + 1
        prefix = body[line_start:mm.start()]
        if "//" in prefix:
            continue
        if kw in ("struct", "enum", "actor", "typealias"):
            continue
        if kw == "class":
            continue  # nested class decl; `class func/var` is seen by func/var
        if kw == "case":
            counts["cases"] += 1
        elif kw == "init":
            if re.search(r"\b(private|fileprivate)\b", prefix):
                counts["private_inits"] += 1
            else:
                counts["open_inits"] += 1
        elif re.search(r"\b(static|class)\b", prefix):
            counts["statics"] += 1
        else:
            counts["instances"] += 1


fail = False
for root in roots:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".build", "Tests")]
        for fn in sorted(filenames):
            if not fn.endswith(".swift") or fn.endswith("Tests.swift"):
                continue
            path = os.path.join(dirpath, fn)
            src = open(path, encoding="utf-8", errors="replace").read()
            lines = src.split("\n")

            ext_counts = {}
            for em in EXT.finditer(src):
                brace = src.find("{", em.end())
                if brace < 0:
                    continue
                name = em.group("name").split(".")[-1]
                counts = ext_counts.setdefault(
                    name,
                    {"cases": 0, "private_inits": 0, "open_inits": 0,
                     "statics": 0, "instances": 0},
                )
                tally(body_and_end(src, brace), counts)

            for m in DECL.finditer(src):
                head = m.group("head")
                if "public" not in head and "package" not in head:
                    continue
                brace = src.find("{", m.end())
                if brace < 0:
                    continue
                conformances = src[m.end():brace]
                if STATIC_KEY_PROTOCOLS.search(conformances):
                    continue
                counts = {"cases": 0, "private_inits": 0, "open_inits": 0,
                          "statics": 0, "instances": 0}
                tally(body_and_end(src, brace), counts)
                ext = ext_counts.get(m.group("name"))
                if ext:
                    for key in counts:
                        counts[key] += ext[key]
                if counts["statics"] == 0 or counts["instances"] > 0:
                    continue
                if m.group("kind") == "enum":
                    if counts["cases"] > 0:
                        continue
                else:
                    if counts["open_inits"] > 0:
                        continue
                line = src.count("\n", 0, m.start()) + 1
                ctx = "\n".join(lines[max(0, line - 4):line])
                if MARKER.search(ctx):
                    continue
                if f"{path}:{m.group('name')}" in baseline:
                    continue
                print(
                    f"ERROR   namespace-type               {path}:{line}  "
                    f"{m.group('kind')} {m.group('name')} (all-static public "
                    "surface, not instantiable) -> extension on the receiver "
                    "type or an instantiated value with injected dependencies"
                )
                fail = True

sys.exit(1 if fail else 0)
PY
then
  fail=1
fi

echo
if [ "$fail" = 1 ]; then
  echo "FAIL: convention violations found (ERROR lines above)."
  exit 1
fi
echo "OK: no unjustified convention violations."
