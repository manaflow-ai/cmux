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

ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
       "GIT_COMMITTER_EMAIL": "t@example.com", "GIT_CONFIG_GLOBAL": "/dev/null"}

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

    def test_verify_green_only_when_the_candidate_fixes_a_tip_red(self):
        commit(self.repo, {"pkg/a.py": "x = (\n"}, "Break a (#8)")
        report = {"lang": "python", "paths": ["pkg/a.py"], "sites": ["pkg/a.py"], "errors": []}
        commit(self.repo, {"pkg/a.py": "x = 1\n"}, "red-autofix: fix")
        ok, why = ra.verify(report, self.repo)
        self.assertTrue(ok, why)
        git(self.repo, "reset", "-q", "--hard", "HEAD~1")
        commit(self.repo, {"pkg/b.py": "y = 3\n"}, "red-autofix: no fix")
        ok, why = ra.verify(report, self.repo)
        self.assertFalse(ok)
        self.assertIn("py_compile", why)

    def test_verify_with_no_local_check_defers_to_pr_checks(self):
        ok, why = ra.verify({"lang": "swift", "paths": ["A.swift"], "sites": [], "errors": []}, self.repo)
        self.assertFalse(ok)
        self.assertIn("pull request's own checks", why)


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


class LandTests(unittest.TestCase):
    REPORT = {"repo": "o/r", "target": "feat-cmux-next"}

    def pr(self, number, sha="a" * 40, state="open", body="", merged_at=None):
        return {"number": number, "state": state, "body": body, "merged_at": merged_at, "title": "Fix the red",
                "head": {"sha": sha}}

    def run_land(self, routes, env="1"):
        api = FakeApi(routes)
        with mock.patch.dict(os.environ, {"RED_AUTOFIX": env}):
            return ra.land(self.REPORT, "fix", 1, "a" * 40, "revert/pr-9", api=api), api

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


if __name__ == "__main__":
    unittest.main()
