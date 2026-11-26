#!/usr/bin/env python3
"""red-autofix (scripts/ci/red_autofix.py): a red on main, feat-cmux-next or nightly-next names its files, its
errors and its culprit merge; a candidate fix is green when it fixes a check the tip fails and breaks none; the
first green of the fix and the revert lands and closes the other. Fixtures are lines of the real 2026-11-25 nightly
reds (TS2339 rollingSummary, E0063 overlay, pack-objects signal 6); a temporary git history; a fake api; no network.

Run: python3 -I tests/test_ci_red_autofix.py"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import red_autofix as ra  # noqa: E402



def sanitized_git_env(env) -> dict:
    """No inherited git config reaches the tests' repositories (CodeRabbit 4691805887): no global or system file,
    no GIT_CONFIG_COUNT/KEY/VALUE or GIT_CONFIG_PARAMETERS (a runner's auth header, a developer's hooks)."""
    out = {k: v for k, v in env.items() if not (k.startswith("GIT_CONFIG") or k in {"GIT_DIR", "GIT_WORK_TREE",
                                                                                   "GIT_INDEX_FILE"})}
    out.update({"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"})
    return out


def setUpModule():
    # red_autofix's own git calls inherit os.environ: sanitize it for this module, restore it after.
    patcher = mock.patch.dict(os.environ, clear=True)
    saved = dict(os.environ)
    patcher.start()
    os.environ.update(sanitized_git_env(saved))
    unittest.addModuleCleanup(patcher.stop)


ENV = {**sanitized_git_env(os.environ), "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}

TS_LOG = (
    "early-nightly-webviews\tTypecheck\t2026-11-25T06:31:02.1234567Z \x1b[36;1mbun run typecheck\x1b[0m\n"
    "early-nightly-webviews\tTypecheck\t2026-11-25T06:31:09.1234567Z   x typescript(TS2339): Property "
    "'rollingSummary' does not exist on type 'AcpSession'.\n"
    "early-nightly-webviews\tTypecheck\t2026-11-25T06:31:09.1234567Z      ╭─[src/agent-session/acpmux/App.tsx:412:31]\n"
    "early-nightly-webviews\tTypecheck\t2026-11-25T06:31:09.2Z error: script \"typecheck\" exited with code 1\n"
    "early-nightly-webviews\tTypecheck\t2026-11-25T06:31:09.3Z ##[error]Process completed with exit code 1.\n"
)
RUST_LOG = (
    "error[E0063]: missing field `overlay` in initializer of `DialPlan`\n"
    "   --> crates/cmux-mobile-link/src/dial/wireguard_dormant.rs:583:9\n"
    "    |\n"
    "583 |         DialPlan {\n"
    "warning: unused import\n"
    "   --> crates/cmux-mobile-link/src/lib.rs:3:5\n"
)
INFRA_LOG = "fatal: pack-objects died of signal 6\nerror: remote unpack failed\n##[error]Process completed with exit code 128.\n"

TREE = [
    "webviews/src/agent-session/acpmux/App.tsx",
    "webviews/src/agent-session/App.tsx",
    "webviews/package.json",
    "cmux-next-ios/rust/crates/cmux-mobile-link/src/dial/wireguard_dormant.rs",
    "cmux-next-ios/rust/crates/cmux-mobile-link/src/lib.rs",
    "scripts/ci/run-typecheck.sh",
]


class ParseTests(unittest.TestCase):
    def test_strip_log_drops_job_step_stamp_and_ansi(self):
        lines = ra.strip_log(TS_LOG)
        self.assertEqual(lines[0], "bun run typecheck")
        self.assertTrue(lines[1].startswith("  x typescript(TS2339)"))

    def test_ts_red_names_its_site_error_name_and_script(self):
        lines = ra.strip_log(TS_LOG)
        blocks = ra.error_blocks(lines)
        self.assertNotIn("bun run typecheck", blocks, "a shell echo line is not an error")
        self.assertEqual(ra.error_sites(blocks, TREE), ["webviews/src/agent-session/acpmux/App.tsx"])
        self.assertIn("rollingSummary", ra.error_names(blocks))
        self.assertEqual(ra.bun_scripts(lines), ["typecheck"])
        self.assertEqual(ra.language(ra.error_sites(blocks, TREE), lines), "ts")
        # oxc prints the code and the file on separate lines: the key is the code alone.
        self.assertEqual(ra.error_keys(blocks, ["webviews/src/agent-session/acpmux/App.tsx"]), ["TS2339"])

    def test_rust_red_block_stops_at_the_next_warning(self):
        lines = ra.strip_log(RUST_LOG)
        blocks = ra.error_blocks(lines)
        self.assertFalse(any("lib.rs" in b for b in blocks))
        sites = ra.error_sites(blocks, TREE)
        self.assertEqual(sites, ["cmux-next-ios/rust/crates/cmux-mobile-link/src/dial/wireguard_dormant.rs"])
        self.assertEqual(ra.language(sites, lines), "rust")
        self.assertIn("overlay", ra.error_names(blocks))
        self.assertEqual(ra.classify(lines, sites), "code")

    def test_resolve_needs_one_file(self):
        by_name: dict[str, list[str]] = {}
        for f in TREE:
            by_name.setdefault(f.rsplit("/", 1)[-1], []).append(f)
        self.assertEqual(ra.resolve("acpmux/App.tsx", by_name), "webviews/src/agent-session/acpmux/App.tsx")
        self.assertEqual(ra.resolve("App.tsx", by_name), "", "two App.tsx files: ambiguous names none")
        self.assertEqual(ra.resolve("/home/runner/work/cmux/cmux/webviews/package.json", by_name),
                         "webviews/package.json")

    def test_infra_red_is_infra(self):
        self.assertEqual(ra.classify(ra.strip_log(INFRA_LOG), []), "infra")

    def test_pr_of(self):
        self.assertEqual(ra.pr_of("Drop rollingSummary (#51813)"), "51813")
        self.assertEqual(ra.pr_of("Merge pull request #49723 from x/y"), "49723")
        self.assertEqual(ra.pr_of("plain commit"), "")

    def test_mode(self):
        for value, want in (("0", "off"), ("off", "off"), ("pr", "pr"), ("", "on"), ("1", "on")):
            with mock.patch.dict(os.environ, {"RED_AUTOFIX": value}):
                self.assertEqual(ra.mode(), want, value)




def git(cwd: Path, *argv: str) -> str:
    return subprocess.run(["git", *argv], cwd=cwd, env=ENV, check=True, capture_output=True, text=True).stdout


def commit(repo: Path, files: dict[str, str], subject: str) -> str:
    for name, text in files.items():
        (repo / name).parent.mkdir(parents=True, exist_ok=True)
        (repo / name).write_text(text)
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", subject)
    return git(repo, "rev-parse", "HEAD").strip()


def local_sandbox(test: unittest.TestCase) -> ra.Sandbox:
    """A sandbox without the uid switch (the tests have no sudo): same trees, same env -i."""
    root = Path(tempfile.mkdtemp(prefix="red-verify-test-"))
    test.addCleanup(lambda: subprocess.run(["rm", "-rf", "--", str(root)], check=False))
    return ra.Sandbox(root, None)


class FakeSandbox(ra.Sandbox):
    """Each check's answer by tree ("cand" or "tip") and command: {(tree, cmd): (returncode, output)}."""

    def __init__(self, test, answers: dict):
        super().__init__(Path(tempfile.mkdtemp(prefix="red-fake-")), None)
        test.addCleanup(lambda: subprocess.run(["rm", "-rf", "--", str(self.root)], check=False))
        self.answers = answers

    def run(self, cmd, cwd):
        tree = Path(cwd).relative_to(self.root).parts[0]
        rc, out = self.answers.get((tree, cmd), (0, ""))
        return subprocess.CompletedProcess(cmd, rc, out, "")


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q", "-b", "main")
        self.good = commit(self.repo, {"pkg/a.py": "x = 1\n", "pkg/b.py": "y = 2\n"}, "base")

    def tearDown(self):
        self.tmp.cleanup()

    def test_semantic_clash_narrows_to_the_commit_that_uses_the_name(self):
        # #51813 removes the field, #49723 still uses it; both touch the named file; the error quotes the name.
        commit(self.repo, {"pkg/a.py": "x = 1\nz = 3\n"}, "Unrelated edit (#50000)")
        commit(self.repo, {"pkg/a.py": "x = 1\nz = 3\nsummary = session.rollingSummary\n"}, "Use it (#49723)")
        red = commit(self.repo, {"other/c.py": "w = 4\n"}, "Other dir (#51000)")
        commits = ra.range_commits(self.repo, self.good, red)
        self.assertEqual([c["pr"] for c in commits], ["50000", "49723", "51000"])
        culprit, confirmed, _ = ra.pick_culprit(commits, ["pkg/a.py"])
        self.assertFalse(confirmed, "two commits touched the file")
        culprit, confirmed, _ = ra.pick_culprit(commits, ["pkg/a.py"], self.repo, ["rollingSummary"])
        self.assertTrue(confirmed)
        self.assertEqual(culprit["pr"], "49723")

    def test_one_commit_range_is_confirmed(self):
        red = commit(self.repo, {"pkg/b.py": "y = (\n"}, "Break (#7)")
        culprit, confirmed, _ = ra.pick_culprit(ra.range_commits(self.repo, self.good, red), [])
        self.assertTrue(confirmed)
        self.assertEqual(culprit["sha"], red)

    def test_truncated_range_confirms_no_culprit(self):
        # CodeRabbit 4691805817: past MAX_RANGE only the newest commits are read; an older one may be the culprit.
        commit(self.repo, {"pkg/a.py": "x = 2\n"}, "Old touch (#1)")
        commit(self.repo, {"other/c.py": "w = 1\n"}, "Other (#2)")
        red = commit(self.repo, {"pkg/a.py": "x = (\n"}, "Break (#3)")
        with mock.patch.object(ra, "MAX_RANGE", 2):
            self.assertTrue(ra.range_truncated(self.repo, self.good, red))
            commits = ra.range_commits(self.repo, self.good, red)
            self.assertEqual([c["pr"] for c in commits], ["2", "3"])
            culprit, confirmed, _ = ra.pick_culprit(commits, ["pkg/a.py"], truncated=True)
            self.assertEqual(culprit["pr"], "3")
            self.assertFalse(confirmed, "the cut-off #1 touched the file too")
            self.assertFalse(ra.pick_culprit(commits[-1:], [], truncated=True)[1])
        self.assertFalse(ra.range_truncated(self.repo, self.good, red))

    def test_verify_green_only_when_the_candidate_fixes_the_tip_red(self):
        commit(self.repo, {"pkg/a.py": "x = (\n"}, "Break a (#8)")
        report = {"lang": "python", "paths": ["pkg/a.py"], "sites": ["pkg/a.py"], "errors": []}
        commit(self.repo, {"pkg/a.py": "x = 1\n"}, "red-autofix: fix")
        ok, why = ra.verify(report, self.repo, local_sandbox(self))
        self.assertTrue(ok, why)
        git(self.repo, "reset", "-q", "--hard", "HEAD~1")
        commit(self.repo, {"pkg/b.py": "y = 3\n"}, "red-autofix: no fix")
        ok, why = ra.verify(report, self.repo, local_sandbox(self))
        self.assertFalse(ok)
        self.assertIn("still fails", why)

    def test_verify_red_when_the_red_no_longer_reproduces_on_the_tip(self):
        # CodeRabbit 4691805869: a candidate on a tip that already passes fixes nothing.
        report = {"lang": "python", "paths": ["pkg/a.py"], "sites": ["pkg/a.py"], "errors": []}
        commit(self.repo, {"pkg/b.py": "y = 3\n"}, "red-autofix: no-op")
        ok, why = ra.verify(report, self.repo, local_sandbox(self))
        self.assertFalse(ok)
        self.assertIn("no longer reproduces", why)

    def test_verify_with_no_local_check_defers_to_pr_checks(self):
        commit(self.repo, {"A.swift": "let a = 1\n"}, "red-autofix: swift")
        ok, why = ra.verify({"lang": "swift", "paths": ["A.swift"], "sites": [], "errors": []}, self.repo,
                            local_sandbox(self))
        self.assertFalse(ok)
        self.assertIn("pull request's own checks", why)

    def test_candidate_runs_without_the_runner_env_or_git_dir(self):
        # CodeRabbit 4691805808: candidate code never sees GITHUB_OUTPUT, a token or the checkout's .git.
        commit(self.repo, {"pkg/a.py": "x = 3\n"}, "candidate")
        box = local_sandbox(self)
        cand, tip = box.prepare(self.repo)
        with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(box.root / "out"), "GH_TOKEN": "secret"}):
            done = box.run('echo "out=${GITHUB_OUTPUT:-unset} token=${GH_TOKEN:-unset}"; ls -a', cand)
        self.assertIn("out=unset token=unset", done.stdout)
        self.assertNotIn(".git", done.stdout.split())
        self.assertEqual((cand / "pkg/a.py").read_text(), "x = 3\n")
        self.assertEqual((tip / "pkg/a.py").read_text(), "x = 1\n")

    def test_isolation_that_cannot_be_set_up_fails_closed(self):
        def no_sudo(argv, **_):
            return subprocess.CompletedProcess(argv, 1, "", "sudo: a password is required")

        with self.assertRaises(ra.IsolationError):
            ra.Sandbox.isolated("python", run=no_sudo)
        commit(self.repo, {"pkg/a.py": "x = 3\n"}, "candidate")
        report = {"repo": "o/r", "lang": "python", "paths": ["pkg/a.py"], "sites": [], "errors": [], "jobs": []}
        (self.repo / "report.json").write_text(ra.json.dumps(report))
        out = self.repo / "gh-out"
        with mock.patch.object(ra.Sandbox, "isolated", side_effect=ra.IsolationError("no sudo")), \
                mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": ""}), \
                mock.patch("builtins.print"):
            ra.main(["verify", "--report", str(self.repo / "report.json"), "--repo-dir", str(self.repo),
                     "--sha", "a" * 40])
        self.assertIn("green=false", out.read_text())


class VerifyVerdictTests(unittest.TestCase):
    """The verdict from the checks' answers on both trees (a fake sandbox)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q", "-b", "main")
        pkg = '{"scripts": {"typecheck": "tsc", "lint": "oxlint", "test": "vitest"}}\n'
        commit(self.repo, {"web/package.json": pkg, "web/src/a.ts": "a\n"}, "tip")
        commit(self.repo, {"web/src/a.ts": "b\n"}, "candidate")
        self.report = {"lang": "ts", "paths": ["web/src/a.ts"], "sites": ["web/src/a.ts"], "errors": ["TS2339"],
                       "scripts": ["lint", "test"]}

    def tearDown(self):
        self.tmp.cleanup()

    def verdict(self, answers):
        return ra.verify(self.report, self.repo, FakeSandbox(self, answers))

    def test_named_scripts_run_without_a_typecheck_stand_in(self):
        # CodeRabbit 4691805868: a red that named its scripts is checked by exactly those.
        _, checks = ra.verify_commands(self.report, self.repo)
        self.assertEqual([c[2] for c in checks], ["bun run lint", "bun run test"])
        _, checks = ra.verify_commands({**self.report, "scripts": ["build"]}, self.repo)
        self.assertEqual(checks, [], "a named script the package lacks is no reason to run typecheck")
        _, checks = ra.verify_commands({**self.report, "scripts": []}, self.repo)
        self.assertEqual([c[2] for c in checks], ["bun run typecheck"])

    def test_incident_cleared_with_an_unrelated_tip_red_left(self):
        ok, why = self.verdict({("tip", "bun run lint"): (1, "error TS2339: x"),
                                ("tip", "bun run test"): (1, "flaky"), ("cand", "bun run test"): (1, "flaky")})
        self.assertTrue(ok, why)
        self.assertIn("not this red's", why)

    def test_incident_still_failing_is_red(self):
        # CodeRabbit 4691805876: fixing the unrelated tip red while the red's own failure stays is no fix.
        ok, why = self.verdict({("tip", "bun run lint"): (1, "error TS2339: x"),
                                ("cand", "bun run lint"): (1, "error TS2339: x"),
                                ("tip", "bun run test"): (1, "flaky")})
        self.assertFalse(ok)
        self.assertIn("red's own failures", why)

    def test_new_failure_is_red(self):
        ok, why = self.verdict({("tip", "bun run lint"): (1, "error TS2339: x"), ("cand", "bun run test"): (1, "x")})
        self.assertFalse(ok)
        self.assertIn("passed on the tip", why)

    def test_tip_failing_for_another_reason_is_not_the_red(self):
        ok, why = self.verdict({("tip", "bun run lint"): (1, "some other error")})
        self.assertFalse(ok)
        self.assertIn("no longer reproduce", why)


class TriageTests(unittest.TestCase):
    def run_triage(self, routes, attempt):
        api = FakeApi(routes)
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"RED_AUTOFIX": "1"}):
            return ra.triage("o/r", "7", Path(tmp), api=api, attempt=attempt, now="2026-11-25T10:00:30Z"), api

    RUN = {"head_branch": "main", "name": "CI", "conclusion": "failure", "head_sha": "f" * 40, "workflow_id": 3,
           "event": "push", "updated_at": "2026-11-25T10:00:00Z"}

    def test_reads_the_triggering_attempt(self):
        # CodeRabbit 4691805827: every read pins the attempt that fired the trigger.
        out, api = self.run_triage({("GET", "repos/o/r/actions/runs/7"): {**self.RUN, "run_attempt": 2},
                                    ("GET", "repos/o/r/actions/runs/7/attempts/2"): {**self.RUN, "run_attempt": 2},
                                    ("GET", "repos/o/r/actions/runs/7/attempts/2/jobs"): {"jobs": []}}, "2")
        self.assertEqual(out["why"], "no failed job")
        self.assertIn(("GET", "repos/o/r/actions/runs/7/attempts/2/jobs?per_page=100", None), api.calls)
        self.assertEqual(out["elapsed"], {"detected_to_triage": 30})

    def test_a_newer_attempt_supersedes(self):
        out, api = self.run_triage({("GET", "repos/o/r/actions/runs/7"): {**self.RUN, "run_attempt": 3},
                                    ("GET", "repos/o/r/actions/runs/7/attempts/2"): {**self.RUN, "run_attempt": 2}},
                                   "2")
        self.assertIn("supersedes", out["why"])
        self.assertFalse(any("jobs" in p for _, p, _ in api.calls))

    def test_unread_logs_report_instead_of_a_blind_fix(self):
        # The 2026-11-25 nightly duplicate-key red (run 45589942841): gh refused every log, the fixer ran blind.
        refused = RuntimeError("gh api GET logs: the response contains terminal escape sequences")
        job = {"id": 9, "name": "nightly-next-one", "conclusion": "failure", "steps": []}
        out, _ = self.run_triage({("GET", "repos/o/r/actions/runs/7"): self.RUN,
                                  ("GET", "repos/o/r/actions/runs/7/jobs"): {"jobs": [job]},
                                  ("GET", "repos/o/r/actions/jobs/9/logs"): refused}, "")
        self.assertEqual(out["action"], "report")
        self.assertIn("escape sequences", out["why"])

    def test_stale_open_fix_is_refreshed_and_current_one_stops(self):
        # CodeRabbit 4691805846: a fix refused for a moved base is rebuilt on the new tip by the red's next run.
        report = {"target": "main", "existing": [{"number": 5, "state": "open", "url": "u", "sha": "c" * 40,
                                                  "branch": "autofix/red-k", "base": "main"}]}
        routes = {("GET", "repos/o/r/git/ref/heads/main"): {"object": {"sha": "t" * 40}},
                  ("GET", f"repos/o/r/commits/{'c' * 40}"): {"parents": [{"sha": "t" * 40}]}}
        self.assertIn("in flight", ra.stale_or_stop("o/r", dict(report), api=FakeApi(routes)))
        routes[("GET", f"repos/o/r/commits/{'c' * 40}")] = {"parents": [{"sha": "o" * 40}]}
        moved = dict(report)
        self.assertEqual(ra.stale_or_stop("o/r", moved, api=FakeApi(routes)), "")
        self.assertEqual(moved["refresh"], 5)
        closed = {**report, "existing": [{**report["existing"][0], "state": "closed"}]}
        self.assertIn("already exists", ra.stale_or_stop("o/r", closed, api=FakeApi(routes)))


class ReceiptTests(unittest.TestCase):
    def test_every_stage_has_its_elapsed_seconds(self):
        # ask-05f15b4519: detected→triage, triage→fix pushed, fix→verify, verify→land.
        report: dict = {}
        ra.stamp(report, "detected", "2026-11-25T10:00:00Z")
        ra.stamp(report, "triaged", "2026-11-25T10:00:40Z")
        ra.stamp(report, "pushed", "2026-11-25T10:05:40Z")
        ra.stamp(report, "verified", "2026-11-25T10:09:40Z")
        ra.stamp(report, "landed", "2026-11-25T10:10:00Z")
        self.assertEqual(report["elapsed"], {"detected_to_triage": 40, "triage_to_fix_pushed": 300,
                                             "fix_to_verify": 240, "verify_to_land": 20})
        self.assertEqual(ra.receipt(report), "Elapsed: detected→triage 40 s, triage→fix pushed 300 s, "
                                             "fix→verify 240 s, verify→land 20 s")
        self.assertEqual(ra.receipt({}), "Elapsed: none recorded")


class RegenTests(unittest.TestCase):
    """hq#20980: "cmux-next / cmux-next generated files" was red on feat-cmux-next; the red job had already uploaded
    the regenerated files. The fix is a copy of them, with no model call."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.repo, self.files = root / "repo", root / "artifact"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "feat-cmux-next")
        self.red = commit(self.repo, {"plans/cmux-next/actions.json": "{}\n", "README.md": "hi\n"}, "base")
        stale = {"plans/cmux-next/actions.json": '{"a": 1}\n', "plans/cmux-next/new.md": "# new\n",
                 "README.md": "planted\n", ".paths": "plans/cmux-next/actions.json\nplans/cmux-next/new.md\n"
                 "README.md\n../escape.json\n"}
        for name, text in stale.items():
            (self.files / name).parent.mkdir(parents=True, exist_ok=True)
            (self.files / name).write_text(text)
        self.report = {"regen": "cmux-next-generated-patch", "red": self.red}

    def tearDown(self):
        self.tmp.cleanup()

    def test_generated_files_job_is_a_regen_red(self):
        spec = ra.REGEN[0]
        self.assertTrue(spec["job"].search("cmux-next / cmux-next generated files"))
        self.assertTrue(spec["job"].search("cmux-next generated files (shared build)"))
        self.assertFalse(spec["job"].search("cmux-next / typecheck"))

    def test_copies_only_generated_paths_and_stages_new_files(self):
        copied, _ = ra.apply_regen(self.report, self.files, self.repo)
        self.assertEqual(copied, 2, "README.md and ../escape.json are not generated paths")
        self.assertEqual((self.repo / "README.md").read_text(), "hi\n")
        self.assertFalse((self.repo.parent / "escape.json").exists())
        status = git(self.repo, "status", "--porcelain")
        self.assertIn("A  plans/cmux-next/new.md", status)
        self.assertIn("M  plans/cmux-next/actions.json", status)

    def test_stale_artifact_is_not_applied_on_a_moved_tip(self):
        # CodeRabbit 4691963688: the tip changed a generator input since the red: the model fixer decides.
        commit(self.repo, {"README.md": "input changed\n"}, "moved")
        copied, why = ra.apply_regen(self.report, self.files, self.repo)
        self.assertEqual(copied, 0)
        self.assertIn("stale", why)
        self.assertEqual(git(self.repo, "status", "--porcelain"), "")

    def test_tip_moved_only_in_generated_files_still_applies(self):
        commit(self.repo, {"plans/cmux-next/actions.json": '{"b": 2}\n'}, "regenerated")
        self.assertEqual(ra.apply_regen(self.report, self.files, self.repo)[0], 2)

    def test_no_regen_artifact_copies_nothing(self):
        self.assertEqual(ra.apply_regen({}, self.files, self.repo)[0], 0)
        self.assertEqual(ra.apply_regen(self.report, self.repo / "none", self.repo)[0], 0)

    def test_regen_diff_has_no_size_cap_but_only_generated_files(self):
        self.assertTrue(ra.regen_allowed("cmux-next-generated-patch", "schemas/defaults/cmux-next.json"))
        self.assertFalse(ra.regen_allowed("cmux-next-generated-patch", "plans/cmux-next/../../x.json"))
        self.assertFalse(ra.regen_allowed("other", "plans/cmux-next/actions.json"))


class FixerPatchTests(unittest.TestCase):
    """CodeRabbit 4691805797: the fixer edits a plain copy; only its tracked-file diff, as a patch, reaches a fresh
    clone where the trusted helper commits and pushes."""

    def test_diff_of_the_fixer_copy_applies_to_a_fresh_clone(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target, tree, fresh = root / "target", root / "fixer-tree", root / "fresh"
            target.mkdir()
            git(target, "init", "-q", "-b", "main")
            commit(target, {"a.txt": "one\n", "dir/b.txt": "two\n"}, "tip")
            subprocess.run(["cp", "-a", str(target), str(tree)], check=True)
            subprocess.run(["rm", "-rf", "--", str(tree / ".git")], check=True)
            (tree / "a.txt").write_text("fixed\n")
            (tree / "dir/new.txt").write_text("new\n")
            # A planted repository in the copy carries no config, hooks or index across.
            (tree / ".git").mkdir()
            (tree / ".git/config").write_text("[core]\n\tfsmonitor = touch /tmp/pwned\n")
            patch = root / "fix.patch"
            with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(root / "out")}):
                self.assertEqual(ra.main(["diff", "--repo-dir", str(target), "--tree", str(tree),
                                          "--out", str(patch)]), 0)
            text = patch.read_text()
            self.assertIn("+fixed", text)
            self.assertIn("dir/new.txt", text)
            self.assertNotIn(".git/config", text)
            self.assertIn("changed=true", (root / "out").read_text())
            git(root, "clone", "-q", "--no-hardlinks", f"file://{target}", str(fresh))
            git(fresh, "apply", "--index", "--binary", str(patch))
            self.assertEqual((fresh / "a.txt").read_text(), "fixed\n")
            self.assertIn("A  dir/new.txt", git(fresh, "status", "--porcelain"))


class FakeApi:
    def __init__(self, routes: dict):
        self.routes = routes
        self.calls: list[tuple[str, str, dict | None]] = []

    def __call__(self, path, method="GET", fields=None, raw=False):
        self.calls.append((method, path, fields))
        value = self.routes.get((method, path.split("?")[0]))
        if isinstance(value, Exception):
            raise value
        return value


class GhApiTests(unittest.TestCase):
    @staticmethod
    def runner(answers):
        calls = []

        def run(argv, **_):
            calls.append(list(argv))
            code, err, out = answers.pop(0)
            return subprocess.CompletedProcess(argv, code, out, err)
        return run, calls

    def test_raw_log_read_allows_escape_sequences(self):
        run, calls = self.runner([(0, "", "\x1b[31merror\x1b[0m")])
        self.assertIn("error", ra.gh_api("repos/o/r/actions/jobs/9/logs", raw=True, run=run))
        self.assertIn("--allow-escape-sequences", calls[0])

    def test_old_gh_without_the_flag_retries_without_it(self):
        run, calls = self.runner([(1, "unknown flag: --allow-escape-sequences", ""), (0, "", "log")])
        self.assertEqual(ra.gh_api("p", raw=True, run=run), "log")
        self.assertNotIn("--allow-escape-sequences", calls[1])

    def test_installation_rate_limit_is_waited_out(self):
        # Runs 45598154329 and 45600895404 died on "API rate limit exceeded for installation" at their first read.
        run, calls = self.runner([(1, "gh: API rate limit exceeded for installation (HTTP 403)", ""), (0, "", "{}")])
        with mock.patch.object(ra, "_api_waited", 0.0), mock.patch.object(ra.time, "sleep") as slept, \
                mock.patch("sys.stderr"):
            self.assertEqual(ra.gh_api("p", run=run), {})
        slept.assert_called_once_with(60)
        self.assertEqual(len(calls), 2)

    def test_waits_share_one_budget_that_fits_the_job(self):
        # Run 45612343778: per-call waits of up to 15 min, silent, ran triage past its 10-minute job timeout.
        limited = (1, "gh: API rate limit exceeded for installation (HTTP 403)", "")
        run, calls = self.runner([limited] * 12)
        with mock.patch.object(ra, "_api_waited", 0.0), mock.patch.object(ra, "API_WAIT_BUDGET_S", 240), \
                mock.patch.object(ra.time, "sleep") as slept, mock.patch("sys.stderr"):
            with self.assertRaisesRegex(RuntimeError, "wait budget of 240s spent"):
                ra.gh_api("a", run=run)
            with self.assertRaisesRegex(RuntimeError, "wait budget"):
                ra.gh_api("b", run=run)  # a second call has nothing left to wait
        self.assertEqual(sum(c.args[0] for c in slept.call_args_list), 240)
        self.assertEqual(len(calls), 5, "a: 60 + 120 + 60 (capped), then refused; b: refused at its first limit")

    def test_a_real_refusal_raises_at_once(self):
        run, calls = self.runner([(1, "HTTP 404: Not Found", "")])
        with self.assertRaises(RuntimeError):
            ra.gh_api("p", run=run)
        self.assertEqual(len(calls), 1)


BASE = "e" * 40


class LandTests(unittest.TestCase):
    REPORT = {"repo": "o/r", "target": "feat-cmux-next"}

    def pr(self, number, sha="a" * 40, state="open", body="", merged_at=None, ref="", base="feat-cmux-next",
           auto_merge=None):
        return {"number": number, "state": state, "body": body, "merged_at": merged_at, "title": "Fix the red",
                "head": {"sha": sha, "ref": ref or ("autofix/red-k" if number == 1 else "revert/pr-9")},
                "base": {"ref": base}, "auto_merge": auto_merge}

    def run_land(self, routes, env="1", base=BASE, tip=BASE, run=None):
        routes = {("GET", "repos/o/r/git/ref/heads/feat-cmux-next"): {"object": {"sha": tip}}, **routes}
        api = FakeApi(routes)
        with mock.patch.dict(os.environ, {"RED_AUTOFIX": env}):
            return ra.land(self.REPORT, "fix", 1, "a" * 40, "revert/pr-9", base=base, api=api,
                           run=run or mock.Mock(side_effect=AssertionError("no auto-merge expected"))), api

    def test_merges_and_closes_the_open_sibling(self):
        out, api = self.run_land({("GET", "repos/o/r/pulls/1"): self.pr(1),
                                  ("GET", "repos/o/r/pulls"): [self.pr(2, sha="b" * 40)],
                                  ("PUT", "repos/o/r/pulls/1/merge"): {"merged": True}})
        self.assertEqual(out["action"], "merged")
        self.assertIn(("PATCH", "repos/o/r/pulls/2", {"state": "closed"}), api.calls)

    def test_sibling_merged_first_closes_itself(self):
        out, api = self.run_land({("GET", "repos/o/r/pulls/1"): self.pr(1),
                                  ("GET", "repos/o/r/pulls"): [self.pr(2, state="closed", merged_at="t")]})
        self.assertEqual(out["action"], "closed")
        self.assertFalse(any(m == "PUT" for m, _, _ in api.calls))

    def test_sibling_on_another_base_is_not_this_reds(self):
        # CodeRabbit 4691805841: revert/pr-9 onto main is another red's; it neither stops nor gets closed.
        out, api = self.run_land({("GET", "repos/o/r/pulls/1"): self.pr(1),
                                  ("GET", "repos/o/r/pulls"): [self.pr(2, state="closed", merged_at="t", base="main")],
                                  ("PUT", "repos/o/r/pulls/1/merge"): {"merged": True}})
        self.assertEqual(out["action"], "merged")
        self.assertFalse(any(m == "PATCH" for m, _, _ in api.calls))
        self.assertIn("base=feat-cmux-next", next(p for m, p, _ in api.calls if p.startswith("repos/o/r/pulls?")))

    def test_sibling_armed_for_auto_merge_blocks(self):
        # CodeRabbit 4691805854: never merge or arm while the sibling is armed.
        out, api = self.run_land({("GET", "repos/o/r/pulls/1"): self.pr(1),
                                  ("GET", "repos/o/r/pulls"): [self.pr(2, auto_merge={"merge_method": "squash"})]})
        self.assertEqual(out["action"], "none")
        self.assertIn("armed", out["why"])
        self.assertFalse(any(m in {"PUT", "PATCH"} for m, _, _ in api.calls))

    def test_moved_base_or_no_verified_base_refuses(self):
        # CodeRabbit 4691805846: the verdict holds only for the tip it ran on.
        out, api = self.run_land({("GET", "repos/o/r/pulls/1"): self.pr(1)}, tip="d" * 40)
        self.assertEqual(out["action"], "none")
        self.assertIn("moved from the verified", out["why"])
        self.assertFalse(any(m == "PUT" for m, _, _ in api.calls))
        out, _ = self.run_land({("GET", "repos/o/r/pulls/1"): self.pr(1)}, base="")
        self.assertIn("no verified base", out["why"])

    def test_merge_refused_arms_auto_merge(self):
        run = mock.Mock(return_value=subprocess.CompletedProcess([], 0, "", ""))
        out, _ = self.run_land({("GET", "repos/o/r/pulls/1"): self.pr(1), ("GET", "repos/o/r/pulls"): [],
                                ("PUT", "repos/o/r/pulls/1/merge"): RuntimeError("required checks")}, run=run)
        self.assertEqual(out["action"], "armed")
        self.assertIn("--match-head-commit", run.call_args[0][0])

    def test_close_comes_first_and_survives_a_failed_comment(self):
        # CodeRabbit 4691805860.
        api = FakeApi({("POST", "repos/o/r/issues/2/comments"): RuntimeError("502")})
        with mock.patch("builtins.print"):
            ra.close("o/r", 2, "why", api=api)
        self.assertEqual(api.calls[0], ("PATCH", "repos/o/r/pulls/2", {"state": "closed"}))

    def test_moved_head_held_and_pr_mode_never_merge(self):
        out, _ = self.run_land({("GET", "repos/o/r/pulls/1"): self.pr(1, sha="c" * 40)})
        self.assertIn("moved", out["why"])
        out, _ = self.run_land({("GET", "repos/o/r/pulls/1"): self.pr(1, body="HOLD: lawrencecchen's merge.")})
        self.assertEqual(out["action"], "held")
        out, api = self.run_land({}, env="pr")
        self.assertEqual(out["action"], "none")
        self.assertEqual(api.calls, [])

    def test_every_base_and_the_nightly_have_a_target(self):
        self.assertEqual(ra.TARGET["nightly-next"], "feat-cmux-next")
        self.assertEqual(ra.TARGET["main"], "main")


class OpenTests(unittest.TestCase):
    def test_ambiguous_create_resumes_the_pr_at_the_pushed_head(self):
        # CodeRabbit 4691805833: the create timed out after GitHub made the PR; the head+base lookup finds it.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            remote, repo = root / "remote.git", root / "repo"
            git(root, "init", "-q", "--bare", str(remote))
            repo.mkdir()
            git(repo, "init", "-q", "-b", "main")
            commit(repo, {"a.py": "x = (\n"}, "tip")
            (repo / "a.py").write_text("x = 1\n")
            report = {"repo": "o/r", "key": "k", "target": "main", "workflow": "CI", "run_url": "u", "branch": "main",
                      "red": "f" * 40, "jobs": [], "excerpt": [], "culprit": None, "confirmed": False}
            pulls: list = []
            api = FakeApi({("POST", "repos/o/r/pulls"): RuntimeError("HTTP 502: timeout"),
                           ("GET", "repos/o/r/pulls"): pulls})
            with mock.patch.dict(os.environ, {"GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@e"}):
                out = ra.open_pr(report, "fix", repo, str(remote), "s", api=api)
            self.assertEqual(out["action"], "none", "no pull request at the pushed head: not resumed")
            pulls.append({"number": 9, "html_url": "u9", "head": {"sha": out["sha"]}, "base": {"ref": "main"}})
            pulls.append({"number": 8, "html_url": "u8", "head": {"sha": "0" * 40}, "base": {"ref": "main"}})
            self.assertEqual(ra.find_pr("o/r", "autofix/red-k", "main", out["sha"], api=api)["number"], 9)
            self.assertEqual(ra.find_pr("o/r", "autofix/red-k", "feat-cmux-next", out["sha"], api=api), {})

    def test_fix_touching_an_unnamed_workflow_is_refused(self):
        # A pushed branch runs its own workflows with secrets: the fixer's patch may not add one.
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(repo, "init", "-q", "-b", "main")
            commit(repo, {"a.py": "x = (\n"}, "tip")
            (repo / ".github/workflows").mkdir(parents=True)
            (repo / ".github/workflows/x.yml").write_text("on: push\n")
            git(repo, "add", "-A")
            report = {"repo": "o/r", "key": "k", "target": "main", "lang": "python", "paths": ["a.py"]}
            out = ra.open_pr(report, "fix", repo, "/nonexistent", api=FakeApi({}))
            self.assertEqual(out["action"], "none")
            self.assertIn(".github/workflows/x.yml", out["why"])


class ChecksTests(unittest.TestCase):
    def poll(self, runs, ticks=200):
        clock = iter(range(0, ticks * 60, 60))
        return ra.pr_checks_green("o/r", "s", ["CI / typecheck"], api=lambda *_a, **_k: {"check_runs": runs},
                                  wait_min=10, sleep=lambda _s: None, clock=lambda: next(clock))

    def test_expected_check_absent_is_pending_never_green(self):
        # CodeRabbit 4691805880: unrelated green checks do not stand in for the red's own.
        ok, why = self.poll([{"name": "lint", "status": "completed", "conclusion": "success"}])
        self.assertFalse(ok)
        self.assertIn("pending or absent", why)
        self.assertIn("CI / typecheck", why)

    def test_expected_check_green(self):
        ok, why = self.poll([{"name": "CI / typecheck", "status": "completed", "conclusion": "success"}])
        self.assertTrue(ok, why)

    def test_any_red_check_is_red(self):
        ok, _ = self.poll([{"name": "CI / typecheck", "status": "completed", "conclusion": "success"},
                           {"name": "other", "status": "completed", "conclusion": "failure"}])
        self.assertFalse(ok)


class FixerResultTests(unittest.TestCase):
    # Run 45738143849's fixer job 139639077216: the weekly limit, read back as subtype success with is_error.
    WEEKLY = ('{"type":"result","subtype":"success","is_error":true,'
              '"result":"You\'ve hit your weekly limit \u00b7 resets Dec 2, 3am (UTC)"}')

    def test_weekly_limit_is_limited_never_ok(self):
        got = ra.fixer_result("claude", self.WEEKLY, "", 1)
        self.assertEqual(got["status"], "limited")
        self.assertEqual(got["mechanical"], "false")
        self.assertIn("weekly limit", got["why"])

    def test_schema_answer_is_ok(self):
        answer = '{"subtype":"success","is_error":false,"structured_output":{"mechanical":true,"summary":"fix  it"}}'
        got = ra.fixer_result("claude", answer, "", 0)
        self.assertEqual((got["status"], got["mechanical"], got["summary"]), ("ok", "true", "fix it"))

    def test_not_mechanical_is_still_an_answer(self):
        answer = '{"subtype":"success","result":"{\\"mechanical\\": false, \\"summary\\": \\"needs design\\"}"}'
        got = ra.fixer_result("claude", answer, "", 0)
        self.assertEqual((got["status"], got["mechanical"]), ("ok", "false"))

    def test_no_answer_and_bad_login_is_limited(self):
        got = ra.fixer_result("claude", "", "Invalid API key \u00b7 Please run /login", 1)
        self.assertEqual(got["status"], "limited")

    def test_crash_without_a_known_cause_is_failed(self):
        got = ra.fixer_result("claude", "", "Segmentation fault", 139)
        self.assertEqual(got["status"], "failed")
        self.assertIn("exit 139", got["why"])

    def test_codex_last_message_and_codex_quota(self):
        self.assertEqual(ra.fixer_result("codex", '{"mechanical": true, "summary": "s"}', "", 0)["status"], "ok")
        got = ra.fixer_result("codex", "", "ERROR: You've hit your usage limit. Try again in 3 days.", 1)
        self.assertEqual(got["status"], "limited")

    def test_workflow_falls_back_and_fails_when_no_fixer_ran(self):
        text = (Path(__file__).resolve().parents[1] / ".github/workflows/red-autofix.yml").read_text()
        for needle in ("claude-oauth claude-api codex", "secrets.ANTHROPIC_API_KEY", "secrets.CODEX_AUTH_JSON",
                       "fixer-result --harness", 'echo "limited=true"', '[ "$NO_FIXER" = true ]'):
            self.assertIn(needle, text)


class CommentTests(unittest.TestCase):
    def test_only_the_bots_own_marker_comment_is_edited(self):
        # CodeRabbit 4691805886: anyone can paste the marker; only the Actions bot's comment is ours.
        forged = {"id": 1, "user": {"login": "someone"}, "body": "<!-- red-autofix:k -->\nhi"}
        quoted = {"id": 2, "user": {"login": "github-actions[bot]"}, "body": "> <!-- red-autofix:k -->"}
        mine = {"id": 3, "user": {"login": "github-actions[bot]"}, "body": "<!-- red-autofix:k -->\nred"}
        self.assertIsNone(ra.own_marker([forged, quoted], "k"))
        self.assertEqual(ra.own_marker([forged, quoted, mine], "k")["id"], 3)


if __name__ == "__main__":
    unittest.main()
