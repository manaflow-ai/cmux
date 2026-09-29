#!/usr/bin/env bash
# Static check for the main-thread-blocking patterns banned by
# plans/cmux-next/architecture.md section 5a ("The main thread never waits").
#
# Scans Swift sources under Packages/macOS/CmuxNext/Sources. A hit is allowed
# only when the same line, or a comment line directly above it, carries a
# reviewed `// concurrency-allow: <reason>` comment with a non-empty reason.
#
# Two rule sets:
#   everywhere: waits, sleeps, sync hops to main, raw locks, nested run-loop
#               spinning, synchronous XPC, blocking FileHandle reads.
#   main-actor modules (the uiSwiftSettings targets, main-actor by default):
#               blocking descriptor IO and synchronous file reads, because
#               unannotated code there runs on the main thread.
#
# Usage: scripts/cmux-next/check-concurrency.sh [package-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
exec python3 - "$root" <<'PY'
import os
import re
import sys

root = sys.argv[1]
sources = os.path.join(root, "Sources")

# Targets built with `.defaultIsolation(MainActor.self)` (Package.swift uiSwiftSettings).
MAIN_ACTOR_MODULES = {
    "CmuxNextApp", "CmuxNextBridge", "CmuxNextDesign", "CmuxNextActions", "CmuxNextTerminal",
    "CmuxNextTabs", "CmuxNextSidebar", "CmuxNextPalette", "CmuxNextLayout", "CmuxNextBrowser",
}

EVERYWHERE = [
    ("DispatchQueue.main.sync", r"DispatchQueue\.main\.sync\b"),
    ("blocking wait (semaphore/group/condition)", r"\.wait\((timeout:|wallTimeout:|until:)?[^)]*\)"),
    ("DispatchSemaphore", r"\bDispatchSemaphore\("),
    ("DispatchGroup (wait-capable)", r"\bDispatchGroup\(\)"),
    ("Thread.sleep", r"\bThread\.sleep\b"),
    ("C sleep", r"(?<!await )(?<![.\w])(usleep|nanosleep|sleep)\("),
    ("Process.waitUntilExit", r"\bwaitUntilExit\("),
    ("NSLock (use Mutex; never hold a lock across IO or await)", r"\bNS(Recursive)?Lock\(|\bNSConditionLock\("),
    ("os_unfair_lock", r"\bos_unfair_lock"),
    ("pthread mutex/cond", r"\bpthread_(mutex|cond)_(lock|wait|timedwait)\("),
    ("asyncAfter (use an injected Clock)", r"\basyncAfter\("),
    ("nested run loop", r"\bCFRunLoopRunInMode\(|\bRunLoop\.(current|main)\.run\(|\.run\(mode:[^)]*before:"),
    ("synchronous XPC", r"synchronousRemoteObjectProxy"),
    ("blocking FileHandle read", r"readDataToEndOfFile\(|readData\(ofLength:|\.availableData\b|\breadToEnd\(\)"),
    ("infinite poll", r"\bpoll\([^)]*,\s*-1\s*\)"),
]

MAIN_ACTOR = [
    ("blocking descriptor IO on the main actor",
     r"(^|[^.\w]|Darwin\.)(read|write|recv|send|connect|accept|select)\(\s*(fd|descriptor|socket|masterFD|self\.fd|client)\w*\s*,"),
    ("poll on the main actor", r"(^|[^.\w])poll\(&"),
    ("synchronous file read on the main actor", r"\b(Data|String)\(contentsOf(File)?:"),
]

ALLOW = re.compile(r"//\s*concurrency-allow:\s*\S")
COMMENT_ONLY = re.compile(r"^\s*(//|\*|/\*)")

def allowed(lines, index):
    if ALLOW.search(lines[index]):
        return True
    j = index - 1
    # A contiguous comment block directly above the hit may carry the escape.
    while j >= 0 and COMMENT_ONLY.match(lines[j]):
        if ALLOW.search(lines[j]):
            return True
        j -= 1
    return False

rules_all = [(name, re.compile(rx)) for name, rx in EVERYWHERE]
rules_main = [(name, re.compile(rx)) for name, rx in MAIN_ACTOR]

failures = 0
for dirpath, _, files in os.walk(sources):
    for filename in sorted(files):
        if not filename.endswith(".swift"):
            continue
        path = os.path.join(dirpath, filename)
        module = os.path.relpath(path, sources).split(os.sep)[0]
        rules = rules_all + (rules_main if module in MAIN_ACTOR_MODULES else [])
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        for index, line in enumerate(lines):
            if COMMENT_ONLY.match(line):
                continue
            code = line.split("//", 1)[0] if "//" in line and '"' not in line else line
            for name, rx in rules:
                if rx.search(code) and not allowed(lines, index):
                    print(f"concurrency: {os.path.relpath(path, root)}:{index + 1}: {name}")
                    print(f"    {line.strip()}")
                    failures += 1

if failures:
    print(f"check-concurrency: {failures} violation(s). Fix the blocking call, or add a reviewed "
          "`// concurrency-allow: <reason>` when it provably never runs on the main thread.")
    sys.exit(1)
print("check-concurrency: ok")
PY
