#!/usr/bin/env python3
"""cmux-next guardrails (scripts/cmux-next/guardrails.py): refuse new debt, warn on hot paths and owners.

Each test commits into a throwaway repository and checks what the commit adds. The rule tests call
`guardrails.check` directly; the hook tests install the real hooks and push through the real `git push`,
so the installed trusted copy of the gate is what runs. Run it yourself (Lawrence 2026-10-23: no new
CI tests): python3 tests/test_cmux_next_guardrails.py
"""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import git_fixture_env  # disables git auto maintenance

SOURCE = Path(__file__).resolve().parents[1]
PKG = "Packages/macOS/CmuxNext"
KIT = f"{PKG}/Sources/CmuxNextKit"
APP = f"{PKG}/Sources/CmuxNextApp"
AGENT_VARS = ("CMUX_AGENT", "CMUX_REQUIRE_FORMATTERS", "CI", "CLAUDECODE", "CODEX_CI", "CODEX_THREAD_ID",
              "CODEX_SANDBOX", "CMUX_WEB_LINT_SKIP_REASON", "CMUX_NEXT_CHECKS_SKIP_REASON",
              "CMUX_GUARDRAILS_SKIP_REASON", "GITHUB_ACTIONS")
if os.uname().sysname == "Darwin":
    TOOLS = Path.home() / "Library" / "Caches" / "cmux-lint-tools"
else:
    TOOLS = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "cmux-lint-tools"
TOOLS = Path(os.environ.get("CMUX_LINT_TOOLS_DIR", TOOLS))

_spec = importlib.util.spec_from_file_location("cmux_next_guardrails", SOURCE / "scripts/cmux-next/guardrails.py")
guardrails = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = guardrails
_spec.loader.exec_module(guardrails)

HOT = """import Foundation
final class Router {
    var count = 0
    func dispatch(_ key: Int) { // perf-hot: 2ms key-dispatch
        count += key
    }
    func cold() {
        count = 0
    }
}
"""
OWNERS = """# owners

| Area | Paths | Owner | Read first |
|---|---|---|---|
| Kit sidebar | `Packages/macOS/CmuxNext/Sources/CmuxNextKit/Sidebar/` | a590 | [sidebar-owner.md](sidebar-owner.md) |
"""
BENCHES = '{"paths": {"key-dispatch": {"bench": "scripts/cmux-next/bench-typing.py", "owner": "PL-typing"}}}'
ROW = """import SwiftUI
struct WorkspaceRow: View {
    let title: String
    var body: some View { Text(title) }
}
"""

# rule id -> (file text that adds it, the same with its reviewed escape or the right pattern)
CASES = {
    "singleton": ("final class Cache {\n    static let shared = Cache()\n}\n",
                  "final class Cache {\n    // singleton-allow: the process has exactly one memory-pressure source\n"
                  "    static let shared = Cache()\n}\n"),
    "assume-isolated": ("func f() {\n    MainActor.assumeIsolated { print(1) }\n}\n",
                        "func f() {\n    MainActor.assumeIsolated { print(1) } // main-proof: observer on queue: .main\n}\n"),
    "unchecked-sendable": ("final class Box: @unchecked Sendable {\n    var x = 0\n}\n",
                           "// crash-allow: x is written once in init, then only read\n"
                           "final class Box: @unchecked Sendable {\n    let x = 0\n}\n"),
    "sleep-poll": ("func wait() async throws {\n    while !ready() {\n        try await Task.sleep(for: .milliseconds(5))\n    }\n}\n",
                   "func wait() async throws {\n    try await Task.sleep(for: .seconds(2)) // a minimum display time\n}\n"),
    "main-async": ("func f() {\n    DispatchQueue.main.async { print(1) }\n}\n",
                   "@MainActor func f() {\n    print(1)\n}\n"),
    "broadcast-name": ("extension Notification.Name {\n    static let pagesChanged = Notification.Name(\"pagesChanged\")\n}\n",
                       "protocol PagesObserver: AnyObject {\n    func pageChanged(_ id: Int)\n}\n"),
    "combine-state": ("import Combine\nfinal class Model: ObservableObject {\n    @Published var x = 0\n}\n",
                      "import Observation\n@Observable final class Model {\n    var x = 0\n}\n"),
    "row-store": ("import SwiftUI\nstruct WorkspaceRow: View {\n    let title: String\n"
                  "    @Environment(SidebarStore.self) private var store\n    var body: some View { Text(title) }\n}\n",
                  "import SwiftUI\nstruct WorkspaceRow: View {\n    let title: String\n    let onSelect: () -> Void\n"
                  "    var body: some View { Text(title) }\n}\n"),
}


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-guardrails-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repository"
        self.origin = self.root / "origin.git"
        config = self.root / "gitconfig"
        config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k not in AGENT_VARS}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=str(self.root),
                        CMUX_LINT_TOOLS_DIR=str(TOOLS))
        git_fixture_env.without_auto_maintenance(self.env)
        subprocess.run(["git", "init", "--quiet", "--bare", "--initial-branch=feat-cmux-next", str(self.origin)],
                       env=self.env, check=True, capture_output=True)
        self.repo.mkdir()
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")
        self.git("remote", "add", "origin", str(self.origin))
        self.write(f"{KIT}/Router.swift", HOT)
        self.write(f"{KIT}/WorkspaceRow.swift", ROW)
        self.write(f"{KIT}/Old.swift", "final class Old {\n    static let shared = Old()\n}\n")  # base debt
        self.write("plans/cmux-next/OWNERS.md", OWNERS)
        self.write("scripts/cmux-next/perf-hot-benches.json", BENCHES)
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args, check=True):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, text=True, capture_output=True,
                              check=check)

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--no-verify", "-m", message)

    def check(self):
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        try:
            return guardrails.check(self.repo, self.base, "HEAD")
        finally:
            os.environ.update(saved)


class RuleTests(Fixture):
    def test_each_rule_refuses_what_a_push_adds_and_passes_the_right_pattern(self):
        for rule, (bad, good) in CASES.items():
            with self.subTest(rule=rule):
                self.git("reset", "--quiet", "--hard", self.base)
                target = f"{KIT}/WorkspaceRow.swift" if rule == "row-store" else f"{KIT}/Added.swift"
                self.write(target, bad)
                self.commit(f"adds {rule}")
                refusals, _ = self.check()
                self.assertIn(rule, [r.id for r, _ in refusals], f"{rule} not refused")
                text, refused = guardrails.format_report(refusals, [])
                self.assertTrue(refused)
                self.assertIn("why:", text)
                self.assertIn("do:", text)
                self.assertIn(guardrails.SKIP_ENV, text)

                self.git("reset", "--quiet", "--hard", self.base)
                self.write(target, good)
                self.commit(f"right pattern for {rule}")
                refusals, _ = self.check()
                self.assertEqual([r.id for r, _ in refusals], [], f"{rule}: the right pattern was refused")

    def test_base_debt_and_moved_lines_never_count(self):
        self.git("mv", f"{KIT}/Old.swift", f"{KIT}/Moved.swift")
        self.write(f"{KIT}/Router.swift", HOT.replace("var count = 0", "var count = 1"))
        self.commit("moves the old singleton and edits elsewhere")
        refusals, _ = self.check()
        self.assertEqual(refusals, [])

    def test_big_new_app_file_is_refused_and_app_growth_warns(self):
        self.write(f"{APP}/Feature.swift", "import Foundation\n" + "let x = 1\n" * 450)
        self.commit("big new App file")
        refusals, warnings = self.check()
        self.assertIn("app-big-file", [r.id for r, _ in refusals])
        self.assertTrue(any(kind == "app-grow" for kind, _ in warnings))

    def test_skip_reason_lets_the_push_through_and_is_printed(self):
        self.write(f"{KIT}/Added.swift", CASES["singleton"][0])
        self.commit("adds a singleton")
        refusals, warnings = self.check()
        os.environ[guardrails.SKIP_ENV] = "singleton: test"
        try:
            text, refused = guardrails.format_report(refusals, warnings)
        finally:
            del os.environ[guardrails.SKIP_ENV]
        self.assertFalse(refused)
        self.assertIn("SKIPPED", text)


class WarningTests(Fixture):
    def test_changing_a_perf_hot_function_names_its_bench(self):
        self.write(f"{KIT}/Router.swift", HOT.replace("count += key", "count += key * 2"))
        self.commit("changes the hot path")
        refusals, warnings = self.check()
        self.assertEqual(refusals, [])
        hot = [w for kind, w in warnings if kind == "perf-hot"]
        self.assertEqual(len(hot), 1, warnings)
        self.assertIn("bench-typing.py", hot[0])
        self.assertIn("2ms", hot[0])

    def test_changing_a_cold_function_does_not_warn(self):
        self.write(f"{KIT}/Router.swift", HOT.replace("count = 0\n    }\n}", "count = -1\n    }\n}"))
        self.commit("changes the cold path")
        _, warnings = self.check()
        self.assertEqual([w for kind, w in warnings if kind == "perf-hot"], [])

    def test_removing_a_perf_hot_marker_warns(self):
        self.write(f"{KIT}/Router.swift", HOT.replace(" // perf-hot: 2ms key-dispatch", ""))
        self.commit("drops the marker")
        _, warnings = self.check()
        self.assertTrue(any("removes a perf-hot marker" in w for _, w in warnings), warnings)

    def test_touching_an_owned_area_names_the_owner_and_doc(self):
        self.write(f"{KIT}/Sidebar/Row.swift", "struct R {}\n")
        self.commit("sidebar row")
        refusals, warnings = self.check()
        self.assertEqual(refusals, [])
        owners = [w for kind, w in warnings if kind == "owner"]
        self.assertEqual(len(owners), 1, warnings)
        self.assertIn("a590", owners[0])
        self.assertIn("plans/cmux-next/sidebar-owner.md", owners[0])

    def test_a_typical_push_is_checked_in_well_under_a_second(self):
        for n in range(5):
            self.write(f"{KIT}/F{n}.swift", "import Foundation\n" + "func f() { print(1) }\n" * 300)
        self.commit("five files")
        started = time.monotonic()
        self.check()
        self.assertLess(time.monotonic() - started, 1.0)


class HookTests(Fixture):
    """The installed pre-push hook runs the guardrails; CI (GITHUB_ACTIONS, --commits) never does."""

    def setUp(self):
        super().setUp()
        tracked = subprocess.run(["git", "-C", str(SOURCE), "ls-files", "--cached", "--others", "--exclude-standard",
                                  "scripts/cmux-next"], text=True, capture_output=True, check=True).stdout.split()
        checks = [p for p in tracked if "/" not in p[len("scripts/cmux-next/"):] or p.startswith("scripts/cmux-next/lint/")]
        for relative in ("scripts/git-hooks", "scripts/install-git-hooks.sh", "scripts/web_lint_prepush.py",
                         "scripts/ci/base_merge_warning.py", "scripts/web-lint.sh", "scripts/merge-xcstrings.py",
                         "scripts/merge-pbxproj.py", "scripts/merge-baseline.py", "scripts/merge-daemon-capabilities.py",
                         "scripts/ci/merge_main_resolver.py", "scripts/ci/validate_test_execution_registry.py",
                         "scripts/ci/test_execution_registry.py", "scripts/ci/workload_entrypoints.py",
                         "scripts/normalize-pbxproj.py", *checks):
            source, target = SOURCE / relative, self.repo / relative
            if not source.exists() or target.exists():
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copyfile(source, target)
                shutil.copymode(source, target)
        self.commit("scripts")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        installed = subprocess.run(["bash", "scripts/install-git-hooks.sh"], cwd=self.repo, env=self.env, text=True,
                                   capture_output=True)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.write(f"{KIT}/Added.swift", "final class Cache {\n    static let shared = Cache()\n}\n")
        self.commit("adds a singleton")

    def push(self, **env):
        return subprocess.run(["git", "-C", str(self.repo), "push", "origin", "feat-cmux-next"],
                              env={**self.env, **env}, text=True, capture_output=True)

    def test_hook_refuses_a_new_singleton_even_with_the_checks_skip_reason(self):
        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: other checks")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("[singleton]", output)
        self.assertIn("Added.swift", output)
        self.assertNotIn("Old.swift", output, "base debt must not be reported")

    def test_hook_lets_the_push_through_with_the_guardrails_skip_reason(self):
        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: other checks",
                           CMUX_GUARDRAILS_SKIP_REASON="singleton: fixture")
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("SKIPPED by CMUX_GUARDRAILS_SKIP_REASON", output)

    def test_ci_runs_never_apply_the_guardrails(self):
        gate = self.repo / "scripts/cmux-next/prepush-gate.py"
        local = subprocess.run([sys.executable, "-I", str(gate), "--base", self.base, "--head", "HEAD"],
                               cwd=self.repo, env=self.env, text=True, capture_output=True)
        self.assertIn("[singleton]", local.stdout + local.stderr, "a local run applies them (control)")
        for args, env in (([], {"GITHUB_ACTIONS": "true"}), (["--commits", f"{self.base}..HEAD"], {})):
            with self.subTest(args=args, env=env):
                result = subprocess.run([sys.executable, "-I", str(gate), "--base", self.base, "--head", "HEAD", *args]
                                        if not args else [sys.executable, "-I", str(gate), *args],
                                        cwd=self.repo, env={**self.env, **env}, text=True, capture_output=True)
                self.assertNotIn("guardrails", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
