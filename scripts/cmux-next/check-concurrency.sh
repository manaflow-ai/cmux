#!/usr/bin/env bash
# Static check for the main-thread-blocking patterns banned by
# plans/cmux-next/architecture.md section 5a ("The main thread never waits").
#
# Scans Swift sources under Packages/macOS/CmuxNext/Sources. A hit is allowed
# only when the same line, or a comment line directly above it, carries a
# reviewed `// concurrency-allow: <reason>` comment with a non-empty reason.
#
# Rule sets:
#   everywhere: waits, sleeps, sync hops to main, raw locks, nested run-loop
#               spinning, synchronous XPC, blocking FileHandle reads,
#               unbounded AsyncStream buffers, and deadlines raced inside a
#               task group (the group waits for a loser that ignores
#               cancellation, so the deadline becomes a hang).
#   main-actor modules (the uiSwiftSettings targets, main-actor by default):
#               blocking descriptor IO and synchronous file reads, because
#               unannotated code there runs on the main thread.
#   idle wakeups (plans/cmux-next/idle-wakeups.md; everywhere except the
#               CmuxNextWakeups module, which holds the sanctioned primitives
#               FrameScheduler, DemandTimer, Backoff): timers of any kind,
#               raw display links, sleeps, and loops that can spin
#               (`while true`, `while !Task.isCancelled`, `repeat {`). Nothing
#               may poll. A reviewed exception carries
#               `// wakeup-allow: <reason>` on the line or the comment block
#               directly above.
#   service code (Daemon, Cloud, Mobile, Control, and the App's *Service /
#               *Store / Cloud files): a fire-and-forget `Task {` statement.
#               Store the handle and cancel it with its owner, or say who
#               owns it with `// task-owner: <reason>` (plans/cmux-next/state-audit.md).
#   model checks (Tests/**/*ModelCheckTests.swift): every suite is declared
#               `nonisolated`. An exhaustive exploration is seconds to minutes
#               of CPU; in a main-actor test target it runs on the main actor
#               and stalls every main-actor test in the `swift test` process
#               past its time limit (feat-cmux-next CI, 2026-10-02).
#   isolated deinit: the class must say `@MainActor` itself or inherit it from
#               an AppKit view, window or controller. Isolation inferred only
#               from `.defaultIsolation(MainActor.self)` is lost when another
#               module deserializes the class in a Release (whole-module) build
#               on Swift 6.2 (Xcode 26): "deinit is marked isolated, but
#               containing class ... is not isolated to an actor". Debug
#               builds and Xcode 27 accept it, so only the nightly fails.
#
# --mobile scans the cmux-next iOS tree instead (every root in
# scripts/cmux-next/mobile-scan-roots.txt, repo-root argument): the
# everywhere rules, task-group deadlines, isolated deinit and model checks.
# The idle-wakeup, service-code and main-actor-module rules are the Mac app's
# (idle-wakeups.md, state-audit.md and CmuxNext's module list) and do not
# apply. Hits that predate the scan are counted per file and rule in
# scripts/cmux-next/mobile-concurrency-baseline.json; a file may not gain one.
# --update-baseline (with --mobile) rewrites that file; counts only go down.
#
# Usage: scripts/cmux-next/check-concurrency.sh [package-root]
#        scripts/cmux-next/check-concurrency.sh --mobile [--update-baseline] [repo-root]
set -euo pipefail
mode=macos
update=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --mobile) mode=mobile ;;
    --update-baseline) update=1 ;;
    *) echo "check-concurrency: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ "$mode" == mobile ]]; then
  root="${1:-$(git rev-parse --show-toplevel)}"
else
  [[ "$update" == 0 ]] || { echo "check-concurrency: --update-baseline needs --mobile" >&2; exit 2; }
  root="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
fi
exec python3 - "$root" "$mode" "$update" <<'PY'
import collections
import json
import os
import re
import sys

root = sys.argv[1]
MOBILE = sys.argv[2] == "mobile"
UPDATE = sys.argv[3] == "1"
if MOBILE:
    entries = [line.strip() for line in open(os.path.join(root, "scripts/cmux-next/mobile-scan-roots.txt"), encoding="utf-8")]
    package_roots = [os.path.join(root, entry) for entry in entries if entry and not entry.startswith("#")]
    report_root = root
else:
    package_roots = [root]
    report_root = root
BASELINE_PATH = os.path.join(root, "scripts/cmux-next/mobile-concurrency-baseline.json")

# Targets built with `.defaultIsolation(MainActor.self)` (Package.swift uiSwiftSettings).
MAIN_ACTOR_MODULES = {
    "CmuxNextApp", "CmuxNextBridge", "CmuxNextDesign", "CmuxNextActions", "CmuxNextTerminal",
    "CmuxNextTabs", "CmuxNextSidebar", "CmuxNextPalette", "CmuxNextLayout", "CmuxNextBrowser", "CmuxNextUpdater",
    "CmuxNextOnboarding", "CmuxNextAgentPane",
}

EVERYWHERE = [
    ("DispatchQueue.main.sync", r"DispatchQueue\.main\.sync\b"),
    # A receiver is required (`.wait(x)` alone is an enum case); `await x.wait()`
    # is an async wait and is skipped below.
    ("blocking wait (semaphore/group/condition)", r"(?<=[\w)\]])\.wait\((timeout:|wallTimeout:|until:)?[^)]*\)"),
    ("DispatchSemaphore", r"\bDispatchSemaphore\("),
    ("DispatchGroup (wait-capable)", r"\bDispatchGroup\(\)"),
    ("Thread.sleep", r"\bThread\.sleep\b"),
    ("C sleep", r"(?<!await )(?<!func )(?<![.\w])(usleep|nanosleep|sleep)\("),
    ("Process.waitUntilExit", r"\bwaitUntilExit\("),
    ("NSLock (use Mutex; never hold a lock across IO or await)", r"\bNS(Recursive)?Lock\(|\bNSConditionLock\("),
    ("os_unfair_lock", r"\bos_unfair_lock"),
    ("pthread mutex/cond", r"\bpthread_(mutex|cond)_(lock|wait|timedwait)\("),
    ("asyncAfter (use an injected Clock)", r"\basyncAfter\("),
    ("nested run loop", r"\bCFRunLoopRunInMode\(|\bRunLoop\.(current|main)\.run\(|\.run\(mode:[^)]*before:"),
    ("synchronous XPC", r"synchronousRemoteObjectProxy"),
    ("blocking FileHandle read", r"readDataToEndOfFile\(|readData\(ofLength:|\.availableData\b|\breadToEnd\(\)"),
    ("infinite poll", r"\bpoll\([^)]*,\s*-1\s*\)"),
    # Both resolve every local name through DNS/mDNS and have blocked the
    # main thread for ~35 s. Use gethostname or SCDynamicStoreCopyComputerName.
    ("blocking host-name lookup (Host.current / ProcessInfo.hostName)", r"\bHost\.current\(\)|\bprocessInfo\.hostName\b"),
    # architecture.md 5a: no unbounded buffers. `makeStream()` without a
    # policy and the `AsyncStream { }` initializer default to unbounded.
    ("unbounded AsyncStream buffer (give it a cap and an overflow policy)",
     r"bufferingPolicy:\s*\.unbounded\b|\bmakeStream\((of:\s*[\w.<>\[\]: ]+\.self\s*)?\)"
     r"|\bAsync(Throwing)?Stream(<[^>]*>)?(\([^)]*\.self\))?\s*\{\s*(\[[^\]]*\]\s*)?\w+\s+in\b"),
]

# Idle wakeups: nothing polls; waits are events, one-shot DemandTimer
# deadlines, Backoff after a failure, or FrameClient frames.
WAKEUP_PRIMITIVES_MODULE = "CmuxNextWakeups"
WAKEUP_RULES = [
    ("timer (use DemandTimer for a one-shot deadline, FrameClient for animation frames)",
     r"\bTimer\.(scheduledTimer|publish)\b|\bTimer\((timeInterval|fire|fireAt)|\bNSTimer\b|\bCFRunLoopTimerCreate|\bmakeTimerSource\(|\brepeating:\s*\.(seconds|milliseconds|microseconds|nanoseconds|never)"),
    ("raw display link (use a FrameClient of the window's FrameScheduler)",
     r"\bdisplayLink\(target:|\bCADisplayLink\(|\bCVDisplayLink"),
    ("sleep (wait for an event; DemandTimer for a deadline, Backoff.wait after a failure)",
     r"\bTask\.sleep\(|\.sleep\((for|until):|\bclock\.sleep\b"),
    ("loop that can spin (block or await readiness; end on EOF and fatal errors)",
     r"\bwhile\s+true\b|\bwhile\s+!\s*(Task\.)?isCancelled\b|\brepeat\s*\{"),
]
WAKEUP_ALLOW = re.compile(r"//\s*wakeup-allow:\s*\S")
# Files another agent is rewriting right now, so they cannot take an inline
# comment without a conflict. Temporary: remove the entry when that work lands.
WAKEUP_PENDING_FILES: set[str] = set()

# A task group whose body sleeps within this many lines is a deadline race.
TASK_GROUP_WINDOW = 8
TASK_GROUP = re.compile(r"\bwith(Throwing)?(Discarding)?TaskGroup\b")
GROUP_SLEEP = re.compile(r"\bsleep\((for|until):")

SERVICE_MODULES = {"CmuxNextDaemon", "CmuxNextCloud", "CmuxNextMobile", "CmuxNextControl"}
SERVICE_APP_FILE = re.compile(r"^CmuxNextApp/(Cloud/.*|.*(Service|Store)(\+\w+)?\.swift)$")
# A `Task {` that starts a statement: its handle is discarded.
UNOWNED_TASK = re.compile(r"^\s*(if [^{]*\{\s*)?Task(\.detached)?(\s*\(priority:[^)]*\))?\s*\{")
TASK_OWNER = re.compile(r"//\s*(task-owner|concurrency-allow):\s*\S")

MAIN_ACTOR = [
    ("blocking descriptor IO on the main actor",
     r"(^|[^.\w]|Darwin\.)(read|write|recv|send|connect|accept|select)\(\s*(fd|descriptor|socket|masterFD|self\.fd|client)\w*\s*,"),
    ("poll on the main actor", r"(^|[^.\w])poll\(&"),
    ("synchronous file read on the main actor", r"\b(Data|String)\(contentsOf(File)?:"),
    ("synchronous GPU readback on the main actor (CoreImage/Metal wait)", r"\bcreateCGImage\(|\bwaitUntilCompleted\(|\bwaitUntilScheduled\("),
]

ISOLATED_DEINIT = re.compile(r"^\s*isolated\s+deinit\b")
CLASS_DECL = re.compile(r"^\s*(@\w+(\([^)]*\))?\s+)*((public|open|internal|package|fileprivate|private|final)\s+)*class\s+\w+")
# AppKit superclasses that are @MainActor in the SDK.
MAIN_ACTOR_SUPERCLASS = re.compile(r"class\s+\w+(<[^>]*>)?\s*:\s*(NS|UI)\w*(View|Window|Panel|Controller|Responder)\b")
ASYNC_WAIT = re.compile(r"\bawait\s+[\w.]+(\(\))?\.wait\(")
ATTRIBUTE_LINE = re.compile(r"^\s*@\w+")

def deinit_class_lacks_main_actor(lines, index):
    j = index - 1
    while j >= 0 and not CLASS_DECL.match(lines[j]):
        j -= 1
    if j < 0:
        return False
    if "@MainActor" in lines[j] or MAIN_ACTOR_SUPERCLASS.search(lines[j]):
        return False
    k = j - 1
    while k >= 0 and ATTRIBUTE_LINE.match(lines[k]):
        if "@MainActor" in lines[k]:
            return False
        k -= 1
    return True

ALLOW = re.compile(r"//\s*concurrency-allow:\s*\S")
COMMENT_ONLY = re.compile(r"^\s*(//|\*|/\*)")

def allowed(lines, index, escape=ALLOW):
    if escape.search(lines[index]):
        return True
    j = index - 1
    # A contiguous comment block directly above the hit may carry the escape.
    while j >= 0 and COMMENT_ONLY.match(lines[j]):
        if escape.search(lines[j]):
            return True
        j -= 1
    return False

rules_all = [(name, re.compile(rx)) for name, rx in EVERYWHERE]
rules_wakeup = [(name, re.compile(rx)) for name, rx in WAKEUP_RULES]
rules_main = [(name, re.compile(rx)) for name, rx in MAIN_ACTOR]

failures = 0
# (file relative to report_root, rule) -> [(line number, source line)]
found = collections.defaultdict(list)

def record(path, index, line, name):
    found[(os.path.relpath(path, report_root), name)].append((index + 1, line.strip()))

for package_root in package_roots:
  sources = os.path.join(package_root, "Sources")
  for dirpath, _, files in os.walk(sources):
    for filename in sorted(files):
        if not filename.endswith(".swift"):
            continue
        path = os.path.join(dirpath, filename)
        relative = os.path.relpath(path, sources)
        module = relative.split(os.sep)[0]
        rules = rules_all + (rules_main if not MOBILE and module in MAIN_ACTOR_MODULES else [])
        is_service = not MOBILE and (module in SERVICE_MODULES or SERVICE_APP_FILE.match(relative.replace(os.sep, "/")) is not None)
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        for index, line in enumerate(lines):
            if COMMENT_ONLY.match(line):
                continue
            code = line.split("//", 1)[0] if "//" in line and '"' not in line else line
            hits = [name for name, rx in rules if rx.search(code) and not allowed(lines, index)
                    and not (name.startswith("blocking wait") and ASYNC_WAIT.search(code))]
            if TASK_GROUP.search(code) and not allowed(lines, index):
                window = lines[index + 1:index + 1 + TASK_GROUP_WINDOW]
                if any(GROUP_SLEEP.search(other) for other in window):
                    hits.append("deadline raced in a task group (it waits for a loser that ignores cancellation; "
                                "race with a continuation, as ControlDeadline does)")
            if (not MOBILE and module != WAKEUP_PRIMITIVES_MODULE
                    and relative.replace(os.sep, "/") not in WAKEUP_PENDING_FILES
                    and not allowed(lines, index, WAKEUP_ALLOW)):
                hits += [name for name, rx in rules_wakeup if rx.search(code)]
            if is_service and UNOWNED_TASK.search(code) and not allowed(lines, index, TASK_OWNER):
                hits.append("unowned Task in service code (store and cancel the handle, or `// task-owner: <reason>`)")
            if ISOLATED_DEINIT.match(code) and deinit_class_lacks_main_actor(lines, index):
                hits.append("isolated deinit in a class without an explicit @MainActor (Release builds on "
                            "Xcode 26 reject it across modules; write @MainActor on the class)")
            for name in hits:
                record(path, index, line, name)

# Model checks run off the main actor (see the header).
SUITE_DECL = re.compile(r"^\s*(@\w+(\([^)]*\))?\s+)*((public|internal|package|fileprivate|private|final)\s+)*(struct|final class|class|enum)\s+\w+ModelCheckTests\b")
MODEL_CHECK = ("model check suite on the main actor (declare it `@Suite(.serialized) nonisolated struct`)")
for package_root in package_roots:
  tests = os.path.join(package_root, "Tests")
  for dirpath, _, files in os.walk(tests):
    for filename in sorted(files):
        if not filename.endswith("ModelCheckTests.swift"):
            continue
        path = os.path.join(dirpath, filename)
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        for index, line in enumerate(lines):
            if SUITE_DECL.match(line) and not re.search(r"\bnonisolated\b", line):
                record(path, index, line, MODEL_CHECK)

# The mobile scope's pre-existing hits, per file and rule; a file may not gain one.
baseline = {}
if MOBILE:
    if UPDATE:
        counts = collections.defaultdict(dict)
        for (relative, name), hits in sorted(found.items()):
            counts[relative][name] = len(hits)
        with open(BASELINE_PATH, "w", encoding="utf-8") as out:
            json.dump(counts, out, indent=1, sort_keys=True)
            out.write("\n")
        print(f"check-concurrency: baseline written ({sum(len(h) for h in found.values())} hits in {len(counts)} files)")
        sys.exit(0)
    if os.path.exists(BASELINE_PATH):
        with open(BASELINE_PATH, encoding="utf-8") as handle:
            baseline = json.load(handle)
shrunk = 0
for (relative, name), hits in sorted(found.items()):
    known = baseline.get(relative, {}).get(name, 0)
    if len(hits) < known:
        shrunk += 1
    if len(hits) <= known:
        continue
    for number, source in hits:
        print(f"concurrency: {relative}:{number}: {name}")
        print(f"    {source}")
    if known:
        print(f"    ({len(hits)} hits of this rule in the file, {known} in the baseline)")
    failures += len(hits) - known
for relative, rules in baseline.items():
    for name, known in rules.items():
        if len(found.get((relative, name), ())) < known:
            shrunk += 1

if failures:
    print(f"check-concurrency: {failures} violation(s). Fix the blocking call, or add a reviewed "
          "`// concurrency-allow: <reason>` when it provably never runs on the main thread. "
          "Idle-wakeup hits need an event-driven wait or a reviewed `// wakeup-allow: <reason>` "
          "(plans/cmux-next/idle-wakeups.md).")
    sys.exit(1)
note = (f"; {shrunk} baseline count(s) went down: run scripts/cmux-next/check-concurrency.sh --mobile --update-baseline"
        if MOBILE and shrunk else "")
print(f"check-concurrency: ok{note}")
PY
