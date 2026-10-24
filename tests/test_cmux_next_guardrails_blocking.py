#!/usr/bin/env python3
"""guardrails.py's main-blocking, raw-blocking and thread-doc rules (PL-blocking, plans/cmux-next/threading-model.md).

Each test commits into a throwaway repository and runs `guardrails.check` on what the commit adds. Not on CI
(Lawrence 2026-10-23: no new CI tests): run it yourself after a change to those rules:
python3 tests/test_cmux_next_guardrails_blocking.py
"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
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

## Registered threads and queues

- `com.cmuxterm.next.known`, `com.cmuxterm.next.daemon.exit.<pid>`, `cmux-next known thread`

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
            for number, (directory, bad, good) in enumerate(cases):
                with self.subTest(rule=rule, case=number):
                    if (rule, number) in LISTED:
                        self.assertNotIn(rule, self.push(directory, bad))
                    else:
                        self.assertIn(rule, self.push(directory, bad), f"{rule} case {number} not refused")
                    self.assertNotIn(rule, self.push(directory, good), f"{rule} case {number}: right pattern refused")

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

    def test_the_whole_gate_stays_fast_on_a_large_push(self):
        body = "".join(f"func f{i}() {{\n    print({i})\n}}\n" for i in range(1000))
        for index in range(20):
            self.write(f"{UI}/Big{index}.swift", body)
        self.commit("a large push")
        started = time.monotonic()
        self.refused_ids()
        self.assertLess(time.monotonic() - started, 1.0)


if __name__ == "__main__":
    unittest.main()
