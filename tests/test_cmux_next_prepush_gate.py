#!/usr/bin/env python3
"""The pre-push hook refuses a push that adds a cmux-next static-check violation.

Each test builds a throwaway repository with the real hook installer, the real
scripts/cmux-next checks and a small CmuxNext package, then pushes to a bare
`origin` through the real `git push`, so the installed trusted hook copy is what
runs. The base already carries a `try!` (base debt): only what a push adds counts.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


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
        self.global_config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n")
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
            "scripts/web-lint.sh",
            "scripts/merge-xcstrings.py",
            "scripts/merge-pbxproj.py",
            "scripts/merge-baseline.py",
            "scripts/merge-daemon-capabilities.py",
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
                   self.DEPS_PACKAGE.replace('dependencies: ["CmuxNextKit"]', 'dependencies: ["CmuxNextKit", "CmuxNextApp"]'))
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
                   self.DEPS_PACKAGE.replace('dependencies: ["CmuxNextKit"]', 'dependencies: ["CmuxNextKit", "CmuxNextApp"]'))
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
                   self.DEPS_PACKAGE.replace('dependencies: ["CmuxNextKit"]', 'dependencies: ["CmuxNextApp", "CmuxNextKit"]'))
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
    HIGHLIGHT_WITH_DOCS = ("title: Continue a stopped reply\ncategory: improved\ndocs: https://cmux.com/docs/chief\n\n"
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


if __name__ == "__main__":
    unittest.main()
