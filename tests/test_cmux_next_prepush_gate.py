#!/usr/bin/env python3
"""The pre-push hook refuses a push that adds a cmux-next static-check violation.

Each test builds a throwaway repository with the real hook installer, the real
scripts/cmux-next checks and a small CmuxNext package, then pushes to a bare
`origin` through the real `git push`, so the installed trusted hook copy is what
runs. The base already carries a `try!` (base debt): only what a push adds counts.
"""
import contextlib
import importlib.util
import sys
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import unittest
import unittest.mock
import urllib.request


def _load_git_fixture_env():
    """tests/git_fixture_env.py by path, so `python3 -I` (no script folder on sys.path) runs this file too."""
    spec = importlib.util.spec_from_file_location("git_fixture_env", Path(__file__).resolve().parent / "git_fixture_env.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # importing it disables git auto maintenance
    return module


git_fixture_env = _load_git_fixture_env()


SOURCE = Path(__file__).resolve().parents[1]
INSTALLER = "scripts/install-git-hooks.sh"
GATE = "scripts/cmux-next/prepush-gate.py"
# The fixture is a developer's own push: GITHUB_ACTIONS (set on CI) would turn the guardrails off in the hook
# (prepush-gate.py runs them locally only), and the tests that expect a guardrails line would fail only on CI.
AGENT_VARS = ("CMUX_AGENT", "CMUX_REQUIRE_FORMATTERS", "CI", "CLAUDECODE", "CODEX_CI", "CODEX_THREAD_ID",
              "CODEX_SANDBOX", "CMUX_WEB_LINT_SKIP_REASON", "CMUX_NEXT_CHECKS_SKIP_REASON",
              "CMUX_GUARDRAILS_SKIP_REASON", "GITHUB_ACTIONS")
PKG = "Packages/macOS/CmuxNext"
# The pinned tools are downloaded once per machine; the fixture HOME must not hide that cache.
if os.uname().sysname == "Darwin":
    TOOLS = Path.home() / "Library" / "Caches" / "cmux-lint-tools"
else:
    TOOLS = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "cmux-lint-tools"
TOOLS = Path(os.environ.get("CMUX_LINT_TOOLS_DIR", TOOLS))


def load_gate_tools():
    """scripts/cmux-next/prepush-gate.py as a module, from this checkout."""
    spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate_module", SOURCE / "scripts/cmux-next/prepush-gate.py")
    gate = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = gate
    spec.loader.exec_module(gate)
    return gate


def _pinned_swiftformat() -> Path:
    """The pinned SwiftFormat the gate downloads into TOOLS (scripts/cmux-next/lint-tools.lock, this platform)."""
    spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate_tools", SOURCE / "scripts/cmux-next/prepush-gate.py")
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)
    row = gate.read_lock(SOURCE / "scripts/cmux-next/lint-tools.lock").get("swiftformat")
    if row is None:
        return TOOLS / "swiftformat-unpinned-on-this-platform" / "swiftformat"
    return TOOLS / f"swiftformat-{row[0]}-{gate.platform_key()}" / "swiftformat"


SWIFTFORMAT = _pinned_swiftformat()
# These tests run the real pinned binary through the real hook; they do not download it (the gate would).
NEEDS_SWIFTFORMAT = unittest.skipUnless(
    SWIFTFORMAT.is_file() and os.access(SWIFTFORMAT, os.X_OK),
    f"the pinned SwiftFormat is not installed at {SWIFTFORMAT} (any push through the hook downloads it once)")
# One `consecutiveBlankLines` hit (scripts/cmux-next/lint/swiftformat.conf): a rule the SwiftLint layer does not have,
# so only the SwiftFormat layer can refuse it, and nothing any other check refuses.
SWIFTFORMAT_HIT = """struct Fresh {
    func a() -> Int { 1 }


    func b() -> Int { 2 }
}
"""
SWIFTFORMAT_CLEAN = SWIFTFORMAT_HIT.replace("\n\n\n", "\n\n")

PACKAGE = """// swift-tools-version: 6.2
import PackageDescription
let uiSwiftSettings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]
let package = Package(
    name: "CmuxNext",
    targets: [
        .target(name: "CmuxNextApp", swiftSettings: uiSwiftSettings),
        .target(name: "CmuxNextKit", swiftSettings: uiSwiftSettings),
    ]
)
"""
APP = """import Foundation
func start() { ChildSignalDefaults.installAppSignalPolicy() }
"""
OLD = """import Foundation
struct Old {
    let regex = try! NSRegularExpression(pattern: "a+")
    func name() -> String { "old" }
}
"""
NEW_WITH_TRY = """import Foundation
struct Fresh {
    func load(_ url: URL) -> Data {
        try! Data(contentsOf: url)
    }
}
"""
NEW_WITH_UNOWNED = """import Foundation
final class Owner {}
final class Fresh {
    unowned let owner: Owner
    init(owner: Owner) { self.owner = owner }
}
"""
# A try! and nothing else: no blocking read for the guardrails (main-blocking) to refuse on their own.
NEW_WITH_TRY_ONLY = """import Foundation
struct Fresh {
    func pattern() -> NSRegularExpression {
        try! NSRegularExpression(pattern: "a+")
    }
}
"""
# Clean for the scanners and the guardrails: the read goes through the checked seam (CmuxNextCompat/Threading)
# off the main thread.
NEW_CLEAN = """import Foundation
struct Fresh {
    func load(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) { try Data(blockingContentsOf: url) }.value
    }
}
"""

# A guardrails main-async hit (guardrails.py), not a scanner one.
MAIN_HOP = """func hop() {
    DispatchQueue.main.async { print(1) }
}
"""

# Shared.swift: SHARED_DEBT at the top (base debt upstream later removes), SHARED_MORE far below it (what the
# branch adds: a try! of the same text and a main hop), so the merge has no conflict.
SHARED = """import Foundation
struct Shared {{
{debt}    func name() -> String {{ "shared" }}
    func a() -> Int {{ 1 }}
    func b() -> Int {{ 2 }}
    func c() -> Int {{ 3 }}
    func d() -> Int {{ 4 }}
    func e() -> Int {{ 5 }}
{more}}}
"""
SHARED_DEBT = """    let regex = try! NSRegularExpression(pattern: "a+")
    func hop() {
        DispatchQueue.main.async { print(1) }
    }
"""
SHARED_MORE = """    func branch() -> Int {
        let regex = try! NSRegularExpression(pattern: "a+")
        DispatchQueue.main.async { print(2) }
        return regex.numberOfCaptureGroups
    }
"""

INTENT = """import AppIntents
struct RecordChiefVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Voice Note for Chief"
    static let description = IntentDescription("It is transcribed on this device and sent to your Chief.")
}
"""

class PrePushGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-prepush-gate-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repository"
        self.origin = self.root / "origin.git"
        self.global_config = self.root / "gitconfig"
        # The pushes below go into a local bare origin, whose receive-pack reads only config files (git_fixture_env).
        self.global_config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n"
                                      + git_fixture_env.CONFIG_FILE_OPT_OUT)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_") and key not in AGENT_VARS}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(self.global_config),
                        HOME=str(self.root), CMUX_LINT_TOOLS_DIR=str(TOOLS))
        git_fixture_env.without_auto_maintenance(self.env)

        subprocess.run(["git", "init", "--quiet", "--bare", "--initial-branch=feat-cmux-next", str(self.origin)],
                       env=self.env, check=True, capture_output=True)
        self.repo.mkdir()
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")
        self.git("remote", "add", "origin", str(self.origin))
        self.copy_sources()
        self.write(f"{PKG}/Package.swift", PACKAGE)
        self.write(f"{PKG}/Sources/CmuxNextApp/CmuxNextApp.swift", APP)
        self.write(f"{PKG}/Sources/CmuxNextKit/Old.swift", OLD)  # base debt: one try! already there
        self.commit("base")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        installed = subprocess.run(["bash", INSTALLER], cwd=self.repo, env=self.env, text=True, capture_output=True)
        self.assertEqual(installed.returncode, 0, installed.stderr)

    def copy_sources(self):
        tracked = subprocess.run(["git", "-C", str(SOURCE), "ls-files", "scripts/cmux-next"],
                                 text=True, capture_output=True, check=True).stdout.split()
        checks = [p for p in tracked if "/" not in p[len("scripts/cmux-next/"):] or p.startswith("scripts/cmux-next/lint/")]
        for relative in (
            "scripts/git-hooks",
            INSTALLER,
            "scripts/web_lint_prepush.py",
            "scripts/ci/base_merge_warning.py",
            "scripts/ci/github_release_download.py",
            "scripts/ci/deadline_http.py",
            "scripts/web-lint.sh",
            "scripts/merge-xcstrings.py",
            "scripts/merge-pbxproj.py",
            "scripts/merge-baseline.py",
            "scripts/merge-daemon-capabilities.py",
            "scripts/merge-insertions.py",
            "scripts/ci/merge_main_resolver.py",
            "scripts/ci/validate_test_execution_registry.py",
            "scripts/ci/test_execution_registry.py",
            "scripts/ci/workload_entrypoints.py",
            "scripts/normalize-pbxproj.py",
            "scripts/swift_source_mask.py",
            # The What's New validator the highlights layer runs (origin/feat-cmux-next's copy for the hook).
            "scripts/whats-new/digest.py",
            "scripts/whats-new/validate.py",
            *checks,
        ):
            source, target = SOURCE / relative, self.repo / relative
            if not source.exists():
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copyfile(source, target)
                shutil.copymode(source, target)

    def git(self, *args, check=True):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env,
                              text=True, capture_output=True, check=check)

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--no-verify", "-m", message)

    def push(self, **env):
        return subprocess.run(["git", "-C", str(self.repo), "push", "origin", "feat-cmux-next"],
                              env={**self.env, **env}, text=True, capture_output=True)

    def remote_head(self):
        return subprocess.run(["git", "-C", str(self.origin), "rev-parse", "feat-cmux-next"],
                              env=self.env, text=True, capture_output=True).stdout.strip()

    def remote_head_of(self, ref):
        return subprocess.run(["git", "-C", str(self.origin), "rev-parse", ref],
                              env=self.env, text=True, capture_output=True).stdout.strip()

    def push_ref(self, ref, *flags, **env):
        return subprocess.run(["git", "-C", str(self.repo), "push", *flags, "origin", ref],
                              env={**self.env, **env}, text=True, capture_output=True)

    def test_a_push_that_changes_the_perf_cron_never_runs_its_tests_in_the_hook(self):
        # The hook never runs code the push controls (docs/contributor-verification.md, trust boundary). The perf
        # cron's unit tests are the pushed head's own code, so the hook names them and the command to run them on
        # code the person trusts; it never runs them, whatever they hold.
        marker = self.root / "pushed-code-ran"
        self.write("scripts/cmux-next/perf-cron.py", "VALUE = 1\n")
        self.write("scripts/cmux-next/tests/test_perf_cron.py",
                   f"import unittest\nopen({str(marker)!r}, 'w').close()\n"
                   "class T(unittest.TestCase):\n    def test_ok(self):\n        pass\n")
        self.commit("change the perf cron")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists(), "the hook ran the pushed head's perf cron tests")
        self.assertIn("perf cron", result.stderr)
        self.assertIn("python3 -I -m unittest discover -s scripts/cmux-next/tests -p 'test_perf_cron*.py'",
                      result.stderr, "must say how to run them")

    def test_the_hook_names_each_phase_time_and_what_to_do_next(self):
        # 2026-11-09 (push-reliability): pushes took 34-98 s, and an agent could not tell a slow hook from a slow
        # git or GitHub. The hook prints each phase's time and its total, then says what a failure after it means.
        self.kit("Fresh", NEW_CLEAN)
        self.commit("clean")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        times = [line for line in result.stderr.splitlines() if line.startswith("pre-push: hook times: ")]
        self.assertEqual(len(times), 1, result.stderr)
        for phase in ("fast-tier", "web-lint", "cmux-next-gate", "base-merge-warning", "total"):
            self.assertIn(phase, times[0])
        self.assertIn("a failure after this line is git or GitHub", result.stderr)
        self.assertIn("Retry a failed push", result.stderr)

        self.kit("Refused", self.with_try("Refused"))
        self.commit("adds a try!")

        result = self.push()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        times = [line for line in result.stderr.splitlines() if line.startswith("pre-push: hook times: ")]
        self.assertEqual(len(times), 1, result.stderr)
        self.assertIn("cmux-next-gate", times[0], "the phase that refused is named with its time")
        self.assertIn("pre-push: refused in cmux-next-gate", result.stderr)
        self.assertIn("do not retry", result.stderr)

    def test_a_ui_font_check_stopped_by_its_read_guard_refuses_the_push(self):
        # Review of #39838: the check stops ("reads X, which is not in INPUTS") on a read outside INPUTS. The base pass
        # and the head pass print the same line, so the gate's base/head diff hid it, and the push went through with
        # the check not run. The gate must refuse with the guard's message.
        snapshot = Path(self.git("config", "--get", "core.hooksPath").stdout.strip()) / "cmux-next-checks"
        installed = snapshot.resolve() / "check-ui-font.py"
        entry = "def check_tree(tree: Tree) -> list[str]:\n"
        text = installed.read_text()
        self.assertIn(entry, text)
        installed.write_text(text.replace(entry, entry + '    tree.read("README.md")\n', 1))
        before = self.remote_head()
        self.write("webviews/src/pages/shared/desktop.css", "/* a webviews change */\n")
        self.commit("a webviews change")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn("README.md, which is not in INPUTS", output)

    def test_the_ui_font_check_runs_only_on_a_push_that_changes_what_it_reads(self):
        # 2026-11-09 (push-reliability): check-ui-font.py reads every webviews/src and Native/OptChat source at the
        # base and again at the head (4268 files on feat-cmux-next). On a push that changed one Python file it took
        # 9.6 s of the gate's 18.8 s, and in this blob:none clone each source blob the clone lacks costs one
        # on-demand fetch (5-8 s measured, 16 missing at the feat tip). A push that changes none of the files it
        # reads cannot change what it finds.
        snapshot = Path(self.git("config", "--get", "core.hooksPath").stdout.strip()) / "cmux-next-checks"
        installed = snapshot.resolve() / "check-ui-font.py"
        runs = self.root / "ui-font-runs"
        # The marker is in check_tree, so it counts the check's passes, not the gate asking it what it reads.
        entry = "def check_tree(tree: Tree) -> list[str]:\n"
        text = installed.read_text()
        self.assertIn(entry, text)
        installed.write_text(text.replace(entry, f"{entry}    open({str(runs)!r}, 'a').write('ran\\n')\n", 1))
        self.kit("Fresh", NEW_CLEAN)
        self.commit("a Swift change only")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(runs.exists(), "the hook ran the UI font check on a push that changes none of its inputs")

        self.write("webviews/src/pages/shared/desktop.css", "/* a webviews change */\n")
        self.commit("a webviews change")

        result = self.push()

        self.assertTrue(runs.exists(), "a push that changes a file the UI font check reads must run it\n"
                        + result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)  # the next push holds only its own change

        # A push that changes the check itself runs it too (review of #39765).
        runs.unlink()
        self.write("scripts/cmux-next/check-ui-font.py",
                   (self.repo / "scripts/cmux-next/check-ui-font.py").read_text() + "\n# a change to the check\n")
        self.commit("a change to the UI font check only")

        result = self.push()

        self.assertTrue(runs.exists(), "a push that changes check-ui-font.py must run it\n"
                        + result.stdout + result.stderr)

    def kit(self, name, text):
        self.write(f"{PKG}/Sources/CmuxNextKit/{name}.swift", text)

    def with_try(self, name):
        return NEW_WITH_TRY.replace("Fresh", name)

    def base_gains_debt(self, extra=""):
        """Someone else lands a try! (and EXTRA) on feat-cmux-next past the hook (--no-verify); this clone
        fetches it."""
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.kit("BaseDebt", self.with_try("BaseDebt") + extra)
        self.commit("someone else's debt on the base")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")

    def pushed_topic(self, text):
        """A topic branch pushed once past the hook, its one commit carrying TEXT in Earlier.swift."""
        self.git("checkout", "--quiet", "-b", "topic")
        self.kit("Earlier", text)
        self.commit("topic work pushed before")
        first = self.push_ref("topic", "--no-verify")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)

    def test_a_rebased_branch_is_judged_on_its_own_commits_not_the_base_it_moved_onto(self):
        # A branch pushed once on the old base, then rebased onto a base that gained debt (a try! someone else
        # pushed with --no-verify). The remote head is still the pre-rebase commit: its merge base with the new
        # head is the old base, so a range from there would judge the base commits the rebase brought in.
        self.pushed_topic(APP.replace("CmuxNextApp", "Earlier"))
        self.base_gains_debt()
        self.git("checkout", "--quiet", "topic")
        self.kit("Topic", self.with_try("Topic"))
        self.commit("the branch's own try!")
        self.git("rebase", "--quiet", "origin/feat-cmux-next")
        self.assertNotEqual(self.git("merge-base", "HEAD", self.remote_head_of("topic")).stdout.strip(),
                            self.git("rev-parse", "origin/feat-cmux-next").stdout.strip(),
                            "control: the remote head sits on the old base")

        refused = self.push_ref("topic", "--force")

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("Topic.swift", output, "the rebased commit's own try! is judged")
        self.assertNotIn("BaseDebt.swift", output, "a base commit the rebase brought in is not the branch's")

        self.git("reset", "--quiet", "--hard", "HEAD~1")  # the same rebase without the branch's own try!

        clean = self.push_ref("topic", "--force")

        output = clean.stdout + clean.stderr
        self.assertEqual(clean.returncode, 0, output)
        self.assertNotIn("BaseDebt.swift", output)

    def test_a_force_push_over_a_remote_head_this_clone_does_not_have_is_bounded_by_the_tracking_ref(self):
        # The branch pushed debt once (Earlier.swift); another clone then force pushed the branch, and this clone
        # never fetched it. This clone's tracking ref still says the remote had Earlier.swift's commit.
        self.pushed_topic(self.with_try("Earlier"))
        other = self.root / "other"
        subprocess.run(["git", "clone", "--quiet", "--branch", "topic", str(self.origin), str(other)], env=self.env,
                       check=True, capture_output=True)
        (other / "README").write_text("rewritten elsewhere\n")
        for args in (("add", "-A"), ("commit", "--quiet", "--no-verify", "--amend", "-m", "rewritten elsewhere"),
                     ("push", "--quiet", "--no-verify", "--force", "origin", "topic")):
            subprocess.run(["git", "-C", str(other), *args], env=self.env, check=True, capture_output=True)
        self.assertNotEqual(self.remote_head_of("topic"), self.git("rev-parse", "origin/topic").stdout.strip())
        self.kit("New", self.with_try("New"))
        self.commit("the push's own try!")

        refused = self.push_ref("topic", "--force")

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("New.swift", output)
        self.assertNotIn("Earlier.swift", output, "the tracking ref says the remote had that commit")
        self.assertIn("is not in this clone", output)

    def test_a_first_push_of_two_commits_without_the_upstream_ref_judges_both(self):
        # A clone without origin/feat-cmux-next (a single-branch clone of another branch): the first push of a new
        # branch is bounded by the remote's other refs, never by HEAD~1 alone.
        self.pushed_topic(APP.replace("CmuxNextApp", "Earlier"))
        self.git("update-ref", "-d", "refs/remotes/origin/feat-cmux-next")
        self.git("checkout", "--quiet", "-b", "fresh", "feat-cmux-next")
        self.kit("First", self.with_try("First"))
        self.commit("first commit, with the debt")
        self.kit("Second", NEW_CLEAN.replace("Fresh", "Second"))
        self.commit("second commit, clean")

        result = self.push_ref("fresh")

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("First.swift", output, "the first of a new branch's two commits is the push's own")
        self.assertIn("2 own commit(s)", output)

    def test_a_push_nothing_bounds_is_refused_with_what_to_fetch(self):
        # No ref of the remote at all in this clone: the gate cannot tell the push's own commits, so it refuses
        # on purpose (one line per ref, no traceback) instead of judging HEAD~1 alone.
        for ref in self.git("for-each-ref", "--format=%(refname)", "refs/remotes/").stdout.split():
            self.git("update-ref", "-d", ref)
        self.git("checkout", "--quiet", "-b", "fresh")
        self.kit("First", self.with_try("First"))
        self.commit("first commit, with the debt")
        self.kit("Second", NEW_CLEAN.replace("Fresh", "Second"))
        self.commit("second commit, clean")

        result = self.push_ref("fresh")

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("cannot tell which commits are this push's own", output)
        self.assertIn("git fetch origin", output)
        self.assertNotIn("Traceback", output)

    def test_a_snapshot_without_push_range_refuses_the_push_and_says_how_to_fix_it(self):
        snapshot = Path(self.git("config", "--get", "core.hooksPath").stdout.strip()) / "cmux-next-checks"
        (snapshot.resolve() / "push_range.py").unlink()
        self.kit("Fresh", NEW_CLEAN)
        self.commit("clean")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("push_range.py is missing; rerun scripts/install-git-hooks.sh", output)
        self.assertNotIn("Traceback", output)

    STALE = "the installed hook is older than the checks this push needs: rerun scripts/install-git-hooks.sh"

    def test_a_stale_install_refuses_and_never_runs_the_pushed_check(self):
        # The hook never runs code the push controls. A reviewed copy older than a check must refuse with how to fix
        # it, never fall back to the pushed head's copy of that check.
        snapshot = Path(self.git("config", "--get", "core.hooksPath").stdout.strip()) / "cmux-next-checks"
        marker = self.root / "pushed-code-ran"
        payload = f"open({str(marker)!r}, 'w').close()\n"
        self.write("schemas/keybindings/ghostty-reserved-keys.json", "[]\n")
        self.write("plans/cmux-next/action-surfaces.json", "{}\n")
        self.commit("reserved-key data")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        for number, name in enumerate(("check-ui-font.py", "check-ghostty-reserved-keys.py")):
            with self.subTest(name=name):
                installed = snapshot.resolve() / name
                if installed.exists():
                    installed.unlink()
                self.write(f"scripts/cmux-next/{name}", payload)
                self.kit(f"Stale{number}", NEW_CLEAN.replace("Fresh", f"Stale{number}"))
                self.commit(f"a pushed {name}")
                before = self.remote_head()

                result = self.push()

                output = result.stdout + result.stderr
                self.assertFalse(marker.exists(), f"the hook ran the pushed {name}")
                self.assertNotEqual(result.returncode, 0, output)
                self.assertEqual(self.remote_head(), before)
                self.assertIn(self.STALE, output)
                self.assertNotIn("Traceback", output)

    def test_a_stale_install_never_takes_the_tool_pins_from_the_checkout(self):
        # Review of 9b89be5eefd: an install with no lint-tools.lock read the checkout's (the pushed branch) and
        # downloaded and ran the binary that lock names; its sha256 proves nothing, it comes from the same lock.
        snapshot = Path(self.git("config", "--get", "core.hooksPath").stdout.strip()) / "cmux-next-checks"
        (snapshot.resolve() / "lint-tools.lock").unlink()
        marker = self.root / "pushed-code-ran"
        tools = self.root / "tools"  # a fresh tools folder, so no pinned binary already there answers instead
        payload = self.root / "payload"
        payload.mkdir()
        import hashlib
        import zipfile
        binary = payload / "ast-grep"
        binary.write_text(f"#!/bin/sh\ntouch {marker}\n")
        archive = payload / "tool.zip"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.write(binary, "ast-grep")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        gate = load_gate_tools()
        rows = "".join(f"{tool}\t9.9.9\t{gate.platform_key()}\t{archive.as_uri()}\t{digest}\t{tool}\n"
                       for tool in ("ast-grep", "swiftformat", "swiftlint"))
        self.write("scripts/cmux-next/lint-tools.lock", "# tool\tversion\tplatform\turl\tsha256\tbinary-in-zip\n" + rows)
        self.kit("Pinned", NEW_CLEAN.replace("Fresh", "Pinned"))
        self.commit("a pushed lock and a Swift change")
        before = self.remote_head()

        result = self.push(CMUX_LINT_TOOLS_DIR=str(tools))

        output = result.stdout + result.stderr
        self.assertFalse(marker.exists(), "the hook ran a binary the pushed lock named")
        self.assertFalse(tools.exists() and any(tools.iterdir()), "the hook downloaded what the pushed lock named")
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn(self.STALE, output)
        self.assertNotIn("Traceback", output)

    def test_a_merge_cannot_use_an_upstream_removal_to_pay_for_the_branch_s_own_debt(self):
        # Upstream removes a try! and a main hop from Shared.swift; the branch adds a try! of the same text and a
        # main hop to Shared.swift and merges upstream in. Over the old remote head the removals pay for both
        # (a per-file count, the same text); they are upstream's, so the push must be refused.
        self.kit("Shared", SHARED.format(debt=SHARED_DEBT, more=""))
        self.commit("shared file with debt")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.pushed_topic(APP.replace("CmuxNextApp", "Earlier"))
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.kit("Shared", SHARED.format(debt="", more=""))
        self.commit("upstream removes the try! and the main hop")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.git("checkout", "--quiet", "topic")
        self.kit("Shared", SHARED.format(debt=SHARED_DEBT, more=SHARED_MORE))
        self.commit("the branch's own try! and main hop in Shared.swift")
        self.git("merge", "--quiet", "--no-edit", "--no-ff", "origin/feat-cmux-next")
        self.assertNotIn("DispatchQueue.main.async { print(1) }",
                         (self.repo / PKG / "Sources/CmuxNextKit/Shared.swift").read_text(), "control: upstream's removal")

        refused = self.push_ref("topic")

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("Shared.swift", output)
        self.assertIn("try!", output)
        self.assertIn("[main-async]", output)

    def test_a_second_push_judges_every_new_commit_and_nothing_pushed_before(self):
        self.pushed_topic(self.with_try("Earlier"))  # debt this branch pushed before (a skip reason, an old hook)
        self.kit("First", self.with_try("First"))
        self.commit("first new commit")
        self.kit("Second", self.with_try("Second"))
        self.commit("second new commit")

        result = self.push_ref("topic")

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("First.swift", output, "the first of two new commits is the push's own")
        self.assertIn("Second.swift", output)
        self.assertNotIn("Earlier.swift", output, "a commit the remote already has is not judged again")
        self.assertIn("2 own commit(s)", output)

    def test_a_second_push_without_the_upstream_tracking_ref_judges_every_new_commit(self):
        # A clone that lost origin/feat-cmux-next (a single-branch clone, a remote named otherwise, a ref never
        # fetched): the branch's remote head still bounds the push.
        self.pushed_topic(self.with_try("Earlier"))
        self.git("update-ref", "-d", "refs/remotes/origin/feat-cmux-next")
        self.kit("First", self.with_try("First"))
        self.commit("first new commit")
        self.kit("Second", NEW_CLEAN.replace("Fresh", "Second"))
        self.commit("second new commit, clean")

        result = self.push_ref("topic")

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("First.swift", output, "the first of two new commits is the push's own")
        self.assertNotIn("Earlier.swift", output)

    def test_a_branch_that_merges_feat_cmux_next_in_is_judged_on_its_own_changes(self):
        # Debt for the scanners (try!) and for the guardrails (a main hop) on all three sides: pushed before by
        # the branch, landed upstream, and added by the merge itself. Only the merge's own is the push's.
        self.pushed_topic(self.with_try("Earlier") + MAIN_HOP.replace("hop", "earlierHop"))
        self.base_gains_debt(MAIN_HOP.replace("hop", "baseHop"))
        self.git("checkout", "--quiet", "topic")
        self.git("merge", "--quiet", "--no-ff", "--no-commit", "origin/feat-cmux-next")
        self.kit("Merged", self.with_try("Merged") + MAIN_HOP.replace("hop", "mergedHop"))
        self.git("add", "-A")
        self.git("commit", "--quiet", "--no-verify", "--no-edit")

        refused = self.push_ref("topic")

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("Merged.swift", output, "a violation the merge itself adds is the push's own")
        self.assertNotIn("BaseDebt.swift", output, "upstream's debt only comes in through the merge")
        self.assertNotIn("Earlier.swift", output, "the branch pushed that before")
        self.assertIn("[main-async]", output, "the guardrails judge the merge's own lines too")
        self.assertIn("a merge", output)

        self.git("rm", "--quiet", f"{PKG}/Sources/CmuxNextKit/Merged.swift")
        self.git("commit", "--quiet", "--no-verify", "--amend", "--no-edit")

        clean = self.push_ref("topic")

        output = clean.stdout + clean.stderr
        self.assertEqual(clean.returncode, 0, output)
        self.assertNotIn("BaseDebt.swift", output)
        self.assertNotIn("Earlier.swift", output)

    def test_a_merge_does_not_judge_again_debt_pushed_before_when_upstream_moves_its_lines(self):
        # The branch pushed a try! and a main hop into Shared.swift (past the hook); upstream then adds lines
        # above them. After the merge the old debt sits on other line numbers: it is still not the push's.
        self.kit("Shared", SHARED.format(debt="", more=""))
        self.commit("shared file")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.git("checkout", "--quiet", "-b", "topic")
        self.kit("Shared", SHARED.format(debt="", more=SHARED_MORE))
        self.commit("debt pushed before")
        first = self.push_ref("topic", "--no-verify")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.kit("Shared", SHARED.format(debt="    let upstream = 1\n    let more = 2\n    let lines = 3\n", more=""))
        self.commit("upstream adds lines above")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.git("checkout", "--quiet", "topic")
        self.git("merge", "--quiet", "--no-edit", "--no-ff", "origin/feat-cmux-next")
        self.kit("Fresh", NEW_CLEAN)
        self.commit("clean new work")

        result = self.push_ref("topic")

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("a merge", output)

    def test_a_branch_that_merged_an_extra_upstream_is_judged_on_what_it_adds_over_it(self):
        # A long-lived shared branch on the remote (perf/x) carries a try! pushed past the hook; a task branch
        # merges it in. Unset, cmux.prepushExtraUpstream changes nothing: perf/x's commit is the push's own. Set
        # to origin/perf/x, it is a shared base like origin/feat-cmux-next, and only the task's own work counts.
        self.git("checkout", "--quiet", "-b", "perf/x")
        self.kit("PerfDebt", self.with_try("PerfDebt"))
        self.commit("the shared perf branch's debt")
        self.assertEqual(self.push_ref("perf/x", "--no-verify").returncode, 0)
        self.git("fetch", "--quiet", "origin")
        self.git("checkout", "--quiet", "-b", "task", "origin/feat-cmux-next")
        self.kit("Fresh", NEW_CLEAN)
        self.commit("clean task work")
        self.git("merge", "--quiet", "--no-edit", "--no-ff", "origin/perf/x")

        unset = self.push_ref("task")

        output = unset.stdout + unset.stderr
        self.assertNotEqual(unset.returncode, 0, output)
        self.assertIn("PerfDebt.swift", output, "unset: the merged shared branch's commits count as the push's")
        self.assertNotEqual(self.git("ls-remote", "--exit-code", "origin", "refs/heads/task", check=False).returncode, 0)

        self.git("config", "--add", "cmux.prepushExtraUpstream", "origin/perf/x")

        extra = self.push_ref("task")

        output = extra.stdout + extra.stderr
        self.assertEqual(extra.returncode, 0, output)
        self.assertNotIn("PerfDebt.swift", output)
        self.assertNotIn("installed hook copy", output, "the tracked push_range.py reads the setting: no patch")
        self.assertEqual(self.remote_head_of("refs/heads/task"), self.git("rev-parse", "task").stdout.strip())

    def pre_push_extra(self, name, status):
        """An executable outside the checkout that records its arguments and stdin, then exits with STATUS."""
        record = self.root / f"{name}.record"
        script = self.root / name
        script.write_text(f'#!/bin/sh\nprintf "%s|%s|%s\\n" "$1" "$2" "$PWD" > {record}\ncat >> {record}\nexit {status}\n')
        script.chmod(0o755)
        return script, record

    def test_a_hook_stopped_by_a_signal_during_a_check_never_says_it_passed(self):
        # Review of #39787: bash runs the EXIT trap when SIGTERM or SIGINT kills it, but $? there is the last
        # command's status (0), so a hook stopped in the middle of a check printed "pre-push: passed". The extra
        # writes the hook's pid into a FIFO (its open blocks until the test reads it, so the hook is inside the check)
        # and then blocks on a second FIFO that is never written.
        self.kit("Fresh", NEW_CLEAN)
        self.commit("clean")
        before = self.remote_head()
        pid_fifo, never = self.root / "hook-pid", self.root / "never"
        os.mkfifo(pid_fifo)
        os.mkfifo(never)
        extra = self.root / "blocks"
        extra.write_text(f'#!/bin/sh\necho "$PPID" > {pid_fifo}\nexec cat {never}\n')
        extra.chmod(0o755)
        self.git("config", "--add", "cmux.prePushExtra", str(extra))
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum.name):
                push = subprocess.Popen(["git", "-C", str(self.repo), "push", "origin", "feat-cmux-next"],
                                        env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                got: list[str] = []
                reader = threading.Thread(target=lambda: got.append(pid_fifo.read_text()), daemon=True)
                reader.start()
                reader.join(timeout=120)
                if not got:
                    push.kill()
                    self.fail("the hook never reached the clone-local extra:\n" + "".join(push.communicate()))
                hook = int(got[0].strip())
                rows = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], text=True, capture_output=True).stdout
                children = [int(p) for p, pp in (r.split() for r in rows.splitlines() if len(r.split()) == 2)
                            if int(pp) == hook]
                for pid in (hook, *children):  # as a terminal's Ctrl-C or a process-group kill reaches both
                    os.kill(pid, signum)
                out, err = push.communicate(timeout=120)

                self.assertNotEqual(push.returncode, 0, out + err)
                self.assertEqual(self.remote_head(), before)
                self.assertNotIn("pre-push: passed", err, "a hook stopped in a check must not say it passed")
                self.assertIn("pre-push: refused in extras", err)

    def test_clone_local_pre_push_extras_run_with_the_pushed_refs_and_a_failure_refuses_the_push(self):
        self.kit("Fresh", NEW_CLEAN)
        self.commit("clean")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        before = self.remote_head()
        passes, passed = self.pre_push_extra("passes", 0)
        refuses, refused_record = self.pre_push_extra("refuses", 3)
        self.git("config", "--add", "cmux.prePushExtra", str(passes))
        self.git("config", "--add", "cmux.prePushExtra", str(refuses))

        refused = self.push()

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn(f"cmux.prePushExtra {refuses} refused the push (exit 3)", output)
        for record in (passed, refused_record):  # each extra, in order, got the remote, its URL, the top and refs
            lines = record.read_text().splitlines()
            self.assertEqual(lines[0], f"origin|{self.origin}|{self.repo.resolve()}")
            self.assertEqual(lines[1], f"refs/heads/feat-cmux-next {head} refs/heads/feat-cmux-next {before}")

        self.git("config", "--unset-all", "cmux.prePushExtra")
        self.git("config", "--add", "cmux.prePushExtra", str(passes))

        allowed = self.push()

        output = allowed.stdout + allowed.stderr
        self.assertEqual(allowed.returncode, 0, output)
        self.assertEqual(self.remote_head(), head)
        self.assertNotIn("installed hook copy", output, "the tracked hook runs the extras: no patched copy")

    def test_a_pre_push_extra_that_is_relative_or_not_executable_refuses_the_push(self):
        self.kit("Fresh", NEW_CLEAN)
        self.commit("clean")
        before = self.remote_head()
        script, record = self.pre_push_extra("check", 0)
        script.chmod(0o644)
        (self.repo / "check").write_text(script.read_text())  # a checkout path never runs
        (self.repo / "check").chmod(0o755)
        for value, why in (("check", "is not an absolute path"), (str(script), "is not an executable file")):
            self.git("config", "--unset-all", "cmux.prePushExtra", check=False)
            self.git("config", "--add", "cmux.prePushExtra", value)

            pushed = self.push()

            output = pushed.stdout + pushed.stderr
            self.assertNotEqual(pushed.returncode, 0, output)
            self.assertIn(why, output)
            self.assertEqual(self.remote_head(), before)
            self.assertFalse(record.exists(), "the extra never ran")

    def remote_branch(self, name, text=None):
        """Branch NAME on the remote (pushed past the hook), with a commit that adds TEXT (a clean file by default)."""
        self.git("checkout", "--quiet", "-b", name, "origin/feat-cmux-next")
        kind = name.title().replace("-", "")
        self.kit(kind, text or NEW_CLEAN.replace("Fresh", kind))
        self.commit(f"{name} work")
        self.assertEqual(self.push_ref(name, "--no-verify").returncode, 0)
        self.git("checkout", "--quiet", "feat-cmux-next")
        return self.remote_head_of(f"refs/heads/{name}")

    def remote_has(self, ref):
        return subprocess.run(["git", "-C", str(self.origin), "show-ref", "--verify", "--quiet", ref],
                              env=self.env).returncode == 0

    def test_a_delete_only_push_passes_from_a_clone_without_a_work_tree(self):
        # 2026-11-01: the tip watcher's `git -C /work/cmux push origin :refs/heads/x` (a core.bare clone root,
        # no work tree) died in the hook with "this operation must be run in a work tree" 738 times. A delete
        # sends no commits; nothing in the hook has anything to check.
        for name in ("stale-a", "stale-b"):
            self.remote_branch(name)
        self.git("config", "core.bare", "true")

        one = self.push_ref(":refs/heads/stale-a")

        output = one.stdout + one.stderr
        self.assertEqual(one.returncode, 0, output)
        self.assertNotIn("work tree", output)
        self.assertFalse(self.remote_has("refs/heads/stale-a"), "the branch is gone")

        # Two deletes in one push (`git push --delete origin a b`): every line is a delete, so it passes too.
        self.git("config", "core.bare", "false")
        self.remote_branch("stale-c")
        self.git("config", "core.bare", "true")
        two = subprocess.run(["git", "-C", str(self.repo), "push", "--delete", "origin", "stale-b", "stale-c"],
                             env=self.env, text=True, capture_output=True)

        output = two.stdout + two.stderr
        self.assertEqual(two.returncode, 0, output)
        for name in ("stale-b", "stale-c"):
            self.assertFalse(self.remote_has(f"refs/heads/{name}"), name)

    def test_a_push_with_any_real_ref_still_runs_every_check(self):
        # The delete-only pass must not reach a push that also sends commits: a delete next to a real ref, or a
        # real ref alone, still runs the gate and is refused for the try! it adds.
        doomed = self.remote_branch("doomed")
        before = self.remote_head()
        self.kit("Fresh", NEW_WITH_TRY)
        self.commit("adds a try!")

        for refs in ((":refs/heads/doomed", "feat-cmux-next"), ("feat-cmux-next",)):
            pushed = subprocess.run(["git", "-C", str(self.repo), "push", "--atomic", "origin", *refs],
                                    env=self.env, text=True, capture_output=True)

            output = pushed.stdout + pushed.stderr
            self.assertNotEqual(pushed.returncode, 0, f"{refs}: {output}")
            self.assertIn("Fresh.swift", output, refs)
            self.assertIn("try!", output, refs)
            self.assertEqual(self.remote_head(), before, refs)
            self.assertEqual(self.remote_head_of("refs/heads/doomed"), doomed, f"{refs}: the hook refused the delete too")

    def long_lived_branch(self, name, debt):
        """A long-lived integration branch NAME on the remote, three commits ahead of feat-cmux-next (its own merge
        train), the first carrying a try! in DEBT.swift (pushed past the hook); this clone fetches it."""
        self.git("checkout", "--quiet", "-b", name, "origin/feat-cmux-next")
        self.kit(debt, self.with_try(debt))
        self.commit(f"{name}: debt landed on its own train")
        for index in range(2):
            self.kit(f"{debt}Clean{index}", NEW_CLEAN.replace("Fresh", f"{debt}Clean{index}"))
            self.commit(f"{name}: more of its train")
        self.git("push", "--quiet", "--no-verify", "origin", name)
        self.git("fetch", "--quiet", "origin")
        self.git("checkout", "--quiet", "feat-cmux-next")

    def topic_from(self, start, *flags):
        """Branch `topic` cut from START (git checkout -b topic FLAGS START) with one commit adding a try!."""
        self.git("checkout", "--quiet", "-b", "topic", *flags, start)
        self.kit("Topic", self.with_try("Topic"))
        self.commit("the branch's own try!")

    def test_a_branch_cut_from_the_perf_integration_branch_is_judged_only_over_its_own_commits(self):
        # origin/perf/chrome-parity runs far ahead of feat-cmux-next with debt of its own (2026-10-29: one agent's
        # push was judged over 9,426 perf commits and refused for files it never touched). No upstream is set
        # (--no-track): the known integration refs bound the walk.
        self.long_lived_branch("perf/chrome-parity", "PerfDebt")
        self.topic_from("origin/perf/chrome-parity", "--no-track")

        refused = self.push_ref("topic")

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("Topic.swift", output, "the branch's own try! is judged")
        self.assertNotIn("PerfDebt.swift", output, "perf's own debt is not the branch's")
        self.assertIn(" 1 own commit(s); cut from origin/perf/chrome-parity", output)

        self.git("reset", "--quiet", "--hard", "HEAD~1")
        self.kit("Topic", NEW_CLEAN.replace("Fresh", "Topic"))
        self.commit("clean work on perf")

        clean = self.push_ref("topic")

        output = clean.stdout + clean.stderr
        self.assertEqual(clean.returncode, 0, output)
        self.assertNotIn("PerfDebt.swift", output)

    def test_a_branch_tracking_any_long_lived_remote_branch_is_judged_over_its_upstream(self):
        # A long-lived branch no list names: the branch's configured upstream (git worktree add -b topic
        # origin/release/train sets it) is a fact of where it was cut from.
        self.long_lived_branch("release/train", "TrainDebt")
        self.topic_from("origin/release/train", "--track")
        self.assertEqual(self.git("rev-parse", "--symbolic-full-name", "topic@{upstream}").stdout.strip(),
                         "refs/remotes/origin/release/train", "control: the branch tracks the train")

        refused = self.push_ref("topic")

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("Topic.swift", output)
        self.assertNotIn("TrainDebt.swift", output, "the train's debt is not the branch's")
        self.assertIn(" 1 own commit(s)", output)
        self.assertIn("origin/release/train", output, "the report names the upstream that bounds the push")

    def test_a_branch_with_no_known_base_is_still_judged_over_feat_cmux_next(self):
        # Cut from a remote branch that is neither its upstream nor a known integration ref: no base is found,
        # so the push is judged over origin/feat-cmux-next as before, never given a free pass.
        self.long_lived_branch("release/train", "TrainDebt")
        self.topic_from("origin/release/train", "--no-track")

        refused = self.push_ref("topic")

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("Topic.swift", output)
        self.assertIn("TrainDebt.swift", output, "with no known base the train's commits count as the push's")
        self.assertIn(" 4 own commit(s)", output)

    def test_an_upstream_that_is_a_local_branch_bounds_nothing(self):
        # A local branch's commits are not on the remote: tracking one (git branch --track) must not hide them.
        self.git("checkout", "--quiet", "-b", "local-train")
        self.kit("LocalDebt", self.with_try("LocalDebt"))
        self.commit("debt that was never pushed")
        self.topic_from("local-train", "--track")
        self.assertEqual(self.git("rev-parse", "--symbolic-full-name", "topic@{upstream}").stdout.strip(),
                         "refs/heads/local-train", "control: the upstream is a local branch")

        refused = self.push_ref("topic")

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("LocalDebt.swift", output, "an unpushed upstream's commits are the push's own")
        self.assertIn(" 2 own commit(s)", output)

    def test_an_upstream_on_another_remote_bounds_nothing(self):
        # A branch cut from a contributor's fork (git checkout -b topic fork/contrib) pushed to origin: the fork's
        # commits are not on origin, so they are the push's own.
        fork = self.root / "fork.git"
        subprocess.run(["git", "init", "--quiet", "--bare", str(fork)], env=self.env, check=True, capture_output=True)
        self.git("remote", "add", "fork", str(fork))
        self.git("checkout", "--quiet", "-b", "contrib")
        self.kit("ForkDebt", self.with_try("ForkDebt"))
        self.commit("a contributor's debt, never on origin")
        self.git("push", "--quiet", "--no-verify", "fork", "contrib")
        self.git("fetch", "--quiet", "fork")
        self.topic_from("fork/contrib", "--track")
        self.assertEqual(self.git("rev-parse", "--symbolic-full-name", "topic@{upstream}").stdout.strip(),
                         "refs/remotes/fork/contrib", "control: the upstream is on another remote")

        refused = self.push_ref("topic")

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("ForkDebt.swift", output, "another remote's commits are the push's own")
        self.assertIn(" 2 own commit(s)", output)

    def test_an_extra_upstream_bounds_nothing_on_a_push_onto_an_integration_branch(self):
        # cmux.prepushExtraUpstream is a cut-from ref like the configured upstream: landing perf onto
        # feat-cmux-next is judged over feat-cmux-next whatever the setting names (review of the #28493 merge).
        self.long_lived_branch("perf/x", "PerfDebt")
        self.git("merge", "--quiet", "--no-ff", "--no-edit", "origin/perf/x")
        self.git("config", "--add", "cmux.prepushExtraUpstream", "origin/perf/x")

        refused = self.push()

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("PerfDebt.swift", output, "what perf lands on feat-cmux-next is judged")

    def test_an_extra_upstream_that_is_not_a_ref_of_the_pushed_remote_bounds_nothing(self):
        # A local branch nobody pushed (or another remote's ref, a URL push, a raw sha) never hides its commits.
        self.git("checkout", "--quiet", "-b", "local-x")
        self.kit("LocalDebt", self.with_try("LocalDebt"))
        self.commit("never pushed")
        self.git("checkout", "--quiet", "-b", "task", "origin/feat-cmux-next")
        self.kit("Fresh", NEW_CLEAN)
        self.commit("clean task work")
        self.git("merge", "--quiet", "--no-ff", "--no-edit", "local-x")
        self.git("config", "--add", "cmux.prepushExtraUpstream", "local-x")

        refused = self.push_ref("task")

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("LocalDebt.swift", output, "a local branch's commits are the push's own")

    def test_landing_perf_onto_feat_cmux_next_is_judged_over_feat_cmux_next(self):
        # A push onto the integration branch itself (the perf train landing on feat-cmux-next) is judged over
        # feat-cmux-next as before: perf's commits are what it lands.
        self.long_lived_branch("perf/chrome-parity", "PerfDebt")
        self.git("merge", "--quiet", "--no-ff", "--no-edit", "origin/perf/chrome-parity")

        manual = subprocess.run(["python3", "-I", GATE], cwd=self.repo, env=self.env, text=True, capture_output=True)

        output = manual.stdout + manual.stderr
        self.assertNotEqual(manual.returncode, 0, output)
        self.assertIn("PerfDebt.swift", output, "a manual run on feat-cmux-next reads what its push will")
        self.assertNotIn("cut from", output)

        refused = self.push()

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("PerfDebt.swift", output, "what perf lands on feat-cmux-next is judged")
        self.assertNotIn("cut from", output)

    def test_an_ordinary_branch_report_names_no_integration_ref(self):
        # perf exists in the clone but this branch left feat-cmux-next: the report reads as before.
        self.long_lived_branch("perf/chrome-parity", "PerfDebt")
        self.topic_from("origin/feat-cmux-next", "--track")

        refused = self.push_ref("topic")

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("Topic.swift", output)
        self.assertIn(" 1 own commit(s)", output)
        self.assertNotIn("cut from", output)
        self.assertNotIn("perf/chrome-parity", output)

    def test_a_base_given_on_the_command_line_wins_over_the_branch_s_integration_base(self):
        self.long_lived_branch("perf/chrome-parity", "PerfDebt")
        self.topic_from("origin/perf/chrome-parity", "--track")
        run = lambda *args: subprocess.run(["python3", "-I", GATE, *args], cwd=self.repo,
                                           env=self.env, text=True, capture_output=True)

        inferred = run()

        output = inferred.stdout + inferred.stderr
        self.assertNotEqual(inferred.returncode, 0, output)
        self.assertIn("Topic.swift", output)
        self.assertNotIn("PerfDebt.swift", output, "with no flag the base is where the branch left perf")

        given = run("--base", "origin/feat-cmux-next")

        output = given.stdout + given.stderr
        self.assertNotEqual(given.returncode, 0, output)
        self.assertIn("Topic.swift", output)
        self.assertIn("PerfDebt.swift", output, "--base A judges exactly what HEAD adds over A")
        self.assertIn("the base given", output)

    def test_install_adds_the_gate_to_the_pre_push_hook(self):
        hooks = Path(self.git("config", "--get", "core.hooksPath").stdout.strip())
        self.assertTrue((hooks / "cmux_next_prepush_gate.py").is_file())

    def test_push_that_adds_a_try_bang_is_refused(self):
        before = self.remote_head()
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_WITH_TRY)
        self.commit("adds a try!")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before, "the bad commit must not reach origin")
        self.assertIn("Fresh.swift", output)
        self.assertIn("try!", output)
        self.assertNotIn("Old.swift", output, "base debt in an untouched file must not be reported")

    # A package whose test target declares one local target (one target per block, as Package.swift writes them).
    DEPS_PACKAGE = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNext",
    targets: [
        .target(
            name: "CmuxNextApp"
        ),
        .target(
            name: "CmuxNextKit"
        ),
        .testTarget(
            name: "CmuxNextKitTests",
            dependencies: ["CmuxNextKit"]
        ),
    ]
)
"""

    # A list of two entries, one per line under the checker's marker (check-package-dependency-lists.py).
    TWO_DEPS = ('dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py\n'
                '                "CmuxNextApp",\n                "CmuxNextKit",\n            ]')

    def test_push_that_adds_an_undeclared_local_import_is_refused_with_the_fix(self):
        # 2026-10-29: a63986a4 and e875485c each pushed a test import their target did not declare, and the CI step
        # "Package dependency lists sorted" was red on every pull request after them.
        self.write(f"{PKG}/Package.swift", self.DEPS_PACKAGE)
        self.write(f"{PKG}/Tests/CmuxNextKitTests/KitTests.swift", "import CmuxNextKit\n")
        self.commit("a test target")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        before = self.remote_head()
        self.write(f"{PKG}/Tests/CmuxNextKitTests/AppTests.swift", "import CmuxNextKit\n@testable import CmuxNextApp\n")
        self.commit("a test that imports the app")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before, "the bad commit must not reach origin")
        self.assertIn("Package dependency lists sorted", output)
        self.assertIn('Fix: add "CmuxNextApp" to the dependencies of CmuxNextKitTests', output)

        self.write(f"{PKG}/Package.swift",
                   self.DEPS_PACKAGE.replace('dependencies: ["CmuxNextKit"]', self.TWO_DEPS))
        self.commit("declare it")
        declared = self.push()
        self.assertEqual(declared.returncode, 0, declared.stdout + declared.stderr)

    def test_a_direct_gate_run_refuses_an_undeclared_local_import(self):
        # Review of #28365: the gate's own trees (a direct `prepush-gate.py` run, as agents and CI's "Pushed commits
        # add no violations" step do) held scripts/cmux-next only, so the checker could not import the Swift source
        # masker from scripts/, did not run, and the gate passed an undeclared import with a warning.
        self.write(f"{PKG}/Package.swift", self.DEPS_PACKAGE)
        self.write(f"{PKG}/Tests/CmuxNextKitTests/KitTests.swift", "import CmuxNextKit\n")
        self.commit("a test target")
        self.write(f"{PKG}/Tests/CmuxNextKitTests/AppTests.swift", "import CmuxNextKit\n@testable import CmuxNextApp\n")
        self.commit("a test that imports the app")

        result = subprocess.run(["python3", "-I", str(self.repo / GATE), "--repo", str(self.repo), "--base", "HEAD~1",
                                 "--head", "HEAD", "--only", "scanners"],
                                cwd=self.repo, env=self.env, text=True, capture_output=True)

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertNotIn("Package dependency lists sorted did not run cleanly", output)
        self.assertIn('Fix: add "CmuxNextApp" to the dependencies of CmuxNextKitTests', output)

    def test_push_that_drops_a_dependency_an_unchanged_file_imports_is_refused(self):
        # Review of 6d8b96f: the gate's trees held only the changed files, so a manifest edit that dropped a
        # dependency an untouched source imports passed. A manifest change now brings the package's Swift sources.
        self.write(f"{PKG}/Package.swift",
                   self.DEPS_PACKAGE.replace('dependencies: ["CmuxNextKit"]', self.TWO_DEPS))
        self.write(f"{PKG}/Tests/CmuxNextKitTests/AppTests.swift", "import CmuxNextKit\n@testable import CmuxNextApp\n")
        self.commit("a test target that declares what it imports")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        before = self.remote_head()
        self.write(f"{PKG}/Package.swift", self.DEPS_PACKAGE)
        self.commit("drop a dependency AppTests.swift still imports")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn('Fix: add "CmuxNextApp" to the dependencies of CmuxNextKitTests', output)

    def test_a_push_that_removes_one_of_two_baseline_imports_is_not_told_to_drop_the_baseline_line(self):
        # Review of 115ed33e: without a manifest change the trees hold only the changed files, so the check saw no
        # file importing CmuxNextWakeups and called IMPORT_BASELINE's line stale while an untouched file kept it.
        package = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNext",
    targets: [
        .target(
            name: "CmuxNextWakeups"
        ),
        .testTarget(
            name: "CmuxNextActionsTests"
        ),
    ]
)
"""
        self.write(f"{PKG}/Package.swift", package)
        self.write(f"{PKG}/Sources/CmuxNextWakeups/Wakeups.swift", "public enum Wakeups {}\n")
        self.write(f"{PKG}/Tests/CmuxNextActionsTests/A.swift", "import CmuxNextWakeups\n")
        self.write(f"{PKG}/Tests/CmuxNextActionsTests/B.swift", "import CmuxNextWakeups\n")
        self.commit("two files under the baseline import")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.write(f"{PKG}/Tests/CmuxNextActionsTests/A.swift", "import Foundation\n")
        self.commit("one file stops importing it")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertNotIn("drop its line", output)

    def test_a_push_that_declares_a_baseline_import_and_drops_its_line_passes(self):
        # Review of 3db311e3: the hook runs the installed checker, whose IMPORT_BASELINE still lists the pair, so the
        # cleanup the pushed checker asks for (declare it, drop its line) was refused with "drop its line".
        checker = "scripts/cmux-next/check-package-dependency-lists.py"
        pair = '"CmuxNextActionsTests: CmuxNextWakeups",'
        self.assertIn(pair, (self.repo / checker).read_text(), "the fixture needs this baseline pair")
        package = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNext",
    targets: [
        .target(
            name: "CmuxNextWakeups"
        ),
        .testTarget(
            name: "CmuxNextActionsTests"
        ),
    ]
)
"""
        self.write(f"{PKG}/Package.swift", package)
        self.write(f"{PKG}/Sources/CmuxNextWakeups/Wakeups.swift", "public enum Wakeups {}\n")
        self.write(f"{PKG}/Tests/CmuxNextActionsTests/A.swift", "import CmuxNextWakeups\n")
        self.commit("a baseline import")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.write(f"{PKG}/Package.swift", package.replace(
            'name: "CmuxNextActionsTests"\n', 'name: "CmuxNextActionsTests",\n            dependencies: ["CmuxNextWakeups"]\n'))
        self.write(checker, (self.repo / checker).read_text().replace(pair + "\n    ", "", 1))
        self.assertNotIn(pair, (self.repo / checker).read_text())
        self.commit("declare it and drop its baseline line")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertNotIn("drop its line", output)

    def test_a_pushed_baseline_cannot_hide_an_import_the_installed_checker_refuses(self):
        # The other half of the same fix: only the installed checker decides what is missing, so a push that adds a
        # pair to its own IMPORT_BASELINE still cannot land an undeclared import.
        checker = "scripts/cmux-next/check-package-dependency-lists.py"
        self.write(f"{PKG}/Package.swift", self.DEPS_PACKAGE)
        self.write(f"{PKG}/Tests/CmuxNextKitTests/KitTests.swift", "import CmuxNextKit\n")
        self.commit("a test target")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.write(f"{PKG}/Tests/CmuxNextKitTests/AppTests.swift", "@testable import CmuxNextApp\n")
        self.write(checker, (self.repo / checker).read_text().replace(
            "IMPORT_BASELINE = frozenset((\n", 'IMPORT_BASELINE = frozenset((\n    "CmuxNextKitTests: CmuxNextApp",\n', 1))
        self.commit("baseline the new import instead of declaring it")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn('Fix: add "CmuxNextApp" to the dependencies of CmuxNextKitTests', output)

    def test_an_annotated_or_set_baseline_is_read_so_a_dropped_line_is_still_seen(self):
        # Review of c9beb1af: `IMPORT_BASELINE: frozenset[str] = ...` read as None, which dropped_baseline_pairs took
        # as "nothing dropped", so a push that rewrote the line that way and dropped a pair passed the gate.
        spec = importlib.util.spec_from_file_location("prepush_gate_baseline", SOURCE / GATE)
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        for source in (b'IMPORT_BASELINE: frozenset[str] = frozenset(("A: B",))\n',
                       b'IMPORT_BASELINE = frozenset({"A: B"})\n'):
            self.assertEqual(gate.import_baseline(source), frozenset({"A: B"}), source)
        self.assertIsNone(gate.import_baseline(b"IMPORT_BASELINE: frozenset[str]\n"))

    def test_a_head_without_the_checker_reads_no_baseline_instead_of_aborting(self):
        # Review of 3f01de17: `git()` raises SystemExit on a failed `git show`, which the CalledProcessError handler
        # never caught, so a pushed head without the checker aborted the whole push.
        spec = importlib.util.spec_from_file_location("prepush_gate_no_checker", SOURCE / GATE)
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        (self.repo / gate.DEPS_CHECKER).unlink()
        self.commit("a head without the dependency checker")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        self.assertNotEqual(self.git("cat-file", "-e", f"{head}:{gate.DEPS_CHECKER}", check=False).returncode, 0)
        self.assertIsNone(gate.pushed_import_baseline(self.repo, head))

    def test_a_push_that_drops_a_baseline_line_without_declaring_the_import_is_refused(self):
        # Review of a37b4cce: the installed checker still lists the pair, so it reported neither a missing import nor
        # a stale line, and a push that only deleted the pair from IMPORT_BASELINE passed; CI's pushed checker failed.
        checker = "scripts/cmux-next/check-package-dependency-lists.py"
        pair = '"CmuxNextActionsTests: CmuxNextWakeups",'
        package = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNext",
    targets: [
        .target(
            name: "CmuxNextWakeups"
        ),
        .testTarget(
            name: "CmuxNextActionsTests"
        ),
    ]
)
"""
        self.write(f"{PKG}/Package.swift", package)
        self.write(f"{PKG}/Sources/CmuxNextWakeups/Wakeups.swift", "public enum Wakeups {}\n")
        self.write(f"{PKG}/Tests/CmuxNextActionsTests/A.swift", "import CmuxNextWakeups\n")
        self.commit("a baseline import")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        before = self.remote_head()
        self.write(checker, (self.repo / checker).read_text().replace(pair + "\n    ", "", 1))
        self.assertNotIn(pair, (self.repo / checker).read_text())
        self.commit("drop the baseline line, declare nothing")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn('Fix: add "CmuxNextWakeups" to the dependencies of CmuxNextActionsTests', output)

    def test_a_source_only_push_that_removes_a_baseline_import_s_last_use_must_drop_its_line(self):
        # Review of befae46a: with the manifest unchanged the gate dropped every "drop its line" finding, so a push
        # that removed the last import of a baseline pair passed and left the pair in IMPORT_BASELINE. Only a line
        # the push itself made stale is kept: base stale lines and pairs an untouched file still imports stay out.
        checker = "scripts/cmux-next/check-package-dependency-lists.py"
        pair = '"CmuxNextActionsTests: CmuxNextWakeups",'
        package = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNext",
    targets: [
        .target(
            name: "CmuxNextWakeups"
        ),
        .testTarget(
            name: "CmuxNextActionsTests"
        ),
    ]
)
"""
        self.write(f"{PKG}/Package.swift", package)
        self.write(f"{PKG}/Sources/CmuxNextWakeups/Wakeups.swift", "public enum Wakeups {}\n")
        self.write(f"{PKG}/Tests/CmuxNextActionsTests/A.swift", "import CmuxNextWakeups\n")
        self.commit("the one file under a baseline import")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        before = self.remote_head()
        self.write(f"{PKG}/Tests/CmuxNextActionsTests/A.swift", "import Foundation\n")
        self.commit("its last file stops importing it")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn("IMPORT_BASELINE lists CmuxNextActionsTests: CmuxNextWakeups", output)
        self.assertIn("drop its line", output)

        self.write(checker, (self.repo / checker).read_text().replace(pair + "\n    ", "", 1))
        self.assertNotIn(pair, (self.repo / checker).read_text())
        self.commit("drop its baseline line")
        dropped = self.push()
        self.assertEqual(dropped.returncode, 0, dropped.stdout + dropped.stderr)

    WAKEUPS_PACKAGE = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNext",
    targets: [
        .target(
            name: "CmuxNextWakeups"
        ),
        .testTarget(
            name: "CmuxNextActionsTests"
        ),
    ]
)
"""

    def test_a_push_that_only_deletes_a_baseline_import_s_last_file_must_drop_its_line(self):
        # Review of 81d1b7fb: changed_files() leaves deletions out, so a push that only deleted the last Swift file
        # importing a baseline pair changed no file, the gate never ran the dependency check, and the stale
        # IMPORT_BASELINE line reached CI.
        checker = "scripts/cmux-next/check-package-dependency-lists.py"
        pair = '"CmuxNextActionsTests: CmuxNextWakeups",'
        self.write(f"{PKG}/Package.swift", self.WAKEUPS_PACKAGE)
        self.write(f"{PKG}/Sources/CmuxNextWakeups/Wakeups.swift", "public enum Wakeups {}\n")
        self.write(f"{PKG}/Tests/CmuxNextActionsTests/A.swift", "import CmuxNextWakeups\n")
        self.write(f"{PKG}/Tests/CmuxNextActionsTests/B.swift", "import Foundation\n")
        self.commit("the one file under a baseline import")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        before = self.remote_head()
        self.git("rm", "--quiet", f"{PKG}/Tests/CmuxNextActionsTests/A.swift")
        self.commit("delete its last importing file")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn("IMPORT_BASELINE lists CmuxNextActionsTests: CmuxNextWakeups", output)
        self.assertIn("drop its line", output)

        self.write(checker, (self.repo / checker).read_text().replace(pair + "\n    ", "", 1))
        self.assertNotIn(pair, (self.repo / checker).read_text())
        self.commit("drop its baseline line")
        dropped = self.push()
        self.assertEqual(dropped.returncode, 0, dropped.stdout + dropped.stderr)

    def test_a_push_that_renames_a_baseline_import_s_last_file_is_not_told_to_drop_the_line(self):
        # The rename side of the same fix: the old path is gone but the new one still imports the module.
        self.write(f"{PKG}/Package.swift", self.WAKEUPS_PACKAGE)
        self.write(f"{PKG}/Sources/CmuxNextWakeups/Wakeups.swift", "public enum Wakeups {}\n")
        self.write(f"{PKG}/Tests/CmuxNextActionsTests/A.swift", "import CmuxNextWakeups\n")
        self.commit("the one file under a baseline import")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.git("mv", f"{PKG}/Tests/CmuxNextActionsTests/A.swift", f"{PKG}/Tests/CmuxNextActionsTests/C.swift")
        self.commit("rename it")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertNotIn("drop its line", output)

    def test_a_manifest_edit_does_not_put_a_changed_test_under_production_rules(self):
        # Review of 115ed33e: the package's file list for the dependency check replaced ast-grep's list of changed
        # production sources, so a test's try! failed only when the push also changed Package.swift.
        self.write(f"{PKG}/Package.swift", self.DEPS_PACKAGE)
        self.write(f"{PKG}/Tests/CmuxNextKitTests/KitTests.swift", "import CmuxNextKit\n")
        self.commit("a test target")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.write(f"{PKG}/Package.swift",
                   self.DEPS_PACKAGE.replace('dependencies: ["CmuxNextKit"]', self.TWO_DEPS))
        self.write(f"{PKG}/Tests/CmuxNextKitTests/TryTests.swift", self.with_try("TryTests"))
        self.commit("a manifest edit and a test with try!")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertNotIn("TryTests.swift", output)

    def test_push_that_adds_a_raw_spawn_in_a_daemon_crate_is_refused(self):
        # Reviews 1 and 2 of pl-holder-11: on macOS a daemon child started any other way than
        # cmux_process::Command can inherit a PTY master the daemon is receiving on another thread.
        self.write("cmux-tui/crates/cmux-tui-core/src/fresh.rs",
                   'pub fn run() { let _ = std::process::Command::new("git").output(); }\n')
        self.commit("adds a raw spawn to the daemon")
        before = self.remote_head()

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before, "the raw spawn must not reach origin")
        self.assertIn("check-no-raw-spawn", output)
        self.assertIn("fresh.rs", output)

    def test_push_with_a_spawn_through_cmux_process_or_outside_the_daemon_passes(self):
        self.write("cmux-tui/crates/cmux-tui-core/src/fresh.rs",
                   'pub fn run() { let _ = cmux_process::Command::new("git").output(); }\n')
        self.write("cmux-tui/crates/cmux-tui-core/tests/fresh.rs",
                   '#[test] fn t() { let _ = std::process::Command::new("git").output(); }\n')
        self.write("cmux-tui/crates/acpmux/src/fresh.rs",
                   'pub fn run() { let _ = std::process::Command::new("git").output(); }\n')
        self.commit("spawns through cmux_process, in a test and in another crate")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_raw_spawn_guard_rules_hold(self):
        # The guard's own rule tests (per-file counts, the ratchet, scope), with the pre-push set.
        result = subprocess.run(["bash", str(SOURCE / "scripts/cmux-next/tests/check-no-raw-spawn.test.sh")],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_app_id_special_cases_guard_rules_hold(self):
        # Zero first-party privilege (docs/app-store-platonic-ideal.md 5): the guard's own rule tests.
        result = subprocess.run(["bash", str(SOURCE / "scripts/cmux-next/tests/check-app-id-special-cases.test.sh")],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_push_that_names_an_apple_device_in_an_app_intent_is_refused(self):
        # ITMS-90626 (2026-10-20): Apple rejected cmux INTERNAL builds after upload for this text.
        before = self.remote_head()
        self.write("cmux-next-ios/App/ChiefVoiceIntents.swift", INTENT.replace("this device", "this iPhone"))
        self.commit("intent text names the iPhone")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before, "the rejected text must not reach origin")
        self.assertIn("90626-reserved-term", output)

    def test_push_with_device_neutral_app_intent_text_passes(self):
        self.write("cmux-next-ios/App/ChiefVoiceIntents.swift", INTENT)
        self.commit("intent text for every device")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_push_that_adds_conflict_markers_is_refused_even_with_a_skip_reason(self):
        # c779988d57d (2026-10-22) landed an unresolved merge in a test file; no scanner reads tests.
        before = self.remote_head()
        self.write(f"{PKG}/Tests/CmuxNextKitTests/MergedTests.swift",
                   "struct T {\n<<<<<<< HEAD\n    let a = 1\n=======\n    let a = 2\n>>>>>>> abc1234 (other)\n}\n")
        self.commit("unresolved merge")

        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="unrelated")

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before, "the conflicted file must not reach origin")
        self.assertIn("Merge conflict markers", output)
        self.assertIn("MergedTests.swift:2: <<<<<<< HEAD", output)

    def cargo_workspace(self):
        """A two-crate cmux-tui workspace with a matching Cargo.lock; the push env cargo needs under this HOME."""
        cargo = shutil.which("cargo")
        if cargo is None:
            self.skipTest("no cargo on this host")
        real_home = Path(os.environ.get("HOME", str(Path.home())))
        env = {"CARGO_HOME": os.environ.get("CARGO_HOME", str(real_home / ".cargo")),
               "RUSTUP_HOME": os.environ.get("RUSTUP_HOME", str(real_home / ".rustup")),
               "PATH": f"{Path(cargo).parent}:{self.env.get('PATH', '')}"}
        self.write("cmux-tui/Cargo.toml", '[workspace]\nmembers = ["crates/a", "crates/b"]\nresolver = "2"\n')
        for name in ("a", "b"):
            self.write(f"cmux-tui/crates/{name}/Cargo.toml",
                       f'[package]\nname = "{name}"\nversion = "0.1.0"\nedition = "2021"\n')
            self.write(f"cmux-tui/crates/{name}/src/lib.rs", "")
        made = subprocess.run(["cargo", "generate-lockfile", "--offline"], cwd=self.repo / "cmux-tui",
                              env={**self.env, **env}, text=True, capture_output=True)
        self.assertEqual(made.returncode, 0, made.stderr)
        self.commit("cmux-tui workspace")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        return env

    def test_a_cargo_dependency_moved_without_its_lock_is_refused(self):
        # 2026-11-02: #31462 changed a crate's Cargo.toml and left Cargo.lock behind; every --locked step failed.
        env = self.cargo_workspace()
        before = self.remote_head()
        self.write("cmux-tui/crates/a/Cargo.toml", '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n'
                   '\n[dependencies]\nb = { path = "../b" }\n')
        self.commit("a uses b")

        result = self.push(**env)

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn("cmux-tui/Cargo.lock: does not match its manifests", output)

    def test_a_cargo_dependency_with_its_lock_pushes(self):
        env = self.cargo_workspace()
        self.write("cmux-tui/crates/a/Cargo.toml", '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n'
                   '\n[dependencies]\nb = { path = "../b" }\n')
        locked = subprocess.run(["cargo", "metadata", "--offline", "--format-version", "1"], cwd=self.repo / "cmux-tui",
                                env={**self.env, **env}, capture_output=True, text=True)
        self.assertEqual(locked.returncode, 0, locked.stderr)
        self.commit("a uses b, with the lock")

        result = self.push(**env)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    SIDEBAR_VIEW = f"{PKG}/Sources/CmuxNextSidebar/Views/RowView.swift"

    def test_a_sidebar_view_change_without_a_sidebar_look_trailer_is_refused_even_with_a_skip_reason(self):
        # 233 sidebar commits in four days undid each other (Lawrence 2026-10-23): the owner keeps the look.
        before = self.remote_head()
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let inset = 22\n}\n")
        self.commit("sidebar: move the title")

        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="unrelated")

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn("Sidebar look owner", output)
        self.assertIn("no `Sidebar-Look:` trailer", output)

    def test_a_sidebar_change_outside_views_also_needs_the_trailer(self):
        # a702 (2026-10-25) turned the pinned section's tiles into rows in Sections/, outside Views/.
        self.write(f"{PKG}/Sources/CmuxNextSidebar/Sections/SectionFlow.swift", "struct SectionFlow {\n    let rows = true\n}\n")
        self.commit("sidebar: pinned section draws rows")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("no `Sidebar-Look:` trailer", output)

    def test_sidebar_strings_need_no_trailer(self):
        self.write(f"{PKG}/Sources/CmuxNextSidebar/Strings.swift", "let hello = \"Hello\"\n")
        self.commit("sidebar: copy")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_visual_sidebar_change_must_update_the_owner_note(self):
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let inset = 22\n}\n")
        self.commit("sidebar: move the title\n\nSidebar-Look: Lawrence 11405 text as left as possible")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("must update plans/cmux-next/sidebar-owner.md", output)

    def test_a_visual_sidebar_change_with_the_note_passes(self):
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let inset = 6\n}\n")
        self.write("plans/cmux-next/sidebar-owner.md", "# owner\n- titles at the inset (Lawrence 11405)\n")
        self.commit("sidebar: title at the inset\n\nSidebar-Look: Lawrence 11405 text as left as possible")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_sidebar_change_marked_no_visual_change_passes_without_the_note(self):
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let cache = [Int]()\n}\n")
        self.commit("sidebar: cache the rows\n\nSidebar-Look: no visual change")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_later_commit_does_not_launder_an_earlier_sidebar_change(self):
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let inset = 22\n}\n")
        self.commit("sidebar: move the title")
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let inset = 23\n}\n")
        self.write("plans/cmux-next/sidebar-owner.md", "# owner\n")
        self.commit("sidebar: tweak\n\nSidebar-Look: Lawrence said so")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("sidebar: move the title", output)

    def test_a_sidebar_change_the_owner_logged_passes_in_the_ci_sweep(self):
        # dcd4316ef5c (2026-10-23) reached the branch from an old hook copy; the owner logs it once.
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let flash = true\n}\n")
        self.commit("scrollers: flash on enter")
        first = self.git("rev-parse", "HEAD").stdout.strip()
        base = self.git("rev-parse", "HEAD^").stdout.strip()
        gate = self.repo / "scripts/cmux-next/prepush-gate.py"
        sweep = lambda: subprocess.run(["python3", "-I", str(gate), "--only", "sidebar", "--commits", f"{base}..HEAD"],
                                       cwd=self.repo, env=self.env, text=True, capture_output=True)
        unlogged = sweep()
        self.assertNotEqual(unlogged.returncode, 0, unlogged.stdout + unlogged.stderr)
        self.write("plans/cmux-next/sidebar-owner.md", f"# owner\n- {first[:11]} scrollers (a595), no look change\n")
        self.commit("plans: log the scroller commit")

        logged = sweep()

        self.assertEqual(logged.returncode, 0, logged.stdout + logged.stderr)

    def test_a_pull_request_sweep_warns_on_a_base_commit_and_errors_on_its_own(self):
        # 2026-10-29: two feat-cmux-next commits without the owner's record (#24073, #24295) put an ##[error] on
        # every pull request's checks, and next-autoland read it as the PR's own red (#27454). A pull request is
        # judged on its own commits (--own-range); the base's debt is a warning that names the commit there, and
        # stays an error on the branch's push sweep (no --own-range).
        start = self.git("rev-parse", "HEAD").stdout.strip()
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let inset = 22\n}\n")
        self.commit("sidebar: a base commit with no record")
        on_base = self.git("rev-parse", "HEAD").stdout.strip()
        gate = self.repo / "scripts/cmux-next/prepush-gate.py"
        sweep = lambda *extra: subprocess.run(
            ["python3", "-I", str(gate), "--only", "sidebar", "--commits", f"{start}..HEAD", *extra],
            cwd=self.repo, env=self.env, text=True, capture_output=True)

        # The pull request adds an unrelated commit: the base commit is only a warning.
        self.write("docs/notes.md", "notes\n")
        self.commit("docs: notes")
        pr_run = sweep("--own-range", f"{on_base}..HEAD")
        output = pr_run.stdout + pr_run.stderr
        self.assertEqual(pr_run.returncode, 0, output)
        self.assertNotIn("::error", output)
        self.assertIn("::warning title=Sidebar look owner (base commit)::", output)
        self.assertIn(on_base[:11], output)
        self.assertIn("plans/cmux-next/sidebar-owner.md", output)
        self.assertIn("no `Sidebar-Look:` trailer. Add", output, "the warning carries the whole finding")

        # The branch's push sweep (no --own-range) still fails on the same base commit.
        push_run = sweep()
        self.assertNotEqual(push_run.returncode, 0, push_run.stdout + push_run.stderr)
        self.assertIn("::error title=Sidebar look owner::", push_run.stdout)

        # A sidebar commit of the pull request's own stays an error, next to the base commit's warning.
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let inset = 23\n}\n")
        self.commit("sidebar: the pull request's own commit with no record")
        own_commit = self.git("rev-parse", "HEAD").stdout.strip()
        pr_run = sweep("--own-range", f"{on_base}..HEAD")
        output = pr_run.stdout + pr_run.stderr
        self.assertNotEqual(pr_run.returncode, 0, output)
        self.assertIn("::error title=Sidebar look owner::1 commit(s)", output)
        self.assertIn(own_commit[:11], output.split("::warning")[0])
        self.assertIn(f"{on_base[:11]}", output.split("::warning", 1)[1])

    def test_a_fixture_that_mentions_one_marker_passes(self):
        self.write("docs/merging.md", "Git writes a line such as\n<<<<<<< HEAD\nat the top of a hunk.\n")
        self.commit("docs mention a marker")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    # Crash-allow-OK (lead 2026-10-24): the hook runs the installed crash data, so a reviewed allowlist entry needs
    # the commit trailer; only that commit's own additions are read from the push.
    def add_allow_entry(self, path, count=1):
        import json
        allowlist = self.repo / "scripts/cmux-next/crash-allowlist.json"
        data = json.loads(allowlist.read_text())
        data["allow"].append({"path": path, "class": "swift.unowned", "count": count, "reason": "fixture",
                              "reviewer": "fixture review"})
        allowlist.write_text(json.dumps(data, indent=1) + "\n")

    def test_a_crash_allowlist_entry_without_the_trailer_is_refused(self):
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_WITH_UNOWNED)
        self.add_allow_entry(f"{PKG}/Sources/CmuxNextKit/Fresh.swift")
        self.commit("adds an unowned reference and its allowlist entry, no trailer")
        before = self.remote_head()

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("Crash allowlist review", output)
        self.assertEqual(self.remote_head(), before)

    def test_a_crash_allowlist_entry_with_the_trailer_passes_and_is_named(self):
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_WITH_UNOWNED)
        self.add_allow_entry(f"{PKG}/Sources/CmuxNextKit/Fresh.swift")
        self.commit("adds an unowned reference and its allowlist entry\n\nCrash-allow-OK: review 4 of PL-blocking")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("reviewed raises of the pushed crash data", output)
        self.assertIn("allow swift.unowned in Packages/macOS/CmuxNext/Sources/CmuxNextKit/Fresh.swift", output)

    def test_a_trailer_covers_only_its_own_commit(self):
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_WITH_UNOWNED)
        self.add_allow_entry(f"{PKG}/Sources/CmuxNextKit/Fresh.swift")
        self.commit("adds an unowned reference and its allowlist entry, no trailer")
        self.write(f"{PKG}/Sources/CmuxNextKit/Other.swift", NEW_CLEAN.replace("Fresh", "Other"))
        self.commit("other work\n\nCrash-allow-OK: someone")
        before = self.remote_head()

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertNotIn("reviewed raises of the pushed crash data", output)
        self.assertEqual(self.remote_head(), before)

    # The crash ratchet (scripts/cmux-next/crash_ratchet.py, CI's cmux-next-guards "cmux-next crash ratchet" step)
    # counts the Rust unwraps of each crate against crash-safety-baseline.json (cmux-tui-core: over a thousand). The
    # gate's trees hold only the changed files, so their count never reached the row: #39304's first head (60550abe)
    # added two non-test `.lock().unwrap()`, passed the hook and was refused by CI. A main-based push (no CmuxNext app
    # entry in its tree) got no crash check at all: check-crash-safety.sh died on the missing file and only warned.
    CRATE_FILE = "cmux-tui/crates/cmux-tui-core/src/undo_fixture.rs"
    RUST_CLEAN = """use std::sync::Mutex;

pub struct Snapshot {
    state: Mutex<u32>,
}

impl Snapshot {
    pub fn read(&self) -> u32 {
        *self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}
"""
    RUST_LOCK_UNWRAP = RUST_CLEAN.replace("unwrap_or_else(std::sync::PoisonError::into_inner)", "unwrap()")
    RUST_CLEAN_MORE = RUST_CLEAN + """
pub fn twice(value: u32) -> u32 {
    value.saturating_mul(2)
}
"""

    def main_branch(self):
        """origin/main as this clone fetched it: cut from feat-cmux-next's base, without the CmuxNext app entry (the
        feat-only path check-crash-safety.sh reads) and with a clean cmux-tui crate file. Pushed past the hook."""
        self.git("checkout", "--quiet", "-b", "main", "origin/feat-cmux-next")
        self.git("rm", "--quiet", f"{PKG}/Sources/CmuxNextApp/CmuxNextApp.swift")
        self.write(self.CRATE_FILE, self.RUST_CLEAN)
        self.commit("main: its own tree")
        self.assertEqual(self.push_ref("main", "--no-verify").returncode, 0)
        self.git("fetch", "--quiet", "origin")
        self.git("checkout", "--quiet", "-b", "topic", "--no-track", "origin/main")

    def test_a_main_based_push_that_adds_a_lock_unwrap_is_refused(self):
        self.main_branch()
        self.write(self.CRATE_FILE, self.RUST_LOCK_UNWRAP)
        self.commit("main-based: a lock().unwrap() in production code")

        result = self.push_ref("topic")

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertFalse(self.remote_has("refs/heads/topic"), "the unwrap must not reach origin")
        self.assertIn("cut from origin/main", output, "control: the push is judged as main-based")
        self.assertIn("Crash ratchet", output)
        self.assertIn(f"{self.CRATE_FILE}:", output)
        self.assertIn("unwrap", output)

    def test_a_main_based_clean_push_passes_with_no_crash_check_warning(self):
        self.main_branch()
        self.write(self.CRATE_FILE, self.RUST_CLEAN_MORE)
        self.commit("main-based: clean Rust")

        result = self.push_ref("topic")

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("cut from origin/main", output, "control: the push is judged as main-based")
        self.assertNotIn("FileNotFoundError", output)
        self.assertNotIn("CmuxNextApp.swift", output)
        self.assertNotIn("did not run cleanly", output)

    def test_a_feat_based_push_that_adds_a_lock_unwrap_is_refused(self):
        self.write(self.CRATE_FILE, self.RUST_CLEAN)
        self.commit("base: a clean crate file")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        before = self.remote_head()
        self.write(self.CRATE_FILE, self.RUST_LOCK_UNWRAP)
        self.commit("a lock().unwrap() in production code")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before, "the unwrap must not reach origin")
        self.assertIn("Crash ratchet", output)
        self.assertIn(f"{self.CRATE_FILE}:", output)
        self.assertIn("unwrap", output)

    def test_a_test_only_lock_unwrap_passes(self):
        # The ratchet skips test code: an inline #[cfg(test)] module, and a file a `#[cfg(test)] mod name;` line in
        # an unchanged file declares (the gate's trees need that declaring file to tell).
        self.write("cmux-tui/crates/cmux-tui-core/src/lib.rs", "#[cfg(test)]\nmod test_support;\n")
        self.commit("base: a test-only module declaration")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.write("cmux-tui/crates/cmux-tui-core/src/test_support.rs",
                   self.RUST_LOCK_UNWRAP.replace("pub struct", "pub(crate) struct"))
        self.write(self.CRATE_FILE, self.RUST_CLEAN + """
#[cfg(test)]
mod tests {
    #[test]
    fn reads() {
        let state = std::sync::Mutex::new(1);
        assert_eq!(*state.lock().unwrap(), 1);
    }
}
""")
        self.commit("test-only lock().unwrap()")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    # A ratchet row a push lowers or deletes with the sites it removes (lead 2026-11-03, #33091): the installed
    # baseline cannot know the push lowered it, so it read the fix as "fewer than the baseline" and refused it. Each
    # tree reads its own row where that is lower; a raise or a new row still reads the installed copy.
    SCAN = "cmux-tui/crates/fixture/src/scan.rs"

    def scan_source(self, sites):
        return "".join("pub fn exe%d(pid: i32) -> String {\n    format!(\"/proc/{pid}/exe\")\n}\n" % i
                       for i in range(sites))

    def set_scan_row(self, count):
        path = self.repo / "scripts/cmux-next/process-scan-baseline.tsv"
        lines = [line for line in path.read_text().splitlines() if not line.startswith(self.SCAN + "\t")]
        if count:
            lines.append(f"{self.SCAN}\t{count}\tremove\tfixture")
        path.write_text("\n".join(lines) + "\n")

    def install_with_scan_sites(self, sites):
        """A base with SITES process-scan lines and their row, and the hook installed from it."""
        self.write(self.SCAN, self.scan_source(sites))
        self.set_scan_row(sites)
        self.commit(f"base: {sites} process-scan lines")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        installed = subprocess.run(["bash", INSTALLER], cwd=self.repo, env=self.env, text=True, capture_output=True)
        self.assertEqual(installed.returncode, 0, installed.stderr)

    def test_a_push_that_lowers_a_ratchet_row_with_its_fix_passes(self):
        self.install_with_scan_sites(2)
        self.write(self.SCAN, self.scan_source(1))
        self.set_scan_row(1)
        self.commit("removes one process-scan line and lowers its row")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_push_that_deletes_the_row_of_a_site_it_removed_passes(self):
        self.install_with_scan_sites(2)
        self.write(self.SCAN, "pub fn other() {}\n")
        self.set_scan_row(0)
        self.commit("removes both process-scan lines and deletes their row")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_push_that_raises_a_ratchet_row_is_still_refused(self):
        self.install_with_scan_sites(2)
        self.write(self.SCAN, self.scan_source(3))
        self.set_scan_row(3)
        self.commit("adds a process-scan line and raises its row")
        before = self.remote_head()

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("No process scanning", output)
        self.assertIn("has 3 process-scan line(s), baseline 2", output)
        self.assertEqual(self.remote_head(), before)

    def test_a_push_that_lowers_a_row_below_its_sites_is_refused(self):
        self.install_with_scan_sites(2)
        self.write(self.SCAN, self.scan_source(2) + "pub fn other() {}\n")
        self.set_scan_row(1)
        self.commit("lowers the row but keeps both lines")
        before = self.remote_head()

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("has 2 process-scan line(s), baseline 1", output)
        self.assertEqual(self.remote_head(), before)

    def test_a_direct_run_takes_a_row_added_for_sites_already_on_the_base(self):
        # #37531: a base red's fix adds the row for process-scan sites already on the base and touches no source. The
        # trees held only changed files, so the head read 0 sites against the new row and refused the fix.
        self.write(self.SCAN, self.scan_source(1))
        self.commit("base: a process-scan line with no row")
        self.set_scan_row(1)
        self.write("cmux-tui/crates/fixture/src/other.rs", "pub fn other() {}\n")  # the crate is in the trees
        self.commit("adds its row")

        result = subprocess.run(["python3", "-I", str(self.repo / GATE), "--repo", str(self.repo), "--base", "HEAD~1",
                                 "--head", "HEAD", "--only", "scanners"],
                                cwd=self.repo, env=self.env, text=True, capture_output=True)

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertNotIn("now has 0 process-scan line(s)", output)

    def test_each_ratchet_baseline_shape_takes_only_lower_rows(self):
        spec = importlib.util.spec_from_file_location("prepush_gate_ratchet_rows", SOURCE / GATE)
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        name = "swift-type-scale-baseline.tsv"
        self.write(f"scripts/cmux-next/{name}", "# path\tkind\tcount\nA.swift\tsize\t1\nA.swift\tweight\t5\nC.swift\tsize\t4\n")
        self.commit("pushed type-scale rows: one lower, one higher, one deleted, one new")
        installed = self.root / "installed"
        installed.mkdir()
        (installed / name).write_text("# path\tkind\tcount\nA.swift\tsize\t3\nA.swift\tweight\t2\nB.swift\tsize\t1\n")

        taken = gate.lower_ratchet_baselines(self.repo, "HEAD", installed)

        self.assertEqual((installed / name).read_text(), "# path\tkind\tcount\nA.swift\tsize\t1\nA.swift\tweight\t2\n")
        self.assertEqual(sorted(taken), [f"{name}: A.swift size 3 -> 1", f"{name}: B.swift size 1 -> 0 (row deleted)"])
        self.assertEqual(set(gate.RATCHET_BASELINES), {
            "process-scan-baseline.tsv", "state-roots-baseline.tsv", "raw-spawn-baseline.tsv",
            "app-id-special-cases-baseline.tsv", "swift-type-scale-baseline.tsv"})

    def test_push_that_touches_a_file_with_old_debt_passes(self):
        self.write(f"{PKG}/Sources/CmuxNextKit/Old.swift", OLD.replace('"old"', '"renamed"'))
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_CLEAN)
        self.commit("edits next to an old try!, adds clean code")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remote_head(), self.git("rev-parse", "HEAD").stdout.strip())

    @NEEDS_SWIFTFORMAT
    def test_push_that_adds_a_swiftformat_violation_is_refused(self):
        self.kit("Fresh", SWIFTFORMAT_HIT)
        self.commit("adds two blank lines in a row")

        result = self.push()

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SwiftFormat --lint", result.stdout + result.stderr)
        self.assertRegex(result.stdout + result.stderr, r"Sources/CmuxNextKit/Fresh\.swift:\d+:\d+: error: \(consecutiveBlankLines\)")
        self.assertNotEqual(self.remote_head(), self.git("rev-parse", "HEAD").stdout.strip())

    @NEEDS_SWIFTFORMAT
    def test_push_with_swiftformat_clean_code_passes(self):
        self.kit("Fresh", SWIFTFORMAT_CLEAN)
        self.commit("adds formatted code")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("(consecutiveBlankLines)", result.stdout + result.stderr)

    @NEEDS_SWIFTFORMAT
    def test_push_that_edits_a_file_with_an_old_swiftformat_violation_passes(self):
        # The base already has the double blank line (pushed past the hook); the push edits other lines of that file.
        self.kit("Fresh", SWIFTFORMAT_HIT)
        self.commit("old formatting debt")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.kit("Fresh", SWIFTFORMAT_HIT.replace("    func a()", "    func c() -> Int { 3 }\n\n    func a()"))
        self.commit("adds a function above the old double blank line")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remote_head(), self.git("rev-parse", "HEAD").stdout.strip())

    @NEEDS_SWIFTFORMAT
    def test_ci_modes_do_not_run_the_swiftformat_layer(self):
        # SwiftFormat findings are refused by the local pre-push hook only (lead 2026-10-27, CLAUDE.md: no new CI
        # gates). CI and the merge-time gates run the gate as --base/--head (fast gates, car guards, pull requests)
        # or --commits (pushes); none of them may refuse a SwiftFormat finding.
        self.kit("Fresh", SWIFTFORMAT_HIT)
        self.commit("adds two blank lines in a row")
        for args in (["--base", "HEAD~1", "--head", "HEAD"], ["--commits", "HEAD~1..HEAD"]):
            with self.subTest(args=args):
                result = subprocess.run(["python3", "-I", GATE, *args], cwd=self.repo, env=self.env, text=True,
                                        capture_output=True)
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, output)
                self.assertNotIn("(consecutiveBlankLines)", output)

    def test_branch_checker_changes_are_not_executed_by_the_installed_hook(self):
        marker = self.root / "branch-checker-ran"
        self.write(
            "scripts/cmux-next/check-concurrency.sh",
            f"#!/bin/bash\necho branch-controlled > {marker}\nexit 0\n",
        )
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_CLEAN)
        self.commit("branch replaces a pre-push checker")

        self.push()

        self.assertFalse(marker.exists(), "the installed trusted hook executed the branch-controlled checker")

    def test_an_installed_lexer_older_than_origin_s_is_named_as_stale(self):
        # guardrails.py loads count-swift-code-lines.py from the installed copy; an old one counts unlike CI.
        lexer = "scripts/cmux-next/count-swift-code-lines.py"
        self.write(lexer, (self.repo / lexer).read_text() + "# changed upstream\n")
        self.commit("the lexer changes on feat-cmux-next")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_CLEAN)
        self.commit("clean")

        pushed = self.push()

        self.assertIn("count-swift-code-lines.py", pushed.stdout + pushed.stderr)
        self.assertIn("installed hook copy", pushed.stdout + pushed.stderr)

    def test_an_installed_pre_push_hook_older_than_origin_s_is_named_as_stale(self):
        # The hook passes the remote's URL to the compile trailer rule (7ea27860336): an old hook leaves it off.
        hook = "scripts/git-hooks/pre-push"
        self.write(hook, (self.repo / hook).read_text() + "# changed upstream\n")
        self.commit("the pre-push hook changes on feat-cmux-next")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_CLEAN)
        self.commit("clean")

        pushed = self.push()

        self.assertIn("pre-push (the hook)", pushed.stdout + pushed.stderr)
        self.assertIn("run scripts/install-git-hooks.sh", pushed.stdout + pushed.stderr)

    def test_push_from_a_linked_worktree_leaves_the_repository_alone(self):
        # git runs the hook with GIT_DIR=<repo>/.git/worktrees/<name>: the gate's own temp-tree
        # git calls must not inherit it (2026-10-19: it set core.bare=true on the shared clone and
        # staged the deletion of every file in the pushing worktree's index).
        linked = self.root / "linked"
        self.git("worktree", "add", "--quiet", "-b", "linked-work", str(linked), "feat-cmux-next")
        (linked / f"{PKG}/Sources/CmuxNextKit/Fresh.swift").write_text(NEW_CLEAN)
        run = lambda *args: subprocess.run(["git", "-C", str(linked), *args], env=self.env,
                                           text=True, capture_output=True)
        run("add", "-A")
        run("commit", "--quiet", "--no-verify", "-m", "clean change from a linked worktree")

        result = run("push", "origin", "linked-work:feat-cmux-next")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("config", "--get", "core.bare").stdout.strip(), "false")
        self.assertEqual(run("diff", "--cached", "--name-only").stdout, "", "the pushing worktree's index must not change")
        self.assertEqual(self.git("diff", "--cached", "--name-only").stdout, "")

    def test_skip_reason_lets_the_push_through_and_says_so(self):
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_WITH_TRY_ONLY)
        self.commit("adds a try!")

        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: the try! is in a file this push does not touch")

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("SKIPPED", output)

    def test_ci_commits_mode_names_the_commit_pushed_with_no_verify(self):
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_CLEAN)
        self.commit("clean commit")
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_WITH_TRY)
        self.commit("sneaks in a try!")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")

        result = subprocess.run(["python3", "-I", GATE, "--commits", "HEAD~2..HEAD"], cwd=self.repo,
                                env=self.env, text=True, capture_output=True)

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("sneaks in a try!", output)
        self.assertNotIn("clean commit adds", output)
        self.assertIn("2 commit(s) checked, 1 add violations", output)


    # Ghostty's default split keys (Lawrence 2026-10-20, after 2f3e1f95983 made Cmd-Opt-Left / Right
    # sidebar keys): the gate refuses a push whose exported keymap gives one to another action.
    RESERVED = {"reserved": [{"key": "cmd+opt+left", "command": "focusLeft", "ghostty": "goto_split:left"}],
                "scopedOwners": {"keys": ["codeEditorFocused"]}, "scopedActions": []}

    @staticmethod
    def surfaces(sidebar_alias):
        left = {"key": "\uf702", "modifiers": ["opt", "cmd"]}
        prev = {"id": "prevSidebarTab", "default_shortcut": {"key": "[", "modifiers": ["ctrl", "cmd"]},
                "default_aliases": [{"keys": [left], "when": None}] if sidebar_alias else []}
        focus = {"id": "focusLeft", "default_shortcut": left, "default_aliases": []}
        return {"version": 1, "actions": [focus, prev]}

    def reserved_base(self):
        import json
        self.write("schemas/keybindings/ghostty-reserved-keys.json", json.dumps(self.RESERVED))
        self.write("plans/cmux-next/action-surfaces.json", json.dumps(self.surfaces(False)))
        self.commit("reserved keys")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.write("plans/cmux-next/action-surfaces.json", json.dumps(self.surfaces(True)))

    def test_push_that_gives_a_ghostty_key_to_another_action_is_refused_even_with_a_skip_reason(self):
        self.reserved_base()
        before = self.remote_head()
        self.commit("Cmd-Opt-Left selects the previous sidebar item")

        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: unrelated base failure")

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn("prevSidebarTab takes Ghostty's cmd+opt+left", output)
        self.assertIn("does not skip", output)

    def test_a_ghostty_defaults_ok_trailer_lets_the_change_through(self):
        self.reserved_base()
        self.commit("Cmd-Opt-Left selects the previous sidebar item\n\nGhostty-defaults-OK: \"fixture: yes, rebind it\"")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    # What's New highlights (release-notes/next/WRITING.md). 2026-11-01: #30774, #31156 and #31140 each landed a
    # highlight with no docs link (or three sentences); only the release-notary job's test (after the merge) saw it,
    # and it was red on every pull request until a fix landed (#31032, #31252).
    HIGHLIGHT_NO_LINK = ("title: Continue a stopped reply\ncategory: improved\n\n"
                         "Continue picks up a reply you stopped, and Retry asks again.\n")
    HIGHLIGHT_WITH_DOCS = ("title: Continue a stopped reply\ncategory: improved\ndocs: https://cmux.com/docs/chief\n"
                           "gallery: agent-pane.continue/stopped\n\n"
                           "Continue picks up a reply you stopped, and Retry asks again.\n")
    HIGHLIGHTS = "release-notes/next/highlights"

    def test_a_pushed_highlight_without_a_docs_link_is_refused_by_the_hook_only(self):
        before = self.remote_head()
        self.write(f"{self.HIGHLIGHTS}/continue-retry.md", self.HIGHLIGHT_NO_LINK)
        self.commit("adds a highlight with no docs link")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before, "the highlight must not reach origin")
        self.assertIn("What's New highlights", output)
        self.assertIn(f"{self.HIGHLIGHTS}/continue-retry.md: entries[0] (continue-retry): "
                      "needs a tryIt action/deeplink or a docs link", output)
        self.assertIn("add docs: https://cmux.com/docs/<page> or a tryIt; at most 2 sentences, 240 characters", output)
        # The rule stays out of CI and the merge-time gates (CLAUDE.md: no new CI gates): they run --base/--head
        # (pull requests, fast gates, car guards) or --commits (pushes).
        for args in (["--base", "HEAD~1", "--head", "HEAD"], ["--commits", "HEAD~1..HEAD"]):
            with self.subTest(args=args):
                ci = subprocess.run(["python3", "-I", GATE, *args], cwd=self.repo, env=self.env, text=True,
                                    capture_output=True)
                self.assertEqual(ci.returncode, 0, ci.stdout + ci.stderr)
                self.assertNotIn("What's New highlights", ci.stdout + ci.stderr)

    def test_a_pushed_highlight_with_a_docs_link_passes(self):
        self.write(f"{self.HIGHLIGHTS}/continue-retry.md", self.HIGHLIGHT_WITH_DOCS)
        self.commit("adds a highlight with a docs link")

        direct = subprocess.run(["python3", "-I", GATE, "--timings"], cwd=self.repo, env=self.env, text=True,
                                capture_output=True)
        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remote_head(), self.git("rev-parse", "HEAD").stdout.strip())
        # The plain run judged the highlight (its timing line) and found nothing.
        self.assertIn("What's New highlights", direct.stderr, direct.stdout + direct.stderr)
        self.assertNotIn("needs a tryIt", direct.stdout + direct.stderr)

    def test_an_unchanged_bad_highlight_elsewhere_does_not_block_a_push(self):
        # Someone else's bad highlight reached the base past the hook; this push adds its own highlight next to it.
        self.write(f"{self.HIGHLIGHTS}/old-bad.md", "title: Old\n\nOne. Two. Three sentences is too many.\n")
        self.commit("someone else's bad highlight")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.write(f"{self.HIGHLIGHTS}/continue-retry.md", self.HIGHLIGHT_NO_LINK)
        self.commit("adds a highlight with no docs link")

        refused = self.push()

        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn(f"{self.HIGHLIGHTS}/continue-retry.md", output)
        self.assertNotIn("old-bad.md", output, "only the highlights the push changes are judged")

        self.write(f"{self.HIGHLIGHTS}/continue-retry.md", self.HIGHLIGHT_WITH_DOCS)
        self.git("add", "-A")
        self.git("commit", "--quiet", "--no-verify", "--amend", "-m", "adds a highlight with a docs link")

        passed = self.push()

        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
        self.assertEqual(self.remote_head(), self.git("rev-parse", "HEAD").stdout.strip())

    def test_the_hook_runs_origin_s_highlight_validator_not_the_pushed_one(self):
        # A push that also weakens the validator cannot pass its own highlight: the hook reads
        # origin/feat-cmux-next's validator, as it runs the installed checks and never the branch's.
        before = self.remote_head()
        self.write("scripts/whats-new/digest.py", (self.repo / "scripts/whats-new/digest.py").read_text()
                   + "\n\ndef entry_problems(entry):\n    return []\n")
        self.write(f"{self.HIGHLIGHTS}/continue-retry.md", self.HIGHLIGHT_NO_LINK)
        self.commit("adds a highlight and a validator that accepts it")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn("needs a tryIt action/deeplink or a docs link", output)

    def test_a_pushed_highlight_that_is_not_utf8_is_refused_as_the_release_notary_test_fails_it(self):
        # The release-notary test opens each highlight as strict UTF-8: a Latin-1 byte is a test error there, so the
        # hook refuses it too, naming the file (review of #31260).
        before = self.remote_head()
        path = self.repo / self.HIGHLIGHTS / "continue-retry.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.HIGHLIGHT_WITH_DOCS.replace("Retry asks again", "Retry asks the caf\u00e9 again")
                         .encode("latin-1"))
        self.commit("adds a Latin-1 highlight")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn(f"{self.HIGHLIGHTS}/continue-retry.md: is not UTF-8 text", output)

    # What's New pictures (goal whats-new-pretty): on 2026-11-08, 61 of 166 New or Improved highlights in 21 days
    # changed only Swift, got no gallery state and went out with no picture.
    HIGHLIGHT_NO_PICTURE = ("title: Side chats from the command prompt\ncategory: new\n"
                            "docs: https://cmux.com/docs/chief\n\nType /side to fork the chat into a side chat.\n")

    def test_a_pushed_new_highlight_with_no_picture_source_is_refused_by_the_hook_only(self):
        before = self.remote_head()
        self.write(f"{self.HIGHLIGHTS}/side-chat.md", self.HIGHLIGHT_NO_PICTURE)
        self.commit("adds a highlight with no picture source")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn("What's New pictures", output)
        self.assertIn(f"{self.HIGHLIGHTS}/side-chat.md: a new highlight with no picture source", output)
        self.assertIn("release-notes/next/clips/<id>.json", output)
        for args in (["--base", "HEAD~1", "--head", "HEAD"], ["--commits", "HEAD~1..HEAD"]):
            with self.subTest(args=args):
                ci = subprocess.run(["python3", "-I", GATE, *args], cwd=self.repo, env=self.env, text=True,
                                    capture_output=True)
                self.assertNotIn("What's New pictures", ci.stdout + ci.stderr)

    def test_each_picture_source_lets_a_new_highlight_through(self):
        sources = {
            "gallery line": {f"{self.HIGHLIGHTS}/side-chat.md": self.HIGHLIGHT_NO_PICTURE.replace(
                "category: new\n", "category: new\ngallery: agent-pane.side-chat/open\n")},
            "clip spec": {f"{self.HIGHLIGHTS}/side-chat.md": self.HIGHLIGHT_NO_PICTURE,
                          "release-notes/next/clips/side-chat.json": "{}\n"},
            "gallery change": {f"{self.HIGHLIGHTS}/side-chat.md": self.HIGHLIGHT_NO_PICTURE,
                               "webviews/src/side/SideChat.gallery.ts": "export {};\n"},
            "fixed entry": {f"{self.HIGHLIGHTS}/side-chat.md": self.HIGHLIGHT_NO_PICTURE.replace(
                "category: new", "category: fixed")},
        }
        for name, files in sources.items():
            with self.subTest(source=name):
                self.git("reset", "--quiet", "--hard", "origin/feat-cmux-next")
                for path, text in files.items():
                    self.write(path, text)
                self.commit(f"adds a highlight with a {name}")

                direct = subprocess.run(["python3", "-I", GATE, "--only", "pictures"], cwd=self.repo, env=self.env,
                                        text=True, capture_output=True)

                self.assertEqual(direct.returncode, 0, direct.stdout + direct.stderr)
                self.assertNotIn("no picture source", direct.stdout + direct.stderr)

    def test_an_improvement_on_a_new_gallery_file_needs_its_old_look_marked(self):
        # agent-file-result-cards and agent-web-result-cards (2026-11-09) added their gallery files, so the state
        # rendered at the commit before had nothing to draw and the improvement shipped with no before.
        improved = self.HIGHLIGHT_NO_PICTURE.replace("category: new", "category: improved")
        new_file = "webviews/src/side/SideChat.gallery.ts"
        marked = 'id: "side.chat",\nvariants: {\n  open: {},\n  closed: {\n    note: "Before: one row.",\n  },\n}\n'
        unmarked = 'id: "side.chat",\nvariants: {\n  open: {\n    note: "Selected: open.",\n  },\n}\n'
        named = improved.replace("category: improved\n", "category: improved\ngallery: side.chat/open\n")
        cases = {
            "unmarked": (improved, {new_file: unmarked}, True),
            "a Before note": (improved, {new_file: marked}, False),
            "an old-look name": (improved, {new_file: 'variants: {\n  open: {},\n  "open-before": {},\n}\n'}, False),
            # Review of #39651: a prop or comment is not a variant, one marked file never covers another, and a
            # `gallery:` line with no `before:` renders its before at the commit before too.
            "a prop named before": (improved, {new_file: 'variants: {\n  open: { props: { before: true } },\n}\n'}, True),
            "a second new file unmarked": (improved, {new_file: marked, "webviews/src/side/Other.gallery.ts": unmarked}, True),
            "a gallery line on a new file": (named, {new_file: unmarked}, True),
            "a gallery line and a before line": (named.replace("gallery: side.chat/open\n",
                                                               "gallery: side.chat/open\nbefore: side.chat/closed\n"),
                                                 {new_file: unmarked}, False),
        }
        for name, (highlight, galleries, refused) in cases.items():
            with self.subTest(gallery=name):
                self.git("reset", "--quiet", "--hard", "origin/feat-cmux-next")
                self.write(f"{self.HIGHLIGHTS}/side-chat.md", highlight)
                for path, gallery in galleries.items():
                    self.write(path, gallery)
                self.commit(f"adds an improvement on a new gallery file, {name}")

                direct = subprocess.run(["python3", "-I", GATE, "--only", "pictures"], cwd=self.repo, env=self.env,
                                        text=True, capture_output=True)

                output = direct.stdout + direct.stderr
                self.assertEqual(direct.returncode != 0, refused, output)
                self.assertEqual("gallery file is new, with no before" in output, refused, output)
                self.assertNotIn("no picture source", output)
                if refused:
                    self.assertIn('its note opening "Before:"', output)
                    self.assertNotIn("Give each one a picture", output)

    def test_a_validator_warning_on_stderr_does_not_turn_a_refusal_into_a_pass(self):
        # The validator's result is read from its own file, never from its output: a warning it prints (a future
        # SyntaxWarning) must not make the check fail open (review of #31260).
        digest = self.repo / "scripts/whats-new/digest.py"
        digest.write_text(digest.read_text() + "\nimport sys\nprint('digest: a warning', file=sys.stderr)\n"
                          "print('digest: a note')\n")
        self.commit("the validator prints a warning when it loads")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        before = self.remote_head()
        self.write(f"{self.HIGHLIGHTS}/continue-retry.md", self.HIGHLIGHT_NO_LINK)
        self.commit("adds a highlight with no docs link")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn(f"{self.HIGHLIGHTS}/continue-retry.md: entries[0] (continue-retry): "
                      "needs a tryIt action/deeplink or a docs link", output)
        self.assertNotIn("were not validated", output)



class ToolDownloadFallbackTests(unittest.TestCase):
    """2026-11-08: every GitHub release download answered 504, so every PR's fast gates went red on fetching ast-grep,
    while the release-assets API served the same bytes. The gate fetches a failed release download through that API;
    the pinned sha256 still judges what it got."""

    def test_a_release_download_that_fails_is_fetched_through_the_release_assets_api(self):
        import hashlib, io, json as jsonlib, urllib.error, zipfile
        gate = load_gate_tools()
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w") as zf:
            zf.writestr("tool-bin", "#!/bin/sh\necho ok\n")
        archive = payload.getvalue()
        url = "https://github.com/acme/tool/releases/download/1.2.3/tool-linux.zip"
        tag = "https://api.github.com/repos/acme/tool/releases/tags/1.2.3"
        asset = "https://api.github.com/repos/acme/tool/releases/assets/42"
        asked = []

        @contextlib.contextmanager
        def stream(request, seconds=None, **options):
            # The helper's one HTTP call (deadline_http.stream); an error status raises, as raise_errors does.
            self.assertTrue(options.get("raise_errors"))
            target = request.full_url if hasattr(request, "full_url") else request
            asked.append(target)
            if target == url:
                raise urllib.error.HTTPError(url, 504, "Gateway Time-out", {}, None)
            if target == tag:
                yield io.BytesIO(jsonlib.dumps({"assets": [{"name": "other.zip", "url": asset + "0"},
                                                           {"name": "tool-linux.zip", "url": asset}]}).encode())
                return
            if target == asset:
                self.assertEqual(request.get_header("Accept"), "application/octet-stream")
                yield io.BytesIO(archive)
                return
            raise AssertionError(f"unexpected fetch {target}")

        with tempfile.TemporaryDirectory() as tmp:
            lock = Path(tmp) / "lint-tools.lock"
            lock.write_text(f"tool\t1.2.3\t{gate.platform_key()}\t{url}\t{hashlib.sha256(archive).hexdigest()}\ttool-bin\n")
            old_dir = os.environ.get("CMUX_LINT_TOOLS_DIR")
            os.environ["CMUX_LINT_TOOLS_DIR"] = str(Path(tmp) / "tools")
            try:
                with unittest.mock.patch.object(gate.release_download().deadline_http, "stream", stream):
                    path = gate.ensure_tool(lock, "tool")
            finally:
                if old_dir is None:
                    os.environ.pop("CMUX_LINT_TOOLS_DIR")
                else:
                    os.environ["CMUX_LINT_TOOLS_DIR"] = old_dir
            self.assertTrue(path.is_file() and os.access(path, os.X_OK))
            self.assertEqual(asked, [url, tag, asset])

    def test_the_fast_gates_step_hands_the_fallback_a_token(self):
        # 2026-11-08 run 42471118536: the release download 504'd and the fallback's unauthenticated API call answered
        # 403 "rate limit exceeded" (runners share their IPs' 60 calls an hour). fetch() reads GH_TOKEN.
        workflow = (SOURCE / ".github/workflows/cmux-next-fast-gates.yml").read_text(encoding="utf-8")
        step = workflow.split("- name: Fast gates on the merge", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("GH_TOKEN: ${{ github.token }}", step.split("run:", 1)[0])

    def test_the_fallback_sends_the_token_to_the_api_and_never_on_a_redirect(self):
        import io, json as jsonlib, urllib.error
        gate = load_gate_tools()
        url = "https://github.com/acme/tool/releases/download/1.2.3/tool-linux.zip"
        tag = "https://api.github.com/repos/acme/tool/releases/tags/1.2.3"
        asset = "https://api.github.com/repos/acme/tool/releases/assets/42"
        requests = {}

        @contextlib.contextmanager
        def stream(request, seconds=None, **options):
            self.assertTrue(options.get("follow_redirects", True), "the asset's storage redirect is followed")
            requests[request.full_url] = request
            if request.full_url == url:
                raise urllib.error.HTTPError(url, 504, "Gateway Time-out", {}, None)
            if request.full_url == tag:
                yield io.BytesIO(jsonlib.dumps({"assets": [{"name": "tool-linux.zip", "url": asset}]}).encode())
                return
            yield io.BytesIO(b"archive")

        old_token = os.environ.get("GH_TOKEN")
        os.environ["GH_TOKEN"] = "token-for-test"
        try:
            with tempfile.TemporaryDirectory() as tmp, \
                    unittest.mock.patch.object(gate.release_download().deadline_http, "stream", stream):
                gate.download(url, Path(tmp) / "tool.zip")
        finally:
            if old_token is None:
                os.environ.pop("GH_TOKEN")
            else:
                os.environ["GH_TOKEN"] = old_token
        self.assertIsNone(requests[url].get_header("Authorization"), "the release download itself carries no token")
        for api in (tag, asset):
            self.assertEqual(requests[api].unredirected_hdrs.get("Authorization"), "Bearer token-for-test")
            self.assertNotIn("Authorization", requests[api].headers)
        # The asset answers with a redirect to a signed storage URL: urllib's redirect copies only `headers`.
        signed = urllib.request.HTTPRedirectHandler().redirect_request(
            requests[asset], None, 302, "Found", {}, "https://objects.example/signed?sig=1")
        self.assertIsNone(signed.get_header("Authorization"))


    def test_a_hook_copy_refreshed_without_the_helper_still_downloads_directly(self):
        # An install from before github_release_download.py has the old refresh_checks.py, which rewrites the hook's
        # cmux_next_prepush_gate.py from feat-cmux-next but copies nothing from scripts/ci. That gate must still fetch
        # a tool (the direct download, as before #38349), not refuse every push that has no cached tool.
        import io
        url = "https://github.com/acme/tool/releases/download/1.2.3/tool-linux.zip"
        asked = []

        def urlopen(request, timeout=None):
            asked.append(getattr(request, "full_url", request))
            return io.BytesIO(b"archive")

        with tempfile.TemporaryDirectory() as tmp:
            hook_dir = Path(tmp) / "hooks"
            hook_dir.mkdir()
            shutil.copyfile(SOURCE / GATE, hook_dir / "cmux_next_prepush_gate.py")
            shutil.copyfile(SOURCE / "scripts/cmux-next/git_batch.py", hook_dir / "git_batch.py")
            spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate_refreshed",
                                                          hook_dir / "cmux_next_prepush_gate.py")
            gate = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = gate
            stashed = sys.modules.pop("cmux_github_release_download", None)
            old_open = urllib.request.urlopen
            urllib.request.urlopen = urlopen
            try:
                spec.loader.exec_module(gate)
                gate.download(url, Path(tmp) / "tool.zip")
            finally:
                urllib.request.urlopen = old_open
                sys.modules.pop(spec.name, None)
                sys.modules.pop("cmux_github_release_download", None)
                if stashed is not None:
                    sys.modules["cmux_github_release_download"] = stashed
            self.assertEqual((Path(tmp) / "tool.zip").read_bytes(), b"archive")
        self.assertEqual(asked, [url])

    def test_a_hook_copy_with_the_helper_but_not_its_transport_still_downloads_directly(self):
        # An install from before deadline_http.py has the old refresh_checks.py, which rewrites the gate and
        # github_release_download.py from feat-cmux-next but not deadline_http.py, which the helper imports. That gate
        # must still fetch a tool directly, not fail on the import.
        import io
        url = "https://github.com/acme/tool/releases/download/1.2.3/tool-linux.zip"
        asked = []

        def urlopen(request, timeout=None):
            asked.append(getattr(request, "full_url", request))
            return io.BytesIO(b"archive")

        with tempfile.TemporaryDirectory() as tmp:
            hook_dir = Path(tmp) / "hooks"
            hook_dir.mkdir()
            shutil.copyfile(SOURCE / GATE, hook_dir / "cmux_next_prepush_gate.py")
            shutil.copyfile(SOURCE / "scripts/cmux-next/git_batch.py", hook_dir / "git_batch.py")
            shutil.copyfile(SOURCE / "scripts/ci/github_release_download.py", hook_dir / "github_release_download.py")
            spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate_no_transport",
                                                          hook_dir / "cmux_next_prepush_gate.py")
            gate = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = gate
            stashed = {name: sys.modules.pop(name, None) for name in ("cmux_github_release_download", "deadline_http")}
            old_path = list(sys.path)
            # Only the hook folder offers deadline_http, and it has none.
            ci = (SOURCE / "scripts/ci").resolve()
            sys.path[:] = [entry for entry in sys.path if Path(entry or ".").resolve() != ci]
            old_open = urllib.request.urlopen
            urllib.request.urlopen = urlopen
            try:
                spec.loader.exec_module(gate)
                self.assertIsNone(gate.release_download())
                gate.download(url, Path(tmp) / "tool.zip")
            finally:
                urllib.request.urlopen = old_open
                sys.path[:] = old_path
                sys.modules.pop(spec.name, None)
                for name, module in stashed.items():
                    sys.modules.pop(name, None)
                    if module is not None:
                        sys.modules[name] = module
            self.assertEqual((Path(tmp) / "tool.zip").read_bytes(), b"archive")
        self.assertEqual(asked, [url])


class StaleInstallTests(unittest.TestCase):
    """The check trees never take the pushed head's scripts/swift_source_mask.py on a hook run."""

    def test_the_trees_refuse_an_install_without_the_masker_and_never_write_the_pushed_one(self):
        gate = load_gate_tools()
        with tempfile.TemporaryDirectory(prefix="cmux-stale-install-") as temporary:
            root = Path(temporary)
            repo = root / "repo"
            env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
            run = lambda *args: subprocess.run(["git", "-C", str(repo), *args], env=env, check=True,
                                               capture_output=True)
            repo.mkdir()
            run("init", "--quiet")
            (repo / "scripts/cmux-next").mkdir(parents=True)
            (repo / "scripts/cmux-next/check-x.py").write_text("print('x')\n")
            (repo / "scripts/swift_source_mask.py").write_text("PUSHED = True\n")
            run("add", "-A")
            run("-c", "user.email=a@b", "-c", "user.name=n", "commit", "--quiet", "-m", "x")
            head = run("rev-parse", "HEAD").stdout.decode().strip()
            trusted = root / "trusted"
            trusted.mkdir()
            (trusted / "check-x.py").write_text("print('reviewed')\n")
            with self.assertRaises(SystemExit) as raised:
                gate.build_trees(repo, head, head, [], root / "work-stale", trusted)
            self.assertIn("the installed hook is older than the checks this push needs", str(raised.exception))
            (trusted / "swift_source_mask.py").write_text("PUSHED = False\n")
            base_tree, head_tree = gate.build_trees(repo, head, head, [], root / "work", trusted)
            for tree in (base_tree, head_tree):
                self.assertNotIn("PUSHED = True", (tree / "scripts/swift_source_mask.py").read_text()
                                 if (tree / "scripts/swift_source_mask.py").exists() else "")
                self.assertIn("PUSHED = False", (tree / "scripts/cmux-next/swift_source_mask.py").read_text())


class SwiftFormatCacheTests(unittest.TestCase):
    """The gate lints throwaway trees (base and head under a fresh temporary folder per run), and SwiftFormat keys
    its cache by absolute path, so a persistent cache can never hit: it only grows (335 MB on a busy machine, ~50 s
    to read and rewrite on every call, even for one file). The lint must keep no cache file and still report."""

    def test_linting_a_throwaway_tree_keeps_no_cache_and_still_reports(self):
        spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate_sf", SOURCE / GATE)
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        with tempfile.TemporaryDirectory() as tmp:
            tools, tree = Path(tmp) / "tools", Path(tmp) / "head"
            tools.mkdir()
            (tree / "Sources").mkdir(parents=True)
            (tree / "Sources" / "A.swift").write_text("let a = 1 \n")
            # A stand-in SwiftFormat: like the real one, it writes the cache file it is given (unless `ignore`)
            # and prints one finding per file.
            fake = Path(tmp) / "swiftformat"
            fake.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "args = sys.argv[1:]\n"
                "cache = args[args.index('--cache') + 1] if '--cache' in args else None\n"
                "if cache != 'ignore':\n"
                "    open(cache or 'default.cache', 'a').write('entry\\n')\n"
                "for path in [a for a in args if a.endswith('.swift')]:\n"
                "    print(f'{path}:1:10: error: (trailingSpace) Remove trailing space at end of a line.', file=sys.stderr)\n"
                "sys.exit(1)\n")
            fake.chmod(0o755)
            saved = os.environ.get("CMUX_LINT_TOOLS_DIR")
            os.environ["CMUX_LINT_TOOLS_DIR"] = str(tools)
            try:
                out = gate.swiftformat(fake, tree / "swiftformat.conf", tree, ["Sources/A.swift"])
            finally:
                if saved is None:
                    os.environ.pop("CMUX_LINT_TOOLS_DIR", None)
                else:
                    os.environ["CMUX_LINT_TOOLS_DIR"] = saved
            self.assertIn("Sources/A.swift:1:10", out)
            self.assertEqual(sorted(p.name for p in tools.iterdir()), [], "the lint left a cache file in the tools folder")
            self.assertFalse((tree / "default.cache").exists(), "the lint fell back to a default cache file")


def _pinned_rustfmt_runs() -> bool:
    """Whether the rustfmt that cmux-tui/rust-toolchain.toml pins runs here (never installed for a test)."""
    try:
        done = subprocess.run(["rustfmt", "--version"], cwd=SOURCE / "cmux-tui", capture_output=True, timeout=30,
                              env={**os.environ, "RUSTUP_AUTO_INSTALL": "0"})
    except (OSError, subprocess.TimeoutExpired):
        return False
    return done.returncode == 0


NEEDS_RUSTFMT = unittest.skipUnless(_pinned_rustfmt_runs(), "the pinned rustfmt is not installed here")
RUST_UNFORMATTED = "pub fn hint(a: u32,b: u32)->u32{ a+b }\n"
RUST_FORMATTED = "pub fn hint(a: u32, b: u32) -> u32 {\n    a + b\n}\n"


class RustfmtLayerTests(unittest.TestCase):
    """2026-11-05: three tip rust-fmt reds in an hour (#36358, #36524, #36260). Each PR's head left a cmux-tui file
    unformatted, its warn-only CI rustfmt said so and passed, and it merged on compile before the tip fmt check.
    The pre-push gate now judges each changed cmux-tui Rust file with the pinned rustfmt."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate_rf", SOURCE / GATE)
        self.gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.gate)
        self.tmp = tempfile.TemporaryDirectory()
        self.tree = Path(self.tmp.name)
        self.config = SOURCE / "cmux-tui" / "rustfmt.toml"

    def tearDown(self):
        self.tmp.cleanup()

    def judge(self, files: dict[str, str]) -> str:
        for path, text in files.items():
            (self.tree / path).parent.mkdir(parents=True, exist_ok=True)
            (self.tree / path).write_text(text)
        return self.gate.rustfmt(SOURCE, self.config, self.tree, sorted(files))

    @NEEDS_RUSTFMT
    def test_an_unformatted_changed_file_is_a_finding(self):
        out = self.judge({"cmux-tui/crates/x/src/hint.rs": RUST_UNFORMATTED})
        self.assertIn("cmux-tui/crates/x/src/hint.rs: not rustfmt-clean", out)

    @NEEDS_RUSTFMT
    def test_a_formatted_file_is_no_finding(self):
        self.assertEqual(self.judge({"cmux-tui/crates/x/src/hint.rs": RUST_FORMATTED}), "")

    @NEEDS_RUSTFMT
    def test_only_the_changed_file_is_judged_not_the_modules_it_names(self):
        # lib.rs names `mod child;`; the unformatted child is not in the push, so it is not judged.
        (self.tree / "cmux-tui/crates/x/src").mkdir(parents=True)
        (self.tree / "cmux-tui/crates/x/src/child.rs").write_text(RUST_UNFORMATTED)
        self.assertEqual(self.judge({"cmux-tui/crates/x/src/lib.rs": "mod child;\n"}), "")

    @NEEDS_RUSTFMT
    def test_a_crate_outside_the_cmux_tui_workspace_is_not_judged(self):
        # cmux-rd-host: its own [workspace] (and edition 2021), outside `cargo fmt --all` in cmux-tui.
        (self.tree / "cmux-tui/crates/own").mkdir(parents=True)
        (self.tree / "cmux-tui/crates/own/Cargo.toml").write_text(
            '[package]\nname = "own"\nedition = "2021"\n\n[workspace]\n')
        self.assertEqual(self.judge({"cmux-tui/crates/own/src/lib.rs": RUST_UNFORMATTED}), "")

    @NEEDS_RUSTFMT
    def test_a_workspace_crate_is_still_judged(self):
        (self.tree / "cmux-tui/crates/member").mkdir(parents=True)
        (self.tree / "cmux-tui/crates/member/Cargo.toml").write_text(
            '[package]\nname = "member"\nedition.workspace = true\n')
        out = self.judge({"cmux-tui/crates/member/src/lib.rs": RUST_UNFORMATTED})
        self.assertIn("cmux-tui/crates/member/src/lib.rs: not rustfmt-clean", out)

    def test_no_rustfmt_warns_and_finds_nothing(self):
        saved = os.environ.get("PATH", "")
        os.environ["PATH"] = self.tmp.name  # no rustfmt and no rustup proxy on it
        try:
            out = self.judge({"cmux-tui/crates/x/src/hint.rs": RUST_UNFORMATTED})
        finally:
            os.environ["PATH"] = saved
        self.assertEqual(out, "")


class StopCleanlyTests(unittest.TestCase):
    """The gate stops what it started with SIGTERM first, so a `git` under it clears `.git/index.lock`.

    A `git` that refreshes a stale index holds that lock while it writes the index back, and removes it on
    SIGTERM but not on SIGKILL (measured: 3 of 3 runs left it on SIGKILL, 0 of 3 on SIGTERM). The stale lock
    then refuses the developer's next git command with no process alive to blame (live-apply-nightly, three
    times on 2026-11-04). The stand-in below holds and clears a lock the way git does.
    """

    HOLDS_A_LOCK = ("#!/usr/bin/env python3\n"
                    "import os, signal, sys, time\n"
                    "lock = sys.argv[1]\n"
                    "signal.signal(signal.SIGTERM, lambda *_: (os.remove(lock), sys.exit(143)))\n"
                    "open(lock, 'w').close()\n"
                    "open(sys.argv[2], 'w').close()\n"  # it has the lock now
                    "time.sleep(300)\n")

    def _holder(self, folder: Path) -> Path:
        script = folder / "holds-a-lock.py"
        script.write_text(self.HOLDS_A_LOCK)
        script.chmod(0o755)
        return script

    def _wait_for(self, path: Path) -> None:
        for _ in range(500):
            if path.exists():
                return
            time.sleep(0.02)
        self.fail(f"{path.name} never appeared")

    def test_stopping_a_process_lets_it_clear_its_lock(self):
        gate = load_gate_tools()
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            lock, held = folder / "index.lock", folder / "held"
            process = subprocess.Popen([sys.executable, str(self._holder(folder)), str(lock), str(held)])
            try:
                self._wait_for(held)
                gate.stop([process.pid])
                process.wait(timeout=30)
            finally:
                if process.poll() is None:
                    process.kill()
            self.assertFalse(lock.exists(), "the stopped process was killed outright and left its lock behind")

    def test_a_timed_out_check_leaves_no_lock_behind(self):
        gate = load_gate_tools()
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            lock, held = folder / "index.lock", folder / "held"
            code, out = gate.run([sys.executable, str(self._holder(folder)), str(lock), str(held)], folder, timeout=2)
            self.assertEqual(code, 124, out)
            self.assertFalse(lock.exists(), "the timed-out check's process left its lock behind")


if __name__ == "__main__":
    unittest.main()
