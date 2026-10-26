#!/usr/bin/env python3
"""guardrails.py's raw-blocking-ext rule (p02-threads-126): the blocking primitives raw-blocking does not name.

The rule refuses, on any thread, a FileManager disk op through a name the file binds to a FileManager (`let fm =
FileManager.default`, `fileManager: FileManager = .default`, `FileManager()`), POSIX file and process calls, FileHandle
open/write/read/seek/synchronize, ImageIO URL I/O, sqlite3_*, sysctl, proc_pid*, LAContext policy checks, getpw* and
Host.current(). The fixtures pin what it must not refuse: a method of the same name (`menu.removeItem(at:)`), the
`stat()` struct initializer, a `waitpid(..., WNOHANG)` poll, a POSIX name the file declares itself, an awaited
`evaluatePolicy`, the seams and an escaped line. The acceptance count runs threading-inventory.py on 772cdfc45ac.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the rule:
  python3 -m pytest scripts/cmux-next/tests/test_guardrails.py
  python3 -I scripts/cmux-next/tests/test_guardrails.py
"""
from __future__ import annotations

import collections
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # loading the scripts below must not write __pycache__ beside them

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parents[1]
INVENTORY_REV = "772cdfc45ac"
SERVICE = "Packages/macOS/CmuxNext/Sources/CmuxNextService/"
UI = "Packages/macOS/CmuxNext/Sources/CmuxNextUIKit/"
SEAMS = "Packages/macOS/CmuxNext/Sources/CmuxNextCompat/Threading/"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


guardrails = _load("cmux_next_guardrails_ext", SCRIPTS / "guardrails.py")
RULE = next(rule for rule in guardrails.RULES if rule.id == "raw-blocking-ext")

REFUSED = {
    "fm variable": "func f() {\n    let fm = FileManager.default\n    try? fm.removeItem(at: url)\n}\n",
    "typed property": ("struct S {\n    let fileManager: FileManager = .default\n"
                       "    func f() -> Bool { self.fileManager.fileExists(atPath: p) }\n}\n"),
    "injected parameter": "init(files: FileManager) {\n    _ = files.contentsOfDirectory(atPath: p)\n}\n",
    "FileManager()": "func f() {\n    _ = FileManager().fileExists(atPath: p)\n}\n",
    "stat(path, &st)": "func f() -> Bool {\n    var st = stat()\n    return stat(path, &st) == 0\n}\n",
    "lstat": "func f() {\n    guard lstat(url.path, &info) == 0 else { return }\n}\n",
    "open O_": "func f() {\n    let fd = open(path, O_RDONLY | O_CLOEXEC)\n}\n",
    "Darwin.open": "func f() {\n    let fd = Darwin.open(path, flags)\n}\n",
    "Darwin.read": "func f() {\n    _ = Darwin.read(fd, &buffer, 1)\n}\n",
    "rename": "func f() {\n    guard rename(temporary.path, url.path) == 0 else { return }\n}\n",
    "unlink": "func f() {\n    unlink(path)\n}\n",
    "fsync flock": "func f() {\n    _ = fsync(fd)\n    _ = flock(fd, LOCK_EX)\n}\n",
    "realpath": "func f() {\n    let resolved = realpath(path, nil)\n}\n",
    "waitpid blocking": "func f() {\n    while waitpid(pid, &status, 0) < 0, errno == EINTR {}\n}\n",
    "FileHandle open": "func f() throws {\n    let h = try FileHandle(forWritingTo: url)\n}\n",
    "FileHandle write": "func f() throws {\n    try handle.write(contentsOf: data)\n    try handle.synchronize()\n}\n",
    "FileHandle read": "func f() throws {\n    _ = try handle.read(upToCount: 16)\n    _ = try handle.seekToEnd()\n}\n",
    "ImageIO": "func f() {\n    let s = CGImageSourceCreateWithURL(url as CFURL, nil)\n}\n",
    "ImageIO finalize": "func f() {\n    _ = CGImageDestinationFinalize(destination)\n}\n",
    "sqlite3": "func f() {\n    _ = sqlite3_open_v2(path, &db, flags, nil)\n    _ = sqlite3_step(statement)\n}\n",
    "sysctl": "func f() {\n    _ = sysctl(&mib, 4, &info, &size, nil, 0)\n    _ = sysctlbyname(name, &v, &n, nil, 0)\n}\n",
    "proc_pid": "func f() {\n    _ = proc_pidpath(pid, &buffer, 4096)\n}\n",
    "LAContext": "func f() {\n    _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)\n}\n",
    "getpwuid": "func f() {\n    let entry = getpwuid(getuid())\n}\n",
    "Host.current": "func f() {\n    _ = Host.current().localizedName\n}\n",
}
PASSED = {
    "a method with no binding": "func f() {\n    menu.removeItem(at: 0)\n}\n",
    "fileExists on a non-FileManager": "func f(store: Store) {\n    _ = store.fileExists(atPath: p)\n}\n",
    "stat() initializer": "func f() {\n    var st = stat()\n}\n",
    "WNOHANG poll": "func f() {\n    _ = waitpid(pid, &status, WNOHANG)\n}\n",
    "a labeled call": "func f() {\n    rename(id, to: name)\n    _ = access(keyPath: \\.sections)\n}\n",
    "a declaration": "func rename(_ url: URL, to name: String) {}\nenum E { case stat(Int) }\n",
    "an injected closure": ("struct S {\n    var stat: (String) -> Int?\n"
                            "    func f() { _ = stat(path) }\n}\n"),
    "a closure parameter": "init(rename: @escaping (String, String) -> Void) {\n    rename(a, b)\n}\n",
    "the seam": "func f() throws {\n    _ = FileManager.checked.fileExists(atPath: p)\n    _ = try handle.blockingRead(upToCount: 4)\n}\n",
    "a chained default": "func f() {\n    let home = FileManager.default\n        .homeDirectoryForCurrentUser\n    _ = home.url(\n}\n",
    "an awaited policy": "func f() async {\n    _ = try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: r)\n}\n",
    "a comment and a string": "func f() {\n    // unlink(path)\n    print(\"stat(path, &st)\")\n}\n",
    "the escape": "func f() {\n    // blocking-allow: test fixture for the escape\n    unlink(path)\n}\n",
    "Darwin.close": "func f() {\n    Darwin.close(fd)\n    _ = open\n}\n",
}


def change(path: str, text: str):
    lines = text.split("\n")
    return guardrails.FileChange(path, lines, [guardrails.Added(path, n + 1, t) for n, t in enumerate(lines)],
                                 is_new=True)


def hits(text: str, directory: str = SERVICE) -> list:
    return RULE.find([change(directory + "Added.swift", text)], collections.Counter())


class RawBlockingExtTests(unittest.TestCase):
    def test_each_primitive_is_refused(self):
        for name, text in REFUSED.items():
            with self.subTest(name):
                self.assertTrue(hits(text), f"{name} not refused:\n{text}")

    def test_lookalikes_seams_and_escapes_pass(self):
        for name, text in PASSED.items():
            with self.subTest(name):
                self.assertEqual([h.text for h in hits(text)], [], f"{name} refused")

    def test_the_named_lines_are_the_hits(self):
        found = hits(REFUSED["stat(path, &st)"])
        self.assertEqual([h.number for h in found], [3])  # the call, not `var st = stat()`
        found = hits(REFUSED["fm variable"])
        self.assertEqual([h.number for h in found], [3])  # the op, not the binding

    def test_main_actor_code_and_the_seam_folder(self):
        self.assertTrue(hits("func f() {\n    unlink(path)\n}\n", UI), "main-actor code is refused too")
        self.assertEqual(hits("func blockingUnlink() {\n    unlink(path)\n}\n", SEAMS), [])

    def test_raw_blocking_does_not_also_report_these(self):
        """The two rules name disjoint primitives, so a line is refused once."""
        raw = next(rule for rule in guardrails.RULES if rule.id == "raw-blocking")
        for name, text in REFUSED.items():
            with self.subTest(name):
                self.assertEqual(raw.find([change(SERVICE + "Added.swift", text)], collections.Counter()), [])

    def test_a_push_is_judged_through_check(self):
        """The rule runs in the hook's check() on what a commit adds, and base debt does not count."""
        with tempfile.TemporaryDirectory(prefix="cmux-guardrails-ext-") as root:
            repo = Path(root) / "repository"
            env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
            config = Path(root) / "gitconfig"
            config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n[maintenance]\n\tauto = false\n"
                              "[gc]\n\tauto = 0\n")
            env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=root)

            def git(*args):
                return subprocess.run(["git", "-C", str(repo), *args], env=env, text=True, capture_output=True,
                                      check=True).stdout

            repo.mkdir()
            git("init", "--quiet", "--initial-branch=feat-cmux-next")
            old = repo / SERVICE / "Old.swift"
            old.parent.mkdir(parents=True)
            old.write_text("func old() {\n    unlink(path)\n}\n")
            git("add", "-A")
            git("commit", "--quiet", "--no-verify", "-m", "base")
            base = git("rev-parse", "HEAD").strip()
            old.write_text("func old() {\n    unlink(path)\n}\nfunc other() {}\n")
            (repo / SERVICE / "Added.swift").write_text(REFUSED["fm variable"])
            git("add", "-A")
            git("commit", "--quiet", "--no-verify", "-m", "adds")
            saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
            try:
                refusals, warnings = guardrails.check(repo, base, "HEAD")
            finally:
                os.environ.update(saved)
            self.assertEqual([w for w in warnings if w[0] == "guardrails"], [])
            found = {rule.id: [(h.path.rsplit("/", 1)[-1], h.number) for h in rule_hits] for rule, rule_hits in refusals}
            self.assertEqual(found.get("raw-blocking-ext"), [("Added.swift", 3)])

    def test_the_rule_stays_fast_on_a_large_keyword_heavy_push(self):
        """60,000 added lines, a third of them refused primitives and a third FileManager variable ops: the
        rule's CPU time stays under 1 s."""
        body = "".join(f"func f{i}() {{\n    let fm = FileManager.default\n    _ = fm.fileExists(atPath: p{i})\n"
                       f"    guard stat(path{i}, &info) == 0 else {{ return }}\n    menu.removeItem(at: {i})\n}}\n"
                       for i in range(500))
        changes = [change(f"{SERVICE}Big{index}.swift", body) for index in range(20)]
        started = time.process_time()
        found = RULE.find(changes, collections.Counter())
        elapsed = time.process_time() - started
        self.assertEqual(len(found), 20 * 500 * 2)
        self.assertLess(elapsed, 1.0)

    def test_inventory_counts_at_least_600_at_the_reference_rev(self):
        probe = subprocess.run(["git", "-C", str(REPO), "cat-file", "-e", f"{INVENTORY_REV}^{{commit}}"],
                               capture_output=True)
        if probe.returncode != 0:
            self.skipTest(f"{INVENTORY_REV} is not in this clone")
        out = subprocess.run([sys.executable, "-I", str(SCRIPTS / "threading-inventory.py"), "--repo", str(REPO),
                              "--rev", INVENTORY_REV, "--rule", "raw-blocking-ext", "--count"],
                             capture_output=True, text=True, check=True).stdout
        counts = dict(line.rsplit(" ", 1) for line in out.strip().splitlines())
        self.assertGreaterEqual(int(counts["raw-blocking-ext"]), 600, out)


if __name__ == "__main__":
    unittest.main()
