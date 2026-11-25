#!/usr/bin/env python3
"""The Actions artifact pruner deletes only expired-by-rule build artifacts, never a release run's."""
import datetime as dt
import re
from pathlib import Path
import sys
import unittest
from unittest import mock
import urllib.error

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import actions_artifact_prune as prune  # noqa: E402

NOW = dt.datetime(2026, 10, 11, 12, tzinfo=dt.timezone.utc)


def art(artifact_id, name, days, run=1, size=100, expired=False):
    stamp = (NOW - dt.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"id": artifact_id, "name": name, "created_at": stamp, "size_in_bytes": size,
            "expired": expired, "workflow_run": {"id": run}}


class FakeAPI:
    def __init__(self, artifacts, release_runs=()):
        self.by_name = {}
        for artifact in artifacts:
            self.by_name.setdefault(artifact["name"], []).append(artifact)
        self.release_runs = list(release_runs)
        self.deleted = []
        self.listed = []
        self.pages_read = {}
        self.remaining = None

    def artifact_pages(self, name, size=2):
        """Like the API: newest first in pages of `size`, yielded from the last page back."""
        self.listed.append(name)
        newest = sorted(self.by_name.get(name, []), key=prune.created, reverse=True)
        pages = [newest[i:i + size] for i in range(0, len(newest), size)] or [[]]
        for page in reversed(pages):
            self.pages_read[name] = self.pages_read.get(name, 0) + 1
            yield page

    def runs_since(self, workflow, since):
        return self.release_runs if workflow == "cmux-tui-release.yml" else []

    def delete(self, artifact_id):
        self.deleted.append(artifact_id)
        if self.remaining is not None:
            self.remaining -= 1


class Prune(unittest.TestCase):
    def test_dry_run_reports_and_deletes_nothing(self):
        api = FakeAPI([art(1, "npm-packages", 10), art(2, "npm-packages", 1)])
        summary = prune.prune(api, NOW, delete=False, max_deletes=10)
        self.assertEqual((summary["candidates"], summary["candidate_bytes"]), (1, 100))
        self.assertEqual(api.deleted, [])

    def test_build_artifacts_live_3_days(self):
        api = FakeAPI([
            art(1, "cmux-tui-x86_64-unknown-linux-musl", 4), art(2, "cmux-tui-x86_64-unknown-linux-musl", 2),
            art(3, "chatmux-relay-aarch64-apple-darwin", 3.5), art(4, "pypi-wheels", 2.9),
        ])
        prune.prune(api, NOW, delete=True, max_deletes=10)
        self.assertEqual(sorted(api.deleted), [1, 3])

    def test_a_release_run_keeps_its_artifacts_30_days(self):
        api = FakeAPI([art(1, "npm-packages", 20, run=77), art(2, "npm-packages", 40, run=77),
                       art(3, "npm-packages", 20, run=78)], release_runs=[77])
        summary = prune.prune(api, NOW, delete=True, max_deletes=10)
        self.assertEqual(sorted(api.deleted), [2, 3])
        self.assertEqual(summary["kept_release"], 1)

    def test_unlisted_names_and_expired_artifacts_are_never_touched(self):
        api = FakeAPI([art(1, "app-host-products-v1-abc", 50), art(2, "npm-packages", 50, expired=True)])
        prune.prune(api, NOW, delete=True, max_deletes=10)
        self.assertEqual(api.deleted, [])
        self.assertNotIn("app-host-products-v1-abc", api.listed)

    def test_the_cap_deletes_the_oldest_first_and_says_it_stopped(self):
        api = FakeAPI([art(i, "npm-packages", 4 + i) for i in range(1, 6)])
        summary = prune.prune(api, NOW, delete=True, max_deletes=2)
        self.assertEqual(api.deleted, [5, 4])
        self.assertTrue(summary["capped"])
        self.assertIn("capped", prune.render(summary, True))

    def test_reading_stops_at_the_first_page_inside_the_window(self):
        api = FakeAPI([art(i, "npm-packages", d) for i, d in enumerate((10, 9, 2, 1.5, 1, 0.5), 1)])
        summary = prune.prune(api, NOW, delete=False, max_deletes=10)
        self.assertEqual(summary["candidates"], 2)
        # Of three pages, the third (newest) is never read: the second was already all fresh.
        self.assertEqual(api.pages_read["npm-packages"], 2)

    def test_deletes_stop_when_the_hourly_api_quota_runs_low(self):
        api = FakeAPI([art(i, "npm-packages", 4 + i) for i in range(1, 6)])
        api.remaining = prune.QUOTA_FLOOR + 1
        summary = prune.prune(api, NOW, delete=True, max_deletes=10)
        self.assertEqual(api.deleted, [5, 4])
        self.assertTrue(summary["capped"])

    def test_artifacts_github_is_already_expiring_are_left_to_it(self):
        old = art(1, "npm-packages", 10)
        old["expires_at"] = (NOW - dt.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        api = FakeAPI([old, art(2, "npm-packages", 10)])
        prune.prune(api, NOW, delete=True, max_deletes=10)
        self.assertEqual(api.deleted, [2])

    def test_a_secondary_rate_limit_stops_the_run_cleanly(self):
        api = FakeAPI([art(i, "npm-packages", 4 + i) for i in range(1, 4)])
        real_delete = api.delete

        def delete(artifact_id):
            if api.deleted:
                raise prune.SlowDown("DELETE: HTTP 403")
            real_delete(artifact_id)

        api.delete = delete
        summary = prune.prune(api, NOW, delete=True, max_deletes=10)
        self.assertEqual(api.deleted, [3])
        self.assertTrue(summary["capped"])

    def test_an_already_deleted_artifact_counts_as_done_but_a_missing_release_workflow_stops(self):
        github = prune.GitHub("o/r", "t")
        gone = urllib.error.HTTPError("u", 404, "Not Found", {}, None)
        with mock.patch.object(github, "request", side_effect=gone), mock.patch.object(prune.time, "sleep"):
            github.delete(1)
            self.assertEqual(github.runs_since("relay-publish-npm.yml", NOW), [])
            with self.assertRaises(urllib.error.HTTPError):
                github.runs_since("cmux-tui-release.yml", NOW)

    def test_a_failed_release_lookup_stops_before_any_delete(self):
        api = FakeAPI([art(1, "npm-packages", 10)])
        api.runs_since = lambda workflow, since: (_ for _ in ()).throw(RuntimeError("API down"))
        with self.assertRaises(RuntimeError):
            prune.prune(api, NOW, delete=True, max_deletes=10)
        self.assertEqual(api.deleted, [])

    def test_the_rules_cover_every_build_package_upload(self):
        names = prune.rules()
        self.assertEqual(len([n for n in names if n.startswith("cmux-tui-")]), 5)
        self.assertEqual(len([n for n in names if n.startswith("gallery-stage-")]), 0)
        workflow = (ROOT / ".github/workflows/cmux-tui-build-package.yml")
        if workflow.exists():
            text = workflow.read_text()
            for family in ("cmux-relay-", "chatmux-relay-", "cmux-agent-screen-detection-", "npm-packages", "pypi-wheels"):
                self.assertIn(family, text)


class RunAPI:
    def __init__(self, artifacts):
        self.artifacts = artifacts
        self.deleted = []
        self.remaining = None

    def run_artifacts(self, run_id):
        return [a for a in self.artifacts if a["workflow_run"]["id"] == run_id]

    def delete(self, artifact_id):
        self.deleted.append(artifact_id)


class DropRun(unittest.TestCase):
    def test_a_finished_run_drops_only_its_large_build_outputs_largest_first(self):
        api = RunAPI([
            art(1, "cmux-tui-aarch64-apple-darwin", 0, run=9, size=112),
            art(2, "machine-channel-cmux-tui-x86_64-unknown-linux-musl", 0, run=9, size=236),
            art(3, "cmux-tui-dsyms-aarch64-apple-darwin", 0, run=9, size=290),
            art(4, "cmux-relay-aarch64-apple-darwin", 0, run=9, size=1),
            art(5, "cmux-tui-tree-feat-builder-abc", 0, run=9, size=1),
            art(6, "cmux-tui-tree-deferred-abc", 0, run=9, size=1),
            art(7, "cmux-next-tree-notify-pending", 0, run=9, size=1),
            art(8, "cmux-tui-aarch64-apple-darwin", 0, run=10, size=112),
        ])
        summary = prune.drop_run(api, 9, delete=True)
        self.assertEqual(api.deleted, [3, 2, 1])
        self.assertEqual(summary["deleted_bytes"], 638)

    def test_without_delete_it_only_reports(self):
        api = RunAPI([art(1, "cmux-tui-x86_64-unknown-linux-musl", 0, run=9, size=193)])
        summary = prune.drop_run(api, 9, delete=False)
        self.assertEqual((api.deleted, summary["candidate_bytes"]), ([], 193))

    def test_a_rate_limit_stops_the_drop_and_leaves_the_rest_to_retention(self):
        api = RunAPI([art(i, n, 0, run=9, size=s) for i, (n, s) in enumerate(
            (("cmux-tui-aarch64-apple-darwin", 3), ("cmux-tui-aarch64-unknown-linux-musl", 2)), 1)])
        api.delete = mock.Mock(side_effect=prune.SlowDown("HTTP 429"))
        summary = prune.drop_run(api, 9, delete=True)
        self.assertTrue(summary["capped"])
        self.assertEqual(summary["deleted"], 0)

    def test_the_dropped_names_are_what_the_build_package_uploads(self):
        text = (ROOT / ".github/workflows/cmux-tui-build-package.yml").read_text()
        for name in ("}}cmux-tui-dsyms-${{ matrix.target }}", "}}cmux-tui-${{ matrix.target }}",
                     "name: cmux-tui-x86_64-pc-windows-gnu", "name: cmux-tui-acpmux-x86_64-pc-windows-gnu"):
            self.assertIn(name, text)
        profiles = yaml.safe_load((ROOT / "scripts/cmux-next/cmux-tui-build-profiles.json").read_text())
        prefix = profiles["machine_channel"]["artifact_prefix"]
        self.assertTrue({f"{prefix}cmux-tui-{t}" for t in ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")}
                        <= prune.run_drop_names())


ARTIFACTS = ROOT / ".github/workflows/cmux-tui-artifacts.yml"


def artifacts_jobs():
    return yaml.safe_load(ARTIFACTS.read_text())["jobs"]


def reads_dropped_artifacts(job: dict) -> bool:
    """A job that downloads a dropped name: by pattern, by name or with gh run download."""
    names = prune.run_drop_names()
    for step in job.get("steps", []):
        uses, args, run = str(step.get("uses", "")), step.get("with") or {}, str(step.get("run", ""))
        if "download-artifact" in uses:
            pattern = str(args.get("pattern") or args.get("name") or "*")
            regex = "^" + re.escape(pattern).replace(r"\*", ".*") + "$"
            if any(re.match(regex, name) for name in names):
                return True
        if "gh run download" in run or "/artifacts" in run:
            return True
    return False


class DropJob(unittest.TestCase):
    def test_the_drop_waits_for_every_job_and_runs_only_after_a_clean_run(self):
        jobs = artifacts_jobs()
        drop = jobs["drop-build-artifacts"]
        self.assertEqual(set(drop["needs"]), set(jobs) - {"drop-build-artifacts"})
        # Every reader of a dropped name is among them: a reader added later is covered by the rule above.
        readers = {name for name, job in jobs.items() if reads_dropped_artifacts(job)}
        self.assertTrue({"publish", "publish-tree", "sentry-dsyms",
                         "point-machine-channel", "darwin-fallback-plan"} <= readers, readers)
        self.assertTrue(readers <= set(drop["needs"]))
        condition = drop["if"]
        # notify-unpublished-tree hands the key on and must stay the run's last job (cx-urd.26).
        for clause in ("always()", "!contains(needs.*.result, 'failure')", "!contains(needs.*.result, 'cancelled')",
                       "needs.notify-unpublished-tree.result == 'skipped'"):
            self.assertIn(clause, condition)
        self.assertTrue(drop.get("continue-on-error"))

    def test_the_drop_spends_the_cmux_bot_token_never_the_workflow_token(self):
        drop = artifacts_jobs()["drop-build-artifacts"]
        text = yaml.safe_dump(drop)
        self.assertNotIn("github.token", text)
        self.assertNotIn("secrets.GITHUB_TOKEN", text)
        self.assertNotIn("actions", drop["permissions"])
        step = next(s for s in drop["steps"] if "actions_artifact_prune.py" in str(s.get("run", "")))
        self.assertIn("--run-id", step["run"])
        self.assertIn("--delete", step["run"])
        self.assertEqual(step["env"]["GITHUB_TOKEN"], "${{ steps.cmux-bot-token.outputs.token }}")

    def test_only_the_machine_channel_point_reads_a_machine_channel_artifact(self):
        # MACHINE_CHANNEL_THIN: cmux-machine-channel.yml's build uploads machine-channel-* (about 230 MB a
        # target) for its point alone; no shipped download in cmux-tui-artifacts.yml reads them.
        def readers(jobs):
            return [name for name, job in jobs.items() if any("machine-channel-cmux-tui" in str((s.get("with") or {}).get("pattern", ""))
                    + str((s.get("with") or {}).get("name", "")) for s in job.get("steps", []))]
        self.assertEqual(readers(artifacts_jobs()), [])
        channel = yaml.safe_load((ROOT / ".github/workflows/cmux-machine-channel.yml").read_text())["jobs"]
        self.assertEqual(readers(channel), ["point"])
        self.assertEqual(channel["build"]["uses"], "./.github/workflows/cmux-tui-build-package.yml")


class Workflow(unittest.TestCase):
    def test_only_main_prunes_and_only_on_an_explicit_opt_in(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/actions-artifact-prune.yml").read_text())
        triggers = workflow.get("on", workflow.get(True))
        self.assertEqual(set(triggers), {"schedule", "workflow_dispatch"})
        self.assertEqual(workflow["permissions"], {})
        job = workflow["jobs"]["prune"]
        self.assertIn("github.ref == 'refs/heads/main'", job["if"])
        self.assertEqual(job["permissions"], {"contents": "read", "actions": "write"})
        run = next(step for step in job["steps"] if "actions_artifact_prune.py" in str(step.get("run", "")))
        self.assertIn("--delete", run["run"])
        condition = run["env"]["PRUNE_DELETE"]
        self.assertIn("vars.ACTIONS_ARTIFACT_PRUNE_DELETE == '1'", condition)
        # A dispatch decides by its input alone: delete=false is a dry run even when the variable is on.
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.delete", condition)
        self.assertIn("github.event_name == 'schedule' && vars.ACTIONS_ARTIFACT_PRUNE_DELETE == '1'", condition)
        self.assertIn("inputs.delete", condition)


if __name__ == "__main__":
    unittest.main()
