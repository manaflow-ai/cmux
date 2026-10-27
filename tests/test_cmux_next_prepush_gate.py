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
