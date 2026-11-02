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
#               spinning, synchronous XPC, blocking FileHandle reads, dlopen
#               (dyld's loader lock), whole-file code signature validation,
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
#   Synchronization: `import Synchronization` needs macOS 15; CmuxNext runs
#               on macOS 14 and uses CmuxNextCompat's Mutex/Atomic.
#               CHECK_CONCURRENCY_ONLY=synchronization runs only this rule
#               (safe-push blocks on it).
#   isolated deinit: never (cx-t7hu), nor a plain deinit in main-actor
#               scope of a uiSwiftSettings target, which is isolated by default
#               there. Its runtime hop
#               (swift_task_deinitOnExecutor) traps when the object is released
#               inline inside an action's task-local scope under CEF. Write
#               `nonisolated deinit`, with main-actor cleanup in
#               `guard Thread.isMainThread else { return }` plus
#               `MainActor.assumeIsolated { ... }`.
#   generic main-actor class: a class in main-actor code that is generic by
#               its own parameters or by context (nested in a generic type, in
#               an extension of one in any file, in a generic function or under
#               a `where` clause) declares `nonisolated deinit`. Without one its
#               deinit is isolated, and the Release compile's optimizer crashes
#               on it (EarlyPerfInliner, swift-frontend 6.3, macOS 14 target:
#               #23050's FirstMouseHostingView, fixed in #23233; #20408's
#               ThemedPicker.Coordinator; 6bf522e6cdd's ObservedMap.Slot).
#               scripts/cmux-next/swift_scope.py is the one detector; the
#               pre-push guardrails.py applies the same one to what a push adds.
#               A class generic only through an extension names the
#               declaration that makes it so (`generic context: <file>:<line>`):
#               crash-class-gate.sh --pr counts a PR that changes that file.
#   workspace opens: `NSWorkspace.shared.open(url)` and the Finder reveal
#               calls block the main thread in LaunchServices (cx-050n); only
#               CmuxNextCompat/NSWorkspace+Background.swift makes them.
#   pipe reads: `availableData` inside a `readabilityHandler` closure. A
#               failed read(2) (EBADF, EIO) raises an Objective-C exception
#               Swift cannot catch, which aborts the app (cmuxterm-hq#4753);
#               use CmuxNextCompat's `handle.readReady()`. A reviewed
#               exception carries `// pipe-read-allow: <reason>`.
#   CHECK_CONCURRENCY_ONLY=crash-class runs only the isolated-deinit,
#               generic-class deinit, task-local, workspace-open and pipe-read
#               rules; CI blocks on it.
#   task-local bindings: only `$local.withValueInTask` (CmuxNextActions/
#               TaskLocal+InTask.swift) calls `.withValue(`. Bound where no task
#               is current, a task local lives in the thread's fallback storage,
#               and an isolated deinit run inline there makes the Swift 6.2
#               runtime free() a marker its global task allocator made (cx-bpcj).
#
# Usage: scripts/cmux-next/check-concurrency.sh [package-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$root" "$scripts_dir/check-main-actor-work.py" "$scripts_dir/swift_scope.py" <<'PY'
import importlib.util
import os
import re
import sys

root = sys.argv[1]
# Lexical isolation scopes (nonisolated, @concurrent, actor, Task.detached,
# @MainActor) come from check-main-actor-work.py, so both checks agree on
# which lines are main-actor code.
_spec = importlib.util.spec_from_file_location("main_actor_scope", sys.argv[2])
main_actor_scope = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(main_actor_scope)
# The generic-class deinit detector guardrails.py shares (one crash class, one detector).
_spec = importlib.util.spec_from_file_location("cmux_next_swift_scope", sys.argv[3])
swift_scope = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = swift_scope
_spec.loader.exec_module(swift_scope)
sources = os.path.join(root, "Sources")

# Targets built with `.defaultIsolation(MainActor.self)`: every target whose
# swiftSettings are `uiSwiftSettings` in Package.swift. Read from the manifest
# (swift_scope.package_targets, each target call alone, its `path:` honored),
# so a new UI target is scanned without an edit here (a hand list missed 21).
def package_targets(package_root):
    with open(os.path.join(package_root, "Package.swift"), encoding="utf-8") as handle:
        targets = swift_scope.package_targets(handle.read())
    if not any(target.main for target in targets):
        sys.exit("check-concurrency: no uiSwiftSettings targets found in Package.swift")
    return targets

TARGETS = package_targets(root)

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
    # Both resolve every local name through DNS/mDNS and have blocked the
    # main thread for ~35 s. Use gethostname or SCDynamicStoreCopyComputerName.
    ("blocking host-name lookup (Host.current / ProcessInfo.hostName)", r"\bHost\.current\(\)|\bprocessInfo\.hostName\b"),
    # dlopen holds dyld's loader lock while it maps, validates and fixes up the image; every
    # main-thread dlopen, dladdr and image lookup waits for that lock, on any thread's load.
    # The CEF framework's off-main load held it ~2 s on a cold cache and hung the main thread
    # (Sentry MainThreadHang in dyld4::APIs::dlopen_from). Read the file into the cache first,
    # and say why the load is short.
    ("dlopen (holds dyld's loader lock: main-thread dlopen/dladdr wait on it from any thread)", r"(?:^|[^.\w]|Darwin\.)dlopen\s*\("),
    # Static code validation hashes the whole file (72 MB acpmux, the 367 MiB CEF framework):
    # seconds on a cold file cache. Never on the main thread; cache the verdict by file identity.
    ("SecStaticCodeCheckValidity (hashes the whole file; never on the main thread)",
     r"\bSecStaticCodeCheckValidity(WithErrors)?\s*\("),
    # architecture.md 5a: no unbounded buffers. `makeStream()` without a
    # policy and the `AsyncStream { }` initializer default to unbounded.
    ("unbounded AsyncStream buffer (give it a cap and an overflow policy)",
     r"bufferingPolicy:\s*\.unbounded\b|\bmakeStream\((of:\s*[\w.<>\[\]: ]+\.self\s*)?\)"
     r"|\bAsync(Throwing)?Stream(<[^>]*>)?(\([^)]*\.self\))?\s*\{\s*(\[[^\]]*\]\s*)?\w+\s+in\b"),
]

# Every call that suspends for a duration: Task.sleep, a clock's or sleeper's
# `.sleep(for:/until:)`, and an awaited injected sleeper (`try await sleep(delay)`,
# `await self.sleep(d)`: the `Sleep` closure CLAUDE.md prescribes for tests).
# One definition for the idle-wakeup rule and the task-group deadline rule;
# scripts/cmux-next/guardrails.py has no sleep rule of its own.
SLEEP_CALL = (r"\bTask\.sleep\(|\.sleep\((for|until):|\bclock\.sleep\b"
              r"|\bawait\s+(?:[A-Za-z_]\w*\??\.)*sleep\(")

# Idle wakeups: nothing polls; waits are events, one-shot DemandTimer
# deadlines, Backoff after a failure, or FrameClient frames.
WAKEUP_PRIMITIVES_MODULE = "CmuxNextWakeups"
WAKEUP_RULES = [
    ("timer (use DemandTimer for a one-shot deadline, FrameClient for animation frames)",
     r"\bTimer\.(scheduledTimer|publish)\b|\bTimer\((timeInterval|fire|fireAt)|\bNSTimer\b|\bCFRunLoopTimerCreate|\bmakeTimerSource\(|\brepeating:\s*\.(seconds|milliseconds|microseconds|nanoseconds|never)"),
    ("raw display link (use a FrameClient of the window's FrameScheduler)",
     r"\bdisplayLink\(target:|\bCADisplayLink\(|\bCVDisplayLink"),
    ("sleep (wait for an event; DemandTimer for a deadline, Backoff.wait after a failure)", SLEEP_CALL),
    ("loop that can spin (block or await readiness; end on EOF and fatal errors)",
     r"\bwhile\s+true\b|\bwhile\s+!\s*(Task\.)?isCancelled\b|\brepeat\s*\{"),
]
WAKEUP_ALLOW = re.compile(r"//\s*wakeup-allow:\s*\S")
# Files another agent is rewriting right now, so they cannot take an inline
# comment without a conflict. Temporary: remove the entry when that work lands.
WAKEUP_PENDING_FILES: set[str] = set()
# KNOWN main-thread signature checks, moved off main by #22814 (a high-risk-tier PR
# that waits for a person: acpmux trust and the updater). Only the rule for
# SecStaticCodeCheckValidity is waived here; #22814 removes these entries.
SIGNATURE_PENDING_FILES: set[str] = {
    "CmuxNextAgentPane/AcpmuxServerPeer.swift",
    "CmuxNextUpdater/UpdateDropBack.swift",
}
SIGNATURE_RULE = "SecStaticCodeCheckValidity (hashes the whole file; never on the main thread)"

# A task group whose body sleeps within this many lines is a deadline race.
TASK_GROUP_WINDOW = 8
TASK_GROUP = re.compile(r"\bwith(Throwing)?(Discarding)?TaskGroup\b")
GROUP_SLEEP = re.compile(SLEEP_CALL)

# macOS 14 floor (plans/cmux-next/macos-floor.md): Synchronization (Mutex,
# Atomic) needs macOS 15; CmuxNextCompat has the same API on macOS 14.
SYNCHRONIZATION_IMPORT = re.compile(r"^\s*(@\w+\s+)*((public|internal|package|private|fileprivate)\s+)?import\s+Synchronization\b")
SYNCHRONIZATION_RULE = "import Synchronization: use CmuxNextCompat (macOS 14 floor)"
# Files under a WINDOW FREEZE held by another lane that still import it.
# Temporary: the owner switches them to CmuxNextCompat, then drops the entry.
SYNCHRONIZATION_PENDING_FILES: set[str] = set()
# `--only synchronization` (safe-push's blocking check) runs only this rule.
ONLY = os.environ.get("CHECK_CONCURRENCY_ONLY", "")

# CmuxNextCompat implements the sanctioned Mutex (the Synchronization.Mutex API
# on macOS 14, plans/cmux-next/macos-floor.md) over os_unfair_lock; everyone
# else uses that Mutex instead of a raw lock.
LOCK_PRIMITIVES_MODULES = {"CmuxNextCompat"}

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
# A plain deinit takes the target's default isolation: main-actor in a uiSwiftSettings target.
PLAIN_DEINIT = re.compile(r"^\s*deinit\b")
TASK_LOCAL_BINDING = re.compile(r"\.withValue\s*\(")
TASK_LOCAL_HELPER = "CmuxNextActions/TaskLocal+InTask.swift"
# NSWorkspace.shared.open(x) with one argument, and the Finder reveal calls.
WORKSPACE_SYNC = re.compile(r"NSWorkspace\.shared\.(open\((?:[^,()]|\([^()]*\))*\)|activateFileViewerSelecting\(|selectFile\(|openFile\(|launchApplication\()")
WORKSPACE_HELPER = "CmuxNextCompat/NSWorkspace+Background.swift"
ALLOW = re.compile(r"//\s*concurrency-allow:\s*\S")
COMMENT_ONLY = re.compile(r"^\s*(//|\*|/\*)")
# A readability handler's closure literal, and `availableData` read inside one (cmuxterm-hq#4753).
READABILITY_HANDLER = re.compile(r"\breadabilityHandler\s*=\s*\{")
# `readabilityHandler =` at the end of a line: the closure's `{` opens the next code line.
READABILITY_HANDLER_PENDING = re.compile(r"\breadabilityHandler\s*=\s*$")
AVAILABLE_DATA = re.compile(r"\bavailableData\b")
PIPE_READ_ALLOW = re.compile(r"//\s*pipe-read-allow:\s*\S")


def swift_code_mask(text):
    """`text` with comment and string-literal characters turned to spaces (newlines kept), so only
    code is left: `//` and nested `/* */` comments, "..." and multiline literals, raw `#"..."#`
    literals, and an interpolation `\\(...)` inside a literal stays code."""
    out = list(text)
    n = len(text)
    i = 0
    # The open contexts, innermost last: ("block", depth), ("string", quotes, hashes) or
    # ("interp", paren depth) for an interpolation, which is code inside a string.
    stack = []

    def blank(a, b):
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        top = stack[-1] if stack else None
        if top is None or top[0] == "interp":
            if text.startswith("//", i):
                j = text.find("\n", i)
                j = n if j < 0 else j
                blank(i, j)
                i = j
            elif text.startswith("/*", i):
                stack.append(["block", 1])
                blank(i, i + 2)
                i += 2
            elif text[i] == '"' or (text[i] == "#" and re.match(r'#+"', text[i:])):
                hashes = len(re.match(r"#*", text[i:]).group(0))
                quotes = 3 if text.startswith('"""', i + hashes) else 1
                stack.append(["string", quotes, hashes])
                blank(i, i + hashes + quotes)
                i += hashes + quotes
            else:
                if top is not None:
                    if text[i] == "(":
                        top[1] += 1
                    elif text[i] == ")":
                        top[1] -= 1
                        if top[1] == 0:
                            stack.pop()
                            blank(i, i + 1)
                i += 1
        elif top[0] == "block":
            if text.startswith("/*", i):
                top[1] += 1
                blank(i, i + 2)
                i += 2
            elif text.startswith("*/", i):
                top[1] -= 1
                blank(i, i + 2)
                i += 2
                if top[1] == 0:
                    stack.pop()
            else:
                blank(i, i + 1)
                i += 1
        else:
            _, quotes, hashes = top
            escape = "\\" + "#" * hashes
            close = '"' * quotes + "#" * hashes
            if text.startswith(escape + "(", i):
                stack.append(["interp", 1])
                blank(i, i + len(escape) + 1)
                i += len(escape) + 1
            elif text.startswith(escape, i):
                blank(i, i + len(escape) + 1)
                i += len(escape) + 1
            elif text.startswith(close, i):
                stack.pop()
                blank(i, i + len(close))
                i += len(close)
            elif quotes == 1 and text[i] == "\n":
                stack.pop()  # an unterminated literal ends at the line
                i += 1
            else:
                blank(i, i + 1)
                i += 1
    return "".join(out)


def readability_handler_code(lines):
    """For each line inside a `readabilityHandler = { ... }` closure (the line that opens one counts),
    its code with comments and string literals blanked (swift_code_mask), so a match is code, not
    text; None for a line outside one. The closure's extent is found by brace depth over that code."""
    inside = [None] * len(lines)
    text = "\n".join(lines)
    if "readabilityHandler" not in text:
        return inside  # most files: skip the character scan
    masked = swift_code_mask(text).split("\n")
    depth = 0
    open_handlers = []  # the depth of each enclosing handler's opening brace
    pending = False  # the previous code line ended `readabilityHandler =`
    for index, code in enumerate(masked):
        opening = {match.end() - 1 for match in READABILITY_HANDLER.finditer(code)}
        stripped = code.lstrip()
        if pending and stripped:
            if stripped.startswith("{"):
                opening.add(len(code) - len(stripped))
            pending = False
        if READABILITY_HANDLER_PENDING.search(code):
            pending = True
        was_inside = bool(open_handlers)
        for column, char in enumerate(code):
            if char == "{":
                depth += 1
                if column in opening:
                    open_handlers.append(depth)
                    was_inside = True
            elif char == "}":
                if open_handlers and open_handlers[-1] == depth:
                    open_handlers.pop()
                depth -= 1
        if was_inside:
            inside[index] = code
    return inside

def crash_class_hits(code, lines, index, default_main, main_lines, relative, generic_declared, handler_code):
    """The crash-class rules (CHECK_CONCURRENCY_ONLY=crash-class; CI blocks on them)."""
    hits = []
    if ISOLATED_DEINIT.match(code):
        hits.append("isolated deinit (its hop traps inside an action's task-local scope, cx-t7hu; "
                    "write nonisolated deinit with MainActor.assumeIsolated on the main thread)")
    if PLAIN_DEINIT.match(code) and default_main and main_lines[index]:
        hits.append("deinit of a main-actor class in a main-actor-default target is isolated (its hop traps "
                    "inside an action's task-local scope, cx-t7hu); write nonisolated deinit")
    judged = (swift_scope.judge(lines, index, generic_declared.__contains__, main_lines, default_main)
              if "class" in code else None)
    if judged is not None and not swift_scope.escaped(lines, index, swift_scope.GENERIC_CLASS_ALLOW):
        # A class generic only by an extension of a type declared generic in another file names that
        # declaration: a change there makes it a candidate, so crash-class-gate.sh --pr counts that file too.
        context = "; ".join(f"generic context: {site}" for name in judged.extended for site in generic_declared[name])
        hits.append("generic main-actor class with no `nonisolated deinit` (generic by itself or by context; its "
                    "isolated deinit crashes the Release compile's optimizer, #23050 / #23233); declare "
                    "`nonisolated deinit {}`" + (f" ({context})" if context else ""))
    if TASK_LOCAL_BINDING.search(code) and relative != TASK_LOCAL_HELPER and not allowed(lines, index):
        hits.append("task local bound with withValue (where no task is current the runtime frees a marker "
                    "with free() that its task allocator made, cx-bpcj); use $local.withValueInTask")
    if WORKSPACE_SYNC.search(code) and relative != WORKSPACE_HELPER and not allowed(lines, index):
        hits.append("synchronous NSWorkspace open or reveal (LaunchServices and Finder calls block the main "
                    "thread until the watchdog fires, cx-050n); use openInBackground / revealInBackground")
    if handler_code[index] is not None and AVAILABLE_DATA.search(handler_code[index]) \
            and not allowed(lines, index, PIPE_READ_ALLOW):
        hits.append("availableData in a readabilityHandler (a failed read raises an Objective-C exception Swift "
                    "cannot catch, which aborts the app, cmuxterm-hq#4753); switch on handle.readReady(): "
                    ".bytes, .retry (return), .end (clear the handler)")
    return hits


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
texts = {}
for dirpath, _, files in os.walk(sources):
    for filename in sorted(files):
        if filename.endswith(".swift"):
            path = os.path.join(dirpath, filename)
            with open(path, encoding="utf-8") as handle:
                texts[path] = handle.read()
# The generic-class rule reads an extension's context: is its type declared generic anywhere in Sources,
# and where ({type name: ["Sources/<path>:<line>", ...]}).
generic_declared = {}
for path, text in sorted(texts.items()):
    for name, numbers in swift_scope.generic_declarations(text).items():
        site = os.path.relpath(path, root).replace(os.sep, "/")
        generic_declared.setdefault(name, []).extend(f"{site}:{number}" for number in numbers)
for dirpath, _, files in os.walk(sources):
    for filename in sorted(files):
        if not filename.endswith(".swift"):
            continue
        path = os.path.join(dirpath, filename)
        relative = os.path.relpath(path, sources)
        module = relative.split(os.sep)[0]
        is_service = module in SERVICE_MODULES or SERVICE_APP_FILE.match(relative.replace(os.sep, "/")) is not None
        lines = texts[path].split("\n")
        # Main-actor rules apply to main-actor code: the target default for a
        # uiSwiftSettings target, `@MainActor` scopes anywhere, minus
        # nonisolated / @concurrent / actor / detached scopes.
        default_main = swift_scope.default_isolation(
            os.path.relpath(path, root).replace(os.sep, "/"), TARGETS) is True
        main_lines = main_actor_scope.main_actor_lines(lines, default_main)
        handler_code = readability_handler_code(lines)
        for index, line in enumerate(lines):
            if COMMENT_ONLY.match(line):
                continue
            code = line.split("//", 1)[0] if "//" in line and '"' not in line else line
            rules = rules_all + (rules_main if main_lines[index] else [])
            if (ONLY != "crash-class" and SYNCHRONIZATION_IMPORT.match(code) and module not in LOCK_PRIMITIVES_MODULES
                    and relative.replace(os.sep, "/") not in SYNCHRONIZATION_PENDING_FILES):
                print(f"concurrency: {os.path.relpath(path, root)}:{index + 1}: {SYNCHRONIZATION_RULE}")
                print(f"    {line.strip()}")
                failures += 1
            if ONLY == "synchronization":
                continue
            hits = crash_class_hits(code, lines, index, default_main, main_lines, relative.replace(os.sep, "/"),
                                    generic_declared, handler_code)
            if ONLY == "crash-class":
                for name in hits:
                    print(f"concurrency: {os.path.relpath(path, root)}:{index + 1}: {name}")
                    print(f"    {line.strip()}")
                    failures += 1
                continue
            hits += [name for name, rx in rules if rx.search(code) and not allowed(lines, index)
                     and not (module in LOCK_PRIMITIVES_MODULES and name == "os_unfair_lock")
                     and not (name == SIGNATURE_RULE and relative.replace(os.sep, "/") in SIGNATURE_PENDING_FILES)]
            if TASK_GROUP.search(code) and not allowed(lines, index):
                window = lines[index + 1:index + 1 + TASK_GROUP_WINDOW]
                if any(GROUP_SLEEP.search(other) for other in window):
                    hits.append("deadline raced in a task group (it waits for a loser that ignores cancellation; "
                                "race with a continuation, as ControlDeadline does)")
            if (module != WAKEUP_PRIMITIVES_MODULE and relative.replace(os.sep, "/") not in WAKEUP_PENDING_FILES
                    and not allowed(lines, index, WAKEUP_ALLOW)):
                hits += [name for name, rx in rules_wakeup if rx.search(code)]
            if is_service and UNOWNED_TASK.search(code) and not allowed(lines, index, TASK_OWNER):
                hits.append("unowned Task in service code (store and cancel the handle, or `// task-owner: <reason>`)")
            for name in hits:
                print(f"concurrency: {os.path.relpath(path, root)}:{index + 1}: {name}")
                print(f"    {line.strip()}")
                failures += 1

# Shared packages linked into the app run on the same main thread from AppKit callbacks
# (Home's vendored MessagesLab draws there with no task): a task local bound there sits in the
# thread's fallback storage, the cx-bpcj / cx-t7hu trap (CMUXTERM-MACOS-44XN, macOS 15.8.1, Cmd-1
# leaving Home). A binding there needs a reviewed `// concurrency-allow:` saying why it runs inside
# a task or off the main thread.
ASYNC_BINDING = re.compile(r"\bawait\b.*\.withValue\s*\(")
shared_root = os.path.normpath(os.path.join(root, "..", "..", "Shared"))
for dirpath, _, files in (os.walk(shared_root) if ONLY != "synchronization" and os.path.isdir(shared_root) else []):
    if os.sep + "Sources" + os.sep not in dirpath + os.sep:
        continue
    for filename in sorted(files):
        if not filename.endswith(".swift"):
            continue
        path = os.path.join(dirpath, filename)
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        for index, line in enumerate(lines):
            # `await $local.withValue(...)` is the async overload: it always binds inside a task.
            if (COMMENT_ONLY.match(line) or not TASK_LOCAL_BINDING.search(line) or ASYNC_BINDING.search(line)
                    or allowed(lines, index)):
                continue
            print(f"concurrency: {os.path.relpath(path, os.path.dirname(shared_root))}:{index + 1}: task local bound with "
                  "withValue in a shared package (where no task is current the runtime frees a marker with free() "
                  "that its task allocator made, cx-bpcj); bind it inside a task and say so with // concurrency-allow:")
            print(f"    {line.strip()}")
            failures += 1

# Model checks run off the main actor (see the header).
SUITE_DECL = re.compile(r"^\s*(@\w+(\([^)]*\))?\s+)*((public|internal|package|fileprivate|private|final)\s+)*(struct|final class|class|enum)\s+\w+ModelCheckTests\b")
tests = os.path.join(root, "Tests")
for dirpath, _, files in ([] if ONLY else os.walk(tests)):
    for filename in sorted(files):
        if not filename.endswith("ModelCheckTests.swift"):
            continue
        path = os.path.join(dirpath, filename)
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        for index, line in enumerate(lines):
            if SUITE_DECL.match(line) and not re.search(r"\bnonisolated\b", line):
                print(f"concurrency: {os.path.relpath(path, root)}:{index + 1}: model check suite on the main actor "
                      "(declare it `@Suite(.serialized) nonisolated struct`)")
                print(f"    {line.strip()}")
                failures += 1

if failures:
    print(f"check-concurrency: {failures} violation(s). Fix the blocking call, or add a reviewed "
          "`// concurrency-allow: <reason>` when it provably never runs on the main thread. "
          "Idle-wakeup hits need an event-driven wait or a reviewed `// wakeup-allow: <reason>` "
          "(plans/cmux-next/idle-wakeups.md).")
    sys.exit(1)
print("check-concurrency: ok")
PY
