#!/usr/bin/env python3
"""The carrier relay deploy plan (scripts/ci/relay_deploy_plan.py) on a throwaway git history.

Review of #38564 found two holes in the first version of the plan: with no serving commit to compare,
it fell back to the push's previous commit and skipped the migration approval, even when a failed
earlier push had left an unshipped migration behind; and a re-run of an older push after a newer
deploy passed and shipped the older source to production. These cases pin the fixes:
(a) an unknown serving commit requires approval, (b) an older source is refused in plan and guard,
(c) the rollback dispatch may still go back.

A second review found two more: a deploy job re-run whose /version fetch failed admitted any source
(an unknown served commit skipped the ancestry check), and a rollback to a commit whose relay predates
GET /version deployed, failed its /version check and restored the version being left. The guard now
refuses an unknown served commit unless the run passed the relay-migrations approval, and plan refuses
such a commit rollback, pointing at the version-id rollback.
"""

from __future__ import annotations

import contextlib
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import relay_deploy_plan  # noqa: E402

WRANGLER = "cmux-tui/relays/cloudflare-do/wrangler.toml"
V1 = '[[migrations]]\ntag = "v1"\nnew_sqlite_classes = ["RelaySlot"]\n'
V2 = V1 + '\n[[migrations]]\ntag = "v2"\ndeleted_classes = ["RelaySlot"]\n'
FEAT = "refs/heads/feat-cmux-next"


class RelayDeployPlanTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        self.git("init", "-q")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.pre_endpoint = self.commit(V1, "src v0", version_route=False)
        self.v1 = self.commit(V1, "src v1")
        self.v2 = self.commit(V1, "src v2")
        self.migrated = self.commit(V2, "src v2")  # adds a destructive migration
        self.tip = self.commit(V2, "src v3")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", self.repo, *args], check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, wrangler: str, source: str, version_route: bool = True) -> str:
        path = Path(self.repo, WRANGLER)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(wrangler)
        Path(path.parent, "src").mkdir(exist_ok=True)
        route = '    if path == "/version" {\n' if version_route else ""
        Path(path.parent, "src", "routing.rs").write_text(f"// {source}\n{route}")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", source)
        return self.git("rev-parse", "HEAD")

    def plan(self, *extra: str, tip: str | None = None, served: tuple[str, str] = ("", "")) -> tuple[int, dict[str, str], str]:
        argv = ["plan", "--repo", self.repo, "--tip", tip or self.tip, "--ref", FEAT,
                "--served-staging", served[0], "--served-production", served[1], *extra]
        if "--event" not in extra:
            argv += ["--event", "push"]
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = relay_deploy_plan.main(argv)
        lines = [line.split("=", 1) for line in stdout.getvalue().splitlines() if "=" in line and not line.startswith("::")]
        return code, dict(lines), stdout.getvalue() + stderr.getvalue()

    # (a) unknown serving revision -> approval required
    def test_unknown_serving_commit_requires_migration_approval(self) -> None:
        for served in (("", ""), ("f" * 40, "f" * 40)):  # no /version, or a commit this checkout lacks
            code, out, _ = self.plan(served=served)
            self.assertEqual(code, 0)
            self.assertEqual(out["mode"], "deploy")
            self.assertEqual(out["migrations_changed"], "true", served)

    def test_unshipped_migration_behind_a_failed_push_requires_approval(self) -> None:
        # Production still serves v2; the push of `migrated` failed; the tip's own diff adds no migration.
        code, out, _ = self.plan(served=(self.v2, self.v2))
        self.assertEqual(code, 0)
        self.assertEqual(out["migrations_changed"], "true")

    def test_same_migrations_need_no_approval(self) -> None:
        code, out, _ = self.plan(served=(self.migrated, self.migrated))
        self.assertEqual((code, out["migrations_changed"], out["production"]), (0, "false", "true"))

    # (b) older source -> refused
    def test_rerun_of_an_older_push_is_refused(self) -> None:
        code, _, text = self.plan(tip=self.v2, served=(self.tip, self.tip))
        self.assertEqual(code, 1)
        self.assertIn("does not descend", text)

    def test_guard_refuses_an_older_source_and_admits_a_newer_one(self) -> None:
        base = ["guard", "--repo", self.repo, "--worker", "cmux-remote-relay-production", "--mode", "deploy"]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(relay_deploy_plan.main([*base, "--source", self.v1, "--served", self.tip]), 1)
            self.assertEqual(relay_deploy_plan.main([*base, "--source", self.tip, "--served", self.v1]), 0)
            self.assertEqual(relay_deploy_plan.main([*base, "--source", self.tip, "--served", self.tip]), 0)

    def guard(self, served: str, *extra: str) -> int:
        with contextlib.redirect_stdout(io.StringIO()):
            return relay_deploy_plan.main(["guard", "--repo", self.repo, "--worker", "cmux-remote-relay-production",
                                           "--mode", "deploy", "--source", self.v1, "--served", served, *extra])

    def test_guard_refuses_an_unknown_served_commit_without_approval(self) -> None:
        # A re-run of an old deploy job whose /version fetch failed: refused, as with the newer commit itself.
        self.assertEqual(self.guard(self.tip), 1)
        self.assertEqual(self.guard(""), 1)
        self.assertEqual(self.guard("f" * 40), 1)

    def test_guard_admits_an_unknown_served_commit_with_the_bootstrap_approval(self) -> None:
        self.assertEqual(self.guard("", "--bootstrap-approved"), 0)
        # The approval never admits an older source over a known newer one.
        self.assertEqual(self.guard(self.tip, "--bootstrap-approved"), 1)

    # (c) rollback dispatch -> allowed
    def test_rollback_dispatch_may_go_back(self) -> None:
        code, out, _ = self.plan("--event", "workflow_dispatch", "--action", "rollback", "--rollback-to", self.v1,
                                 served=(self.tip, self.tip))
        self.assertEqual(code, 0)
        self.assertEqual((out["mode"], out["sha"], out["journeys"]), ("sha", self.v1, "false"))
        self.assertEqual(out["migrations_changed"], "true")  # v1 lacks the v2 migration production serves
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(relay_deploy_plan.main(["guard", "--repo", self.repo, "--worker", "w", "--mode", "sha",
                                                     "--source", self.v1, "--served", self.tip]), 0)

    def test_rollback_to_a_relay_without_version_is_refused(self) -> None:
        code, _, text = self.plan("--event", "workflow_dispatch", "--action", "rollback",
                                  "--rollback-to", self.pre_endpoint, served=(self.tip, self.tip))
        self.assertEqual(code, 1)
        self.assertIn("predates GET /version", text)
        self.assertIn("rollback_to=<version id>", text)

    def test_version_rollback_names_one_worker(self) -> None:
        version = "0123abcd-0000-4000-8000-0123456789ab"
        code, out, _ = self.plan("--event", "workflow_dispatch", "--action", "rollback", "--rollback-to", version,
                                 "--target", "production")
        self.assertEqual((code, out["mode"], out["staging"], out["production"]), (0, "version", "false", "true"))
        code, _, _ = self.plan("--event", "workflow_dispatch", "--action", "rollback", "--rollback-to", version)
        self.assertEqual(code, 1)

    def test_push_with_the_same_relay_source_deploys_nothing(self) -> None:
        code, out, _ = self.plan(tip=self.tip, served=(self.tip, self.tip))
        self.assertEqual((code, out["mode"], out["staging"], out["production"]), (0, "skip", "false", "false"))


if __name__ == "__main__":
    unittest.main()
