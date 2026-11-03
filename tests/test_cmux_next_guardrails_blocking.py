#!/usr/bin/env python3
"""guardrails.py's main-blocking, raw-blocking and thread-doc rules (PL-blocking, plans/cmux-next/threading-model.md).

Each test commits into a throwaway repository and runs `guardrails.check` on what the commit adds. Not on CI
(Lawrence 2026-10-23: no new CI tests): run it yourself after a change to those rules:
python3 tests/test_cmux_next_guardrails_blocking.py
"""
import collections
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1]
PKG = "Packages/macOS/CmuxNext"
UI = f"{PKG}/Sources/CmuxNextUIKit"        # a uiSwiftSettings target: main-actor by default
SERVICE = f"{PKG}/Sources/CmuxNextService"  # a daemonSwiftSettings target: nonisolated by default
SEAMS = f"{PKG}/Sources/CmuxNextCompat/Threading"
MANIFEST = """// swift-tools-version: 6.2
let package = Package(name: "CmuxNext", targets: [
    .target(
        name: "CmuxNextUIKit",
        swiftSettings: uiSwiftSettings
    ),
    .target(
        name: "CmuxNextService",
        swiftSettings: daemonSwiftSettings
    ),
])
"""
DOC = """# threading model

A label `<x>` in prose, and `com.cmuxterm.next.prose-only` outside the section, list nothing.

## Registered threads and queues

- `com.cmuxterm.next.known`, `com.cmuxterm.next.daemon.exit.<pid>`, `cmux-next known thread`, `<x>`

## Reviewed blocking allowances

| Reason | Why |
|---|---|
| `terminate` | shutdown |
"""


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


git_fixture_env = _load("git_fixture_env", SOURCE / "tests/git_fixture_env.py")
guardrails = _load("cmux_next_guardrails_blocking", SOURCE / "scripts/cmux-next/guardrails.py")

# rule id -> (target directory, text that adds it, the right pattern or its reviewed escape)
CASES = {
    "main-blocking": [
        (UI, "func load() -> Data? {\n    try? Data(contentsOf: url)\n}\n",
         "func load() async -> Data? {\n    await Task.detached { try? Data(blockingContentsOf: url) }.value\n}\n"),
        (UI, "func ready() -> Bool {\n    FileManager.checked.fileExists(atPath: path)\n}\n",
         "nonisolated func ready() -> Bool {\n    FileManager.checked.fileExists(atPath: path)\n}\n"),
        (SERVICE, "@MainActor func wait() {\n    semaphore.blockingWait()\n}\n",
         "func wait() {\n    semaphore.blockingWait()\n}\n"),
        (SERVICE, "func hop() {\n    DispatchQueue.main.sync { print(1) }\n}\n",
         "func hop() async {\n    await MainActor.run { print(1) }\n}\n"),
        (SERVICE, "func nap() {\n    Thread.sleep(forTimeInterval: 0.1)\n}\n",
         "func nap() {\n    // blocking-allow: test fixture for the escape\n    Thread.sleep(forTimeInterval: 0.1)\n}\n"),
        (UI, "func done() {\n    process.waitUntilExit()\n}\n",
         "func done() {\n    process.terminationHandler = { _ in }\n}\n"),
    ],
    "main-blocking ": [  # the same rule: cases the review found refused correct code
        (UI, "func load() async {\n    try await backoff.wait(owner: self)\n}\n", None),
        (UI, "func load() async {\n    let x = await waiter.wait(timeout: .now())\n}\n", None),
        (UI, "func load() {\n    ioQueue.async {\n        _ = FileManager.checked.fileExists(atPath: path)\n    }\n}\n", None),
        (UI, "func run() {\n    process.terminationHandler = { _ in\n        semaphore.blockingWait()\n    }\n}\n", None),
        (UI, "func watch() {\n    source.setEventHandler {\n        _ = try? Data(blockingContentsOf: url)\n    }\n}\n", None),
        # An unnamed thread is thread-doc's (name it, list it); its body is not main-blocking's.
        (UI, "func start() {\n    Thread {\n        _ = FileManager.checked.fileExists(atPath: path)\n    }.start()\n}\n",
         "thread-doc"),
        (UI, "func check() {\n    if ready {\n        _ = FileManager.checked.fileExists(atPath: path)\n    }\n}\n",
         "main-blocking"),
        (UI, "func save() {\n    try? data.write(to: url)\n}\n", "main-blocking"),
        # Openers that run their body on main are judged in any target; other closures are not.
        (SERVICE, "func f() {\n    DispatchQueue.main.async {\n        _ = FileManager.checked.fileExists(atPath: p)\n    }\n}\n",
         "main-blocking"),
        (SERVICE, "func f() async {\n    await MainActor.run {\n        semaphore.blockingWait()\n    }\n}\n", "main-blocking"),
        (SERVICE, "func f() {\n    Task { @MainActor in\n        _ = try? Data(blockingContentsOf: url)\n    }\n}\n",
         "main-blocking"),
        (UI, "var body: some View {\n    Button(\"Go\") {\n        _ = FileManager.checked.fileExists(atPath: p)\n    }\n}\n", None),
        (UI, "func f() {\n    let work = DispatchWorkItem {\n        semaphore.blockingWait()\n    }\n    queue.async(execute: work)\n}\n",
         None),
        (UI, "func f() {\n    let t = Thread {\n        semaphore.blockingWait()\n    }\n    t.name = \"cmux-next known thread\"\n}\n",
         None),
        # A header over several lines is a function or a condition, not a closure.
        (UI, "func load(\n    url: URL,\n    options: Int\n) async throws {\n    _ = FileManager.checked.fileExists(atPath: p)\n}\n",
         "main-blocking"),
        (UI, "func load<T>(_ t: T)\n    where T: Sendable {\n    semaphore.blockingWait()\n}\n", "main-blocking"),
        (UI, "func f() {\n    if ready,\n       let path {\n        _ = FileManager.checked.fileExists(atPath: path)\n    }\n}\n",
         "main-blocking"),
        (UI, "func f() {\n    guard let path,\n          ready else {\n        semaphore.blockingWait()\n        return\n    }\n}\n",
         "main-blocking"),
        (UI, "func f() {\n    while running,\n          ready {\n        semaphore.blockingWait()\n    }\n}\n", "main-blocking"),
        (UI, "var path: String {\n    _ = FileManager.checked.fileExists(atPath: p)\n    return p\n}\n", "main-blocking"),
    ],
    "raw-blocking": [
        (SERVICE, "func load() -> Data? {\n    try? Data(contentsOf: url)\n}\n",
         "func load() -> Data? {\n    try? Data(blockingContentsOf: url)\n}\n"),
        (SERVICE, "func gone() {\n    try? FileManager.default.removeItem(at: url)\n}\n",
         "func gone() {\n    try? FileManager.checked.removeItem(at: url)\n}\n"),
        (SERVICE, "func read() -> Int {\n    queue.sync { count }\n}\n",
         "func read() -> Int {\n    queue.blockingSync { count }\n}\n"),
        (SERVICE, "func w() {\n    _ = group.wait(timeout: .now() + 1)\n}\n",
         "func w() {\n    _ = group.blockingWait(timeout: .now() + 1)\n}\n"),
    ],
    "maybe-main-blocking ": [  # (PL-qos) a caller-isolated async function: a warning, never a refusal
        (SERVICE, "func run() async throws {\n    try process.blockingRun()\n}\n", None),
    ],
    "raw-blocking ": [
        (SERVICE, "func start() {\n    _ = posix_spawn(&pid, path, nil, nil, argv, envp)\n}\n", "raw-blocking"),
        (SERVICE, "func start() {\n    _ = blockingPosixSpawn(&pid, path, nil, nil, argv, envp)\n}\n", None),
        (UI, "func start() throws {\n    try process.blockingRun()\n}\n", "main-blocking"),
        (SERVICE, "func save() {\n    try? data.write(to: url)\n}\n", "raw-blocking"),
        (SERVICE, "func save() {\n    try? data.blockingWrite(to: url)\n}\n", None),
        (SERVICE, "func load() async {\n    try await backoff.wait(owner: self)\n}\n", None),
    ],
    "thread-doc ": [
        (SERVICE, 'let q = DispatchQueue(label: "com.cmuxterm.next.prose-only")\n', "thread-doc"),
        (SERVICE, 'let q = DispatchQueue(label: "anything-at-all")\n', "thread-doc"),
        (SERVICE, "let q = DispatchQueue(label: label, qos: .utility)\n", None),
        (SERVICE, "extension Thread {\n    var isWorker: Bool { false }\n}\n", None),
        (SERVICE, "func f(_ thread: Thread) {}\n", None),
        (SERVICE, "final class Worker: Thread {\n    override func main() {}\n}\n", None),
        (SERVICE, "func make() -> Thread {\n    current\n}\n", None),
        (SERVICE, "var worker: Thread {\n    current\n}\n", None),
        (SERVICE, "func start() {\n    let t = Thread { work() }\n    t.start()\n}\n", "thread-doc"),
        (SERVICE, "func start() {\n    run(Thread { work() })\n}\n", "thread-doc"),
    ],
    "thread-doc": [
        (SERVICE, 'let q = DispatchQueue(label: "com.cmuxterm.next.unknown")\n',
         'let q = DispatchQueue(label: "com.cmuxterm.next.known")\n'),
        (SERVICE, 'let q = DispatchQueue(label: "com.cmuxterm.next.daemon.exit.\\(pid)", qos: .utility)\n',
         'let q = DispatchQueue(label: "com.cmuxterm.next.daemon.exit.\\(pid)", qos: .utility)\n'),
        (SERVICE, 'func start() {\n    let t = Thread { work() }\n    t.name = "cmux-next mystery"\n    t.start()\n}\n',
         'func start() {\n    let t = Thread { work() }\n    t.name = "cmux-next known thread"\n    t.start()\n}\n'),
        (SEAMS, "extension BlockingAllowance {\n    static let launch = BlockingAllowance(reviewed: \"launch\")\n}\n",
         "extension BlockingAllowance {\n    static let terminate = BlockingAllowance(reviewed: \"terminate\")\n}\n"),
    ],
}
# The second thread-doc case is listed (an interpolated label against `<pid>`): its "bad" text is not debt.
LISTED = {("thread-doc", 1)}


class BlockingRuleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-guardrails-blocking-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.repo = root / "repository"
        config = root / "gitconfig"
        config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=str(root))
        git_fixture_env.without_auto_maintenance(self.env)
        self.repo.mkdir()
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")
        self.write(f"{PKG}/Package.swift", MANIFEST)
        self.write("plans/cmux-next/threading-model.md", DOC)
        self.write(f"{UI}/Old.swift", "func old() -> Data? {\n    try? Data(contentsOf: url)\n}\n")  # base debt
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, text=True, capture_output=True, check=True)

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--no-verify", "-m", message)

    def refused_ids(self):
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        try:
            refusals, warnings = guardrails.check(self.repo, self.base, "HEAD")
        finally:
            os.environ.update(saved)
        self.assertEqual([w for w in warnings if w[0] == "guardrails"], [], "a blocking rule failed open")
        return [r.id for r, _ in refusals]

    def push(self, directory, text):
        self.git("reset", "--quiet", "--hard", self.base)
        self.write(f"{directory}/Added.swift", text)
        self.commit("adds")
        return self.refused_ids()

    def test_each_rule_refuses_what_a_push_adds_and_passes_the_right_pattern(self):
        for rule, cases in CASES.items():
            if rule.endswith(" "):  # (directory, text, the one rule it must trip or None) cases
                for number, (directory, text, expected) in enumerate(cases):
                    with self.subTest(rule=rule, case=number):
                        ids = [i for i in self.push(directory, text) if i in ("main-blocking", "raw-blocking", "thread-doc")]
                        self.assertEqual(ids, [expected] if expected else [], text)
                continue
            for number, (directory, bad, good) in enumerate(cases):
                with self.subTest(rule=rule, case=number):
                    if (rule, number) in LISTED:
                        self.assertNotIn(rule, self.push(directory, bad))
                    else:
                        self.assertIn(rule, self.push(directory, bad), f"{rule} case {number} not refused")
                    self.assertNotIn(rule, self.push(directory, good), f"{rule} case {number}: right pattern refused")

    def test_a_caller_isolated_async_function_warns_and_never_refuses(self):
        cases = {
            "func run() async throws {\n    try process.blockingRun()\n}\n": True,
            "@concurrent func run() async throws {\n    try process.blockingRun()\n}\n": False,
            "nonisolated func run() async throws {\n    try process.blockingRun()\n}\n": False,
            "actor Runner {\n    func run() async throws {\n        try process.blockingRun()\n    }\n}\n": False,
            "func run() throws {\n    try process.blockingRun()\n}\n": False,
        }
        for text, warns in cases.items():
            with self.subTest(text=text):
                self.git("reset", "--quiet", "--hard", self.base)
                self.write(f"{SERVICE}/Added.swift", text)
                self.commit("adds")
                saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
                try:
                    refusals, warnings = guardrails.check(self.repo, self.base, "HEAD")
                finally:
                    os.environ.update(saved)
                self.assertNotIn("maybe-main-blocking", [r.id for r, _ in refusals])
                self.assertEqual(any(kind == "maybe-main-blocking" for kind, _ in warnings), warns)

    def test_a_blocking_call_on_main_is_reported_once_not_also_as_raw(self):
        ids = self.push(UI, "func load() -> Data? {\n    try? Data(contentsOf: url)\n}\n")
        self.assertIn("main-blocking", ids)
        self.assertNotIn("raw-blocking", ids)

    def test_base_debt_and_the_seams_never_count(self):
        self.write(f"{UI}/Other.swift", "let x = 1\n")
        self.write(f"{SEAMS}/Data+Blocking.swift", "func seam() {\n    _ = try? Data(contentsOf: url)\n    semaphore.wait()\n}\n")
        self.write(f"{PKG}/Sources/CmuxNextCompat/Mutex.swift", "func lock() {\n    queue.sync { }\n}\n")
        self.commit("edits elsewhere and adds seams")
        self.assertEqual(self.refused_ids(), [])

    def test_a_missing_doc_fails_thread_doc_open_and_keeps_the_others(self):
        self.git("rm", "--quiet", "plans/cmux-next/threading-model.md")
        self.write(f"{SERVICE}/Added.swift", 'let q = DispatchQueue(label: "x")\nfunc f() { Thread.sleep(forTimeInterval: 1) }\n')
        self.commit("drops the doc")
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        try:
            refusals, warnings = guardrails.check(self.repo, self.base, "HEAD")
        finally:
            os.environ.update(saved)
        self.assertIn("main-blocking", [r.id for r, _ in refusals])
        self.assertTrue(any(kind == "guardrails" and "thread-doc" in text for kind, text in warnings))

    def test_a_merge_judges_each_range_by_its_own_threading_doc(self):
        """check_own measures a merge's ranges at once on two threads. Each must judge thread-doc by the doc at its
        own head: here the earlier range's doc (without the new label) loads after HEAD's and before HEAD's rules
        run. A shared copy of the doc refused HEAD's listed thread (#30169, 5eb80dfa4a0: 1 run in 6)."""
        self.write(f"{SERVICE}/Other.swift", "let other = 1\n")
        self.commit("the branch's earlier push: its doc does not list the new thread")
        before = self.git("rev-parse", "HEAD").stdout.strip()
        self.write("plans/cmux-next/threading-model.md", DOC.replace("`<x>`", "`cmux-next fresh thread`, `<x>`"))
        self.write(f"{SERVICE}/Added.swift",
                   'func start() {\n    let t = Thread { work() }\n    t.name = "cmux-next fresh thread"\n    t.start()\n}\n')
        self.commit("adds a thread and lists it")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        head_loaded, before_loaded = threading.Event(), threading.Event()
        load = guardrails.load_blocking_context

        def interleaved(texts, rev):
            if rev == before:
                head_loaded.wait(10)
                load(texts, rev)
                before_loaded.set()
            else:
                load(texts, rev)
                head_loaded.set()
                before_loaded.wait(10)

        guardrails.load_blocking_context = interleaved
        self.addCleanup(setattr, guardrails, "load_blocking_context", load)
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        try:
            refusals, warnings = guardrails.check_own(self.repo, self.base, head, [(self.base, before)])
        finally:
            os.environ.update(saved)
        self.assertTrue(head_loaded.is_set() and before_loaded.is_set(), "the two ranges did not interleave")
        self.assertEqual([w for w in warnings if w[0] == "guardrails"], [])
        self.assertNotIn("thread-doc", [r.id for r, _ in refusals])

    def test_the_blocking_rules_stay_fast_on_a_large_keyword_heavy_push(self):
        """60,000 added lines in main-actor code, a third of them blocking calls (no escape, so every one goes
        through the main-actor scope and the closure walk, and is refused): the three rules' CPU time stays
        under 1 s."""
        body = "".join(f"func f{i}() {{\n    if ready {{\n        _ = FileManager.checked.fileExists(atPath: p{i})\n    }}\n}}\n"
                       for i in range(600))
        changes = []
        for index in range(20):
            path = f"{UI}/Big{index}.swift"
            lines = body.split("\n")
            changes.append(guardrails.FileChange(path, lines, [guardrails.Added(path, n + 1, t) for n, t in enumerate(lines)]))
        guardrails.RUN_CONTEXT.values = {"threading_doc": DOC, "manifest": MANIFEST}
        started = time.process_time()
        hits = {rule.id: rule.find(changes, collections.Counter()) for rule in guardrails.BLOCKING_RULES}
        elapsed = time.process_time() - started
        self.assertEqual(len(hits["main-blocking"]), 20 * 600)  # the scope and closure checks really ran
        self.assertLess(elapsed, 1.0)


if __name__ == "__main__":
    unittest.main()
