#!/usr/bin/env python3
"""scripts/ci/publish-nightly-next-r2.py: the cmux NEXT feed's R2 critical path.

The enclosure rewrite touches only the names asked for (or, with --if-public, only
what the public base serves at the enclosure's length), and the feed write is a
compare-and-swap that never moves the feed to an older build.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

import yaml
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "publish-nightly-next-r2.py"
spec = importlib.util.spec_from_file_location("publish_nightly_next_r2", SCRIPT)
r2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r2)

GH = r2.GITHUB_PREFIX
BASE = "https://files-next.cmux.com/nightly-next/next"
ENV = {
    "NIGHTLY_NEXT_FEED_BASE": BASE,
    "NIGHTLY_NEXT_R2_BUCKET": "cmux-nightly-next",
    "NIGHTLY_NEXT_R2_PREFIX": "nightly-next/next/",
    "R2_ENDPOINT": "https://account.r2.cloudflarestorage.com",
}


def feed(*items: tuple, channel: dict | None = None, source: dict | None = None) -> str:
    channel = channel or {}
    source = source or {}
    body = "".join(
        f'<item><sparkle:version>{build}</sparkle:version>'
        + (f"<sparkle:channel>{channel[build]}</sparkle:channel>" if build in channel else "")
        + (f"<cmux:sourceCommit>{source[build]}</cmux:sourceCommit>" if build in source else "")
        + f'<enclosure url="{url}" length="{length}" sparkle:edSignature="sig"/></item>' for build, url, length in items)
    namespace = ' xmlns:cmux="https://cmux.com/xml-namespaces/cmux"' if source else ""
    return ('<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"'
            f'{namespace}>'
            f"<channel>{body}</channel></rss>")


class RewriteTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        patcher = mock.patch.dict(os.environ, ENV)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, text: str) -> Path:
        path = Path(self.dir.name) / "appcast-arm64.xml"
        path.write_text(text, encoding="utf-8")
        return path

    def test_only_the_named_dmg_moves_to_r2(self) -> None:
        new, old = "cmux-nightly-next-macos-arm64-200.dmg", "cmux-nightly-next-macos-arm64-100.dmg"
        path = self.write(feed((200, GH + new, 5), (100, GH + old, 4)))
        self.assertEqual(r2.rewrite(path, {new}, False), 0)
        text = path.read_text()
        self.assertIn(f'url="{BASE}/{new}"', text)
        self.assertIn(f'url="{GH}{old}"', text)
        self.assertIn('sparkle:edSignature="sig"', text)

    def test_a_missing_name_fails(self) -> None:
        path = self.write(feed((100, GH + "cmux-nightly-next-macos-arm64-100.dmg", 4)))
        self.assertEqual(r2.rewrite(path, {"cmux-nightly-next-macos-arm64-200.dmg"}, False), 1)

    def test_if_public_moves_only_what_r2_serves_at_its_length(self) -> None:
        served = {f"{BASE}/cmux-nightly-next-macos-arm64-200.dmg": 5,
                  f"{BASE}/cmux-nightly-next-macos-arm64-200-100.delta": 999}
        path = self.write(feed((200, GH + "cmux-nightly-next-macos-arm64-200.dmg", 5),
                               (150, GH + "cmux-nightly-next-macos-arm64-200-100.delta", 3),
                               (100, GH + "cmux-nightly-next-macos-arm64-100.dmg", 4)))
        with mock.patch.object(r2, "public_length", side_effect=lambda url, attempts=5: served.get(url)):
            self.assertEqual(r2.rewrite(path, set(), True), 0)
        text = path.read_text()
        self.assertIn(f'url="{BASE}/cmux-nightly-next-macos-arm64-200.dmg"', text)
        # Wrong length on R2, or not on R2: the release URL stays.
        self.assertIn(f'url="{GH}cmux-nightly-next-macos-arm64-200-100.delta"', text)
        self.assertIn(f'url="{GH}cmux-nightly-next-macos-arm64-100.dmg"', text)

    def test_other_downloads_are_never_rewritten(self) -> None:
        other = "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos-arm64-1.dmg"
        path = self.write(feed((1, other, 1)))
        self.assertEqual(r2.rewrite(path, set(), True), 0)
        self.assertIn(other, path.read_text())


class FeedWriteCase(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        patcher = mock.patch.dict(os.environ, ENV)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.path = Path(self.dir.name) / "appcast-arm64.xml"
        self.path.write_text(feed((200, f"{BASE}/cmux-nightly-next-macos-arm64-200.dmg", 5)), encoding="utf-8")
        self.output = Path(self.dir.name) / "out"
        compiled = mock.patch.object(r2, "compiled_artifact_source", return_value=None)
        compiled.start()
        self.addCleanup(compiled.stop)
        self.calls: list[list[str]] = []
        for name in ("guard_key",):
            p = mock.patch.object(r2, name, lambda key: None)
            p.start()
            self.addCleanup(p.stop)

    def run_with(self, lives: list[bytes | None], codes: list[int], same_build: bool = False,
                 source_sha: str | None = None) -> int:
        lives_iter, codes_iter = iter(lives), iter(codes)

        def fake_run(args, *rest, **kwargs):
            self.calls.append(args)
            return subprocess.CompletedProcess(args, next(codes_iter))

        with mock.patch.object(r2, "read_live", lambda key: next(lives_iter)), \
                mock.patch.object(r2.subprocess, "run", fake_run):
            return r2.write_feed(self.path, str(self.output), same_build, source_sha=source_sha)


class WriteFeedTests(FeedWriteCase):
    def test_a_newer_live_feed_is_left_alone(self) -> None:
        live = feed((300, "x", 1)).encode()
        self.assertEqual(self.run_with([live], []), 0)
        self.assertEqual(self.calls, [])
        self.assertIn("feed_written=false", self.output.read_text())

    def test_the_same_build_is_not_rewritten_by_the_first_publication(self) -> None:
        live = feed((200, "x", 1)).encode()
        self.assertEqual(self.run_with([live], []), 0)
        self.assertEqual(self.calls, [])

    def test_an_older_live_feed_is_replaced_only_while_it_has_the_bytes_read(self) -> None:
        live = feed((100, "x", 1)).encode()
        self.assertEqual(self.run_with([live], [0]), 0)
        args = self.calls[0]
        self.assertIn("--replace-sha256", args)
        self.assertEqual(args[args.index("--replace-sha256") + 1], hashlib.sha256(live).hexdigest())
        self.assertEqual(args[args.index("--key") + 1], "nightly-next/next/appcast-arm64.xml")
        self.assertIn("feed_written=true", self.output.read_text())

    def test_a_lost_race_reads_again_and_yields_to_a_newer_build(self) -> None:
        older, newer = feed((100, "x", 1)).encode(), feed((300, "x", 1)).encode()
        self.assertEqual(self.run_with([older, newer], [r2.CONFLICT]), 0)
        self.assertEqual(len(self.calls), 1)
        self.assertIn("feed_written=false", self.output.read_text())

    def test_no_live_feed_is_written_once(self) -> None:
        self.assertEqual(self.run_with([None], [0]), 0)
        self.assertIn("--write-once", self.calls[0])

    def test_an_upload_failure_fails(self) -> None:
        self.assertEqual(self.run_with([feed((100, "x", 1)).encode()], [1]), 1)

    def test_an_older_source_cannot_win_with_a_larger_run_build(self) -> None:
        source_a, source_b = "a" * 40, "b" * 40
        self.path.write_text(feed((300, "x", 1), source={300: source_a}), encoding="utf-8")
        live = feed((200, "x", 1), source={200: source_b}).encode()
        with mock.patch.object(r2, "source_order", return_value=False):
            self.assertEqual(self.run_with([live], [], source_sha=source_a), 0)
        self.assertEqual(self.calls, [])
        self.assertIn("feed_written=false", self.output.read_text())
        self.assertIn("publication_refused=true", self.output.read_text())
        # A successful no-op must not authorize the GitHub release, notes or tag.
        env = {**os.environ, "TAG_MOVE_OUTCOME": "success", "CHANNEL_RELEASE_TAG": "nightly-next",
               "NEXT_FEED_CURRENT": "false", "GITHUB_OUTPUT": str(self.output)}
        subprocess.run(["bash", str(ROOT / "scripts/ci/nightly-steps/publish-tag-outcome.sh")],
                       env=env, check=True, capture_output=True, text=True)
        self.assertIn("tag_status=unpublished", self.output.read_text())
        self.assertNotIn("tag_status=updated", self.output.read_text())

    def test_rerun_reuses_an_already_accepted_build_and_source_for_metadata_repair(self) -> None:
        source = "a" * 40
        live = feed((200, "accepted-download", 1), source={200: source}).encode()
        self.assertEqual(self.run_with([live], [], source_sha=source), 0)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.path.read_bytes(), live)
        self.assertIn("feed_written=false", self.output.read_text())
        self.assertIn("feed_current=true", self.output.read_text())
        self.assertNotIn("publication_refused=true", self.output.read_text())
        env = {**os.environ, "TAG_MOVE_OUTCOME": "success", "CHANNEL_RELEASE_TAG": "nightly-next",
               "NEXT_FEED_CURRENT": "true", "GITHUB_OUTPUT": str(self.output), "HEAD_SHA": source,
               "CHANNEL_FEED_BASE": BASE, "GITHUB_STEP_SUMMARY": str(Path(self.dir.name) / "summary")}
        subprocess.run(["bash", str(ROOT / "scripts/ci/nightly-steps/publish-tag-outcome.sh")],
                       env=env, check=True, capture_output=True, text=True)
        self.assertIn("tag_status=updated", self.output.read_text())

    def test_failed_handoff_retry_reaches_checked_live_bytes_then_recreates_handoff(self) -> None:
        from test_nightly_next_recovery import run_recheck

        source = "a" * 40
        # Attempt one commits CAS, then the artifact service fails. Nothing
        # reached the GitHub release job; attempt two must recreate its input.
        self.assertEqual(self.run_with([None], [0], source_sha=source), 0)
        accepted = self.path.read_bytes()
        self.calls.clear()
        self.output.write_text("")
        recheck = run_recheck(200, (200,), source="own", attempt=2)
        self.assertEqual(recheck.returncode, 0, recheck.stderr)

        job = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]["publish-nightly"]
        values = {"needs.decide.outputs.should_publish": "true", "needs.decide.outputs.track": "nightly-next",
                  "steps.recheck.outputs.already_published": recheck.output.get("already_published", ""),
                  "steps.gate.outputs.refused": ""}

        def runs(name):
            condition = next(s for s in job["steps"] if s.get("name") == name)["if"]
            for key, value in values.items():
                condition = condition.replace(key, repr(value))
            return eval(condition.replace("&&", "and"), {"__builtins__": {}}, {})

        self.assertTrue(runs("Final publication gate"))
        self.assertTrue(runs("Upload nightly-next appcasts to R2"))
        # The accepted-build branch reads live bytes, without another PUT.
        self.assertEqual(self.run_with([accepted], [], source_sha=source), 0)
        values["steps.upload_next_appcasts.outputs.feed_current"] = "true"
        self.assertIn("feed_current=true", self.output.read_text())
        self.assertEqual(self.calls, [])
        self.assertTrue(runs("Hand the published feed to the GitHub release job"))
        self.assertTrue(runs("Upload the published feed for the GitHub release job"))
        work = Path(self.dir.name)
        (work / "nightly-out").mkdir()
        (work / "nightly-out" / self.path.name).write_bytes(self.path.read_bytes())
        env = {**os.environ, "NIGHTLY_FEEDS": self.path.name, "RUNNER_TEMP": str(work)}
        subprocess.run(["bash", str(ROOT / "scripts/ci/nightly-steps/publish-next-hand-feed.sh")],
                       cwd=work, env=env, check=True, capture_output=True, text=True)
        self.assertEqual((work / "next-github" / self.path.name).read_bytes(), accepted)

    def test_handoff_retry_rechecks_source_and_a_race_after_the_early_check(self) -> None:
        from test_nightly_next_recovery import run_recheck

        recheck = run_recheck(200, (200,), source="own", attempt=2)
        self.assertEqual(recheck.returncode, 0, recheck.stderr)
        self.assertNotEqual(recheck.output.get("already_published"), "true")
        for build in (200, 300):
            with self.subTest(live_build=build):
                self.output.write_text("")
                live = feed((build, "newer-source-download", 1), source={build: "b" * 40}).encode()
                self.assertEqual(self.run_with([live], [], source_sha="a" * 40), 0)
                self.assertEqual(self.calls, [])
                self.assertIn("publication_refused=true", self.output.read_text())
                self.assertNotIn("feed_current=true", self.output.read_text())

    def test_the_same_build_number_with_a_different_source_is_refused(self) -> None:
        live = feed((200, "x", 1), source={200: "b" * 40}).encode()
        self.assertEqual(self.run_with([live], [], source_sha="a" * 40), 0)
        self.assertEqual(self.calls, [])
        self.assertIn("publication_refused=true", self.output.read_text())
        self.assertNotIn("feed_current=true", self.output.read_text())

    def test_markerless_live_feed_uses_the_exact_verified_notes_build(self) -> None:
        source_a, source_b = "a" * 40, "b" * 40
        self.path.write_text(feed((300, "x", 1)), encoding="utf-8")
        live = feed((200, "x", 1)).encode()
        with mock.patch.object(r2, "signed_notes_source", return_value=source_b), \
                mock.patch.object(r2, "source_order", return_value=False):
            self.assertEqual(self.run_with([live], [], source_sha=source_a), 0)
        self.assertEqual(self.calls, [])
        self.assertIn("feed_written=false", self.output.read_text())

    def test_markerless_recovered_feed_can_migrate_from_its_exact_compile_receipt(self) -> None:
        live_source, candidate = "a" * 40, "b" * 40
        with mock.patch.object(r2, "signed_notes_source", return_value=None), \
                mock.patch.object(r2, "compiled_artifact_source", return_value=live_source) as compiled, \
                mock.patch.object(r2, "source_order", return_value=True) as order:
            self.assertEqual(self.run_with([feed((100, "x", 1)).encode()], [0], source_sha=candidate), 0)
        compiled.assert_called_once_with(100)
        order.assert_called_once_with(live_source, candidate)
        self.assertIn("feed_written=true", self.output.read_text())

    def test_markerless_live_feed_without_verified_notes_refuses_upload(self) -> None:
        with mock.patch.object(r2, "signed_notes_source", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "no verified signed notes head"):
                self.run_with([feed((100, "x", 1)).encode()], [], source_sha="a" * 40)
        self.assertEqual(self.calls, [])

    def test_cas_retry_rechecks_source_even_when_racing_build_number_is_lower(self) -> None:
        old, new, candidate = "a" * 40, "b" * 40, "c" * 40
        first = feed((100, "x", 1), source={100: old}).encode()
        second = feed((180, "x", 1), source={180: new}).encode()
        with mock.patch.object(r2, "source_order", side_effect=[True, False]) as order:
            self.assertEqual(self.run_with([first, second], [r2.CONFLICT], source_sha=candidate), 0)
        self.assertEqual(order.call_args_list, [mock.call(old, candidate), mock.call(new, candidate)])
        self.assertEqual(len(self.calls), 1)

    def test_source_is_written_into_first_publication(self) -> None:
        source = "a" * 40
        self.assertEqual(self.run_with([None], [0], source_sha=source), 0)
        self.assertEqual(r2.item_source(self.path.read_bytes(), 200), source)

    def test_source_marker_survives_the_real_dev_ring_item_merger(self) -> None:
        spec = importlib.util.spec_from_file_location("ring", ROOT / "scripts/ci/nightly_next_ring.py")
        ring = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ring)
        source = "a" * 40
        marked = r2.add_source(feed((200, BASE + "/cmux-nightly-next-macos-arm64-200.dmg", 1)).encode(), source).decode()
        fresh = feed((300, BASE + "/cmux-nightly-next-macos-arm64-300.dmg", 1))
        merged, _ = ring.legacy(fresh, marked, "on", lambda build: "pass" if build == "200" else "pending")
        ET.fromstring(merged)  # copied items must carry their own prefix binding
        self.assertEqual(r2.item_source(merged.encode(), 200), source)
        self.path.write_text(merged)
        guard_spec = importlib.util.spec_from_file_location("guard", ROOT / "scripts/ci/nightly-next-guard.py")
        guard = importlib.util.module_from_spec(guard_spec)
        guard_spec.loader.exec_module(guard)
        guard.check_appcast(self.path)

    def test_the_delta_revision_needs_the_live_feed_on_this_build(self) -> None:
        self.assertEqual(self.run_with([feed((300, "x", 1)).encode()], [], same_build=True), 0)
        self.assertEqual(self.run_with([feed((100, "x", 1)).encode()], [], same_build=True), 0)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.run_with([feed((200, "x", 1)).encode()], [0], same_build=True), 0)
        self.assertIn("--replace-sha256", self.calls[0])

    def test_same_build_delta_preserves_live_source_metadata_on_each_cas_read(self) -> None:
        first, second = "a" * 40, "b" * 40
        lives = [feed((200, "x", 1), source={200: source}).encode() for source in (first, second)]
        self.assertEqual(self.run_with(lives, [r2.CONFLICT, 0], same_build=True), 0)
        self.assertEqual(r2.item_source(self.path.read_bytes(), 200), second)
        parsed = ET.fromstring(self.path.read_bytes())
        self.assertEqual(parsed.find(".//{https://cmux.com/xml-namespaces/cmux}sourceCommit").text, second)

    def test_root_bound_delta_and_old_feed_markers_survive_item_merges(self) -> None:
        source = "a" * 40
        url = BASE + "/cmux-nightly-next-macos-arm64-200.dmg"
        root_bound = feed((200, url, 1), source={200: source})
        self.path.write_text(root_bound)
        self.assertEqual(self.run_with([root_bound.encode()], [0], same_build=True), 0)
        spec = importlib.util.spec_from_file_location("ring", ROOT / "scripts/ci/nightly_next_ring.py")
        ring = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ring)
        fresh = feed((300, BASE + "/cmux-nightly-next-macos-arm64-300.dmg", 1))
        for current in (root_bound, self.path.read_text()):
            merged, _ = ring.legacy(fresh, current, "on", lambda build: "pass" if build == "200" else "pending")
            ET.fromstring(merged)
            self.assertEqual(r2.item_source(merged.encode(), 200), source)


class CompiledSourceMigrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = "a" * 40
        self.control = "b" * 40  # workflow head differs from the compiled source
        self.run = {"id": 123, "run_attempt": 1, "repository": {"id": 9, "full_name": "manaflow-ai/cmux"},
                    "head_repository": {"full_name": "manaflow-ai/cmux"}, "head_sha": self.control,
                    "head_branch": "nightly-next", "path": ".github/workflows/nightly.yml", "event": "push"}
        self.jobs = {"total_count": 1, "jobs": [{"name": "build-nightly-app", "run_attempt": 1,
                     "conclusion": "success", "started_at": "2026-10-31T00:01:00Z", "completed_at": "2026-10-31T00:03:00Z"}]}
        self.artifacts = {"total_count": 1, "artifacts": [{"id": 20, "name": "nightly-next-dsyms-" + self.source,
                          "expired": False, "digest": "sha256:" + "c" * 64, "created_at": "2026-10-31T00:02:00Z",
                          "workflow_run": {"id": 123, "head_sha": self.control, "head_branch": "nightly-next",
                                           "repository_id": 9, "head_repository_id": 9}}]}

    def read(self, run=None, jobs=None, artifacts=None):
        with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "NIGHTLY_NEXT_PROVENANCE_TOKEN": "test"}), \
                mock.patch.object(r2, "provenance_json", side_effect=[run or self.run, jobs or self.jobs,
                                                                     artifacts or self.artifacts]) as read:
            source = r2.compiled_artifact_source(12301)
        self.assertEqual([call.args[0] for call in read.call_args_list], [
            "repos/manaflow-ai/cmux/actions/runs/123/attempts/1",
            "repos/manaflow-ai/cmux/actions/runs/123/attempts/1/jobs?per_page=100",
            "repos/manaflow-ai/cmux/actions/runs/123/artifacts?per_page=100"])
        return source

    def test_recovered_build_uses_original_producer_receipt_not_workflow_head(self) -> None:
        # A later signing/publication attempt retains the compiler's original
        # daemon_build output, rather than renumbering it to the current run.
        with mock.patch.dict(os.environ, {"GITHUB_RUN_ID": "999", "GITHUB_RUN_ATTEMPT": "3"}):
            self.assertEqual(self.read(), self.source)
        self.run["event"] = "workflow_dispatch"
        self.assertEqual(self.read(), self.source)

    def test_wrong_run_workflow_branch_or_repository_is_refused(self) -> None:
        for key, value in (("id", 124), ("run_attempt", 2), ("path", "other.yml"), ("head_branch", "feature"),
                           ("event", "pull_request"), ("repository", {"id": 10, "full_name": "fork/cmux"}),
                           ("head_repository", {"full_name": "fork/cmux"})):
            with self.subTest(key=key):
                with self.assertRaises(RuntimeError):
                    self.read(run={**self.run, key: value})

    def test_missing_failed_or_wrong_attempt_producer_is_refused(self) -> None:
        for jobs in ([], [{**self.jobs["jobs"][0], "conclusion": "failure"}],
                     [{**self.jobs["jobs"][0], "run_attempt": 2}]):
            with self.subTest(jobs=jobs):
                with self.assertRaises(RuntimeError):
                    self.read(jobs={"total_count": len(jobs), "jobs": jobs})

    def test_missing_expired_ambiguous_or_outside_window_receipt_is_refused(self) -> None:
        artifact = self.artifacts["artifacts"][0]
        for artifacts in ([], [artifact, artifact], [{**artifact, "expired": True}],
                          [{**artifact, "created_at": "2026-10-31T00:04:00Z"}],
                          [{**artifact, "workflow_run": {**artifact["workflow_run"], "head_repository_id": 10}}]):
            with self.subTest(artifacts=artifacts):
                with self.assertRaises(RuntimeError):
                    self.read(artifacts={"total_count": len(artifacts), "artifacts": artifacts})

    def test_truncated_metadata_is_refused(self) -> None:
        with self.assertRaises(RuntimeError):
            self.read(jobs={**self.jobs, "total_count": 101})
        with self.assertRaises(RuntimeError):
            self.read(artifacts={**self.artifacts, "total_count": 101})

    def test_migration_read_never_waits_for_a_rate_limit_reset(self) -> None:
        limited = r2.urllib.error.HTTPError("https://api.github.com", 429, "limited", {"Retry-After": "3600"}, None)
        with mock.patch.object(r2.urllib.request, "urlopen", side_effect=limited) as opened:
            with self.assertRaisesRegex(RuntimeError, "compiled-source provenance"):
                r2.provenance_json("repos/manaflow-ai/cmux/actions/runs/123", "test")
        self.assertEqual(opened.call_count, 1)
        self.assertEqual(opened.call_args.kwargs["timeout"], 15)


class PublicationBoundaryTests(unittest.TestCase):
    def test_source_refusal_reaches_every_followup_and_handoff_uses_written_bytes(self) -> None:
        jobs = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]
        publish = jobs["publish-nightly"]
        self.assertIn("steps.upload_next_appcasts.outputs.publication_refused == 'true'", publish["outputs"]["refused"])
        for name in ("publish-nightly-next-github", "generate-nightly-deltas", "republish-nightly-deltas",
                     "sign-release-notes", "publish-release-notes"):
            self.assertIn("needs.publish-nightly.outputs.refused != 'true'", jobs[name]["if"], name)
        steps = publish["steps"]
        write = next(i for i, step in enumerate(steps) if step.get("id") == "upload_next_appcasts")
        for name in ("Hand the published feed to the GitHub release job", "Upload the published feed for the GitHub release job"):
            i = next(i for i, step in enumerate(steps) if step.get("name") == name)
            self.assertGreater(i, write)
            self.assertIn("steps.upload_next_appcasts.outputs.feed_current == 'true'", steps[i]["if"])
        outcome = next(step for step in steps if step.get("id") == "tag-outcome")
        self.assertEqual(outcome["env"]["NEXT_FEED_CURRENT"], "${{ steps.upload_next_appcasts.outputs.feed_current }}")
        readback = next(step for step in steps if step.get("id") == "feedcheck")
        self.assertIn("steps.upload_next_appcasts.outputs.feed_written == 'true'", readback["if"])

    def test_one_refused_feed_cannot_be_hidden_by_another_accepted_feed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            ci = directory / "ci"
            ci.mkdir()
            (ci / "nightly-next-guard.py").write_text("")
            (ci / "publish-nightly-next-r2.py").write_text(
                "import json, os, pathlib, sys\n"
                "args=sys.argv\n"
                "name=pathlib.Path(args[args.index('--feed')+1]).name\n"
                "pathlib.Path(args[args.index('--github-output')+1]).write_text(json.loads(os.environ['FEED_RESULTS'])[name])\n")
            accepted = "feed_written=true\nfeed_current=true\n"
            refused = "feed_written=false\npublication_refused=true\n"
            output = directory / "out"
            env = {**os.environ, "PUBLISH_TOOLING": temp, "SOURCE_SHA": "a" * 40,
                   "GITHUB_OUTPUT": str(output), "RELEASE_POKE_URL": "",
                   "FEED_RESULTS": json.dumps({"accepted.xml": accepted, "refused.xml": refused})}
            for feeds in ("accepted.xml refused.xml", "refused.xml accepted.xml"):
                with self.subTest(feeds=feeds):
                    output.write_text("")
                    env["NIGHTLY_FEEDS"] = feeds
                    subprocess.run(["bash", str(ROOT / "scripts/ci/nightly-steps/publish-upload-next-appcasts.sh")],
                                   env=env, check=True, capture_output=True, text=True)
                    self.assertEqual(dict(line.split("=", 1) for line in output.read_text().splitlines()),
                                     {"feed_written": "true", "feed_current": "false", "publication_refused": "true"})

    def test_github_writers_require_the_exact_build_on_the_live_feed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            curl = directory / "curl"
            curl.write_text("#!/usr/bin/env python3\nimport os, pathlib, sys\npathlib.Path(sys.argv[sys.argv.index('-o') + 1]).write_text(os.environ['LIVE_FEED'])\n")
            curl.chmod(0o755)
            output = directory / "out"
            env = {**os.environ, "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                   "GITHUB_OUTPUT": str(output), "RUNNER_TEMP": temp, "NIGHTLY_BUILD": "300",
                   "NIGHTLY_NEXT_FEED_BASE": BASE, "GITHUB_RUN_ID": "test"}
            step_dir = ROOT / "scripts/ci/nightly-steps"
            subprocess.run(["bash", str(step_dir / "github-names-install-still-newest.sh")], env=env, check=True)
            for live_build in (200, 300, 400):
                with self.subTest(live_build=live_build):
                    env["LIVE_FEED"] = feed((live_build, "x", 1))
                    output.write_text("")
                    subprocess.run(["bash", str(step_dir / "github-publish-still-newest.sh")], env=env, check=True,
                                   capture_output=True, text=True)
                    self.assertEqual(output.read_text().strip(), "newest=" + str(live_build == 300).lower())
                    mutable = subprocess.run([str(directory / "still-newest")], env=env, capture_output=True, text=True)
                    self.assertEqual(mutable.returncode, 0 if live_build == 300 else 1)


class KeepEarlierBuildsTests(FeedWriteCase):
    """The feed keeps two builds, so nightly-next-rollback.yml always has a published build to serve."""

    def builds(self) -> list[int]:
        return [build for _, build in r2.item_builds(self.path.read_bytes())]

    def test_the_live_feeds_newest_earlier_build_stays_beside_the_new_one(self) -> None:
        live = feed((150, f"{BASE}/cmux-nightly-next-macos-arm64-150.dmg", 4),
                    (100, f"{BASE}/cmux-nightly-next-macos-arm64-100.dmg", 3)).encode()
        self.assertEqual(self.run_with([live], [0]), 0)
        self.assertEqual(self.builds(), [200, 150])
        # The kept item is the live feed's bytes, signature and all.
        kept = next(m.group(0) for m, build in r2.item_builds(live) if build == 150)
        self.assertIn(kept, self.path.read_bytes())

    def test_a_feed_that_already_has_two_builds_is_written_as_it_is(self) -> None:
        self.path.write_text(feed((200, "a", 5), (190, "b", 5)), encoding="utf-8")
        before = self.path.read_bytes()
        self.assertEqual(self.run_with([feed((150, "c", 4)).encode()], [0]), 0)
        self.assertEqual(self.path.read_bytes(), before)

    def test_a_build_that_landed_meanwhile_replaces_an_older_kept_one(self) -> None:
        # Ours was combined from an older read ([200, 150]); the live feed now has 190 above 150.
        self.path.write_text(feed((200, "a", 5), (150, "c", 4)), encoding="utf-8")
        self.assertEqual(self.run_with([feed((190, "b", 5), (150, "c", 4)).encode()], [0]), 0)
        self.assertIn(190, self.builds())

    def test_a_dev_tagged_build_is_never_the_kept_one(self) -> None:
        live = feed((180, "d", 1), (150, "c", 4), channel={180: "cmux-next-dev", 150: "cmux-next"}).encode()
        self.assertEqual(self.run_with([live], [0]), 0)
        self.assertEqual(self.builds(), [200, 150])

    def test_a_promotion_that_raced_the_write_keeps_the_nightly_item(self) -> None:
        # Ours tags 190 Dev; the live feed promoted it to Nightly meanwhile. The written feed serves
        # 190 to Nightly apps, so a rollback of 200 has a build to serve.
        self.path.write_text(feed((200, "a", 5), (190, "b", 5), channel={200: "cmux-next", 190: "cmux-next-dev"}),
                             encoding="utf-8")
        live = feed((200, "a", 5), (190, "b", 5), channel={200: "cmux-next", 190: "cmux-next"}).encode()
        self.assertEqual(self.run_with([live], [0], same_build=True), 0)
        text = self.path.read_bytes()
        self.assertEqual(self.builds(), [200, 190])
        self.assertNotIn(b"cmux-next-dev", text)

    def test_the_promotion_race_survives_a_lost_cas(self) -> None:
        self.path.write_text(feed((200, "a", 5), (190, "b", 5), channel={190: "cmux-next-dev"}), encoding="utf-8")
        first = feed((150, "c", 4)).encode()
        second = feed((190, "b", 5), (150, "c", 4), channel={190: "cmux-next"}).encode()
        self.assertEqual(self.run_with([first, second], [r2.CONFLICT, 0]), 0)
        self.assertEqual(self.builds(), [200, 190])
        self.assertNotIn(b"cmux-next-dev", self.path.read_bytes())

    def test_a_lost_race_keeps_from_the_feed_it_read_last(self) -> None:
        first, second = feed((100, "x", 1)).encode(), feed((180, "y", 1), (100, "x", 1)).encode()
        self.assertEqual(self.run_with([first, second], [r2.CONFLICT, 0]), 0)
        self.assertEqual(self.builds(), [200, 180])

    def test_no_live_feed_writes_the_new_build_alone(self) -> None:
        self.assertEqual(self.run_with([None], [0]), 0)
        self.assertEqual(self.builds(), [200])

    def test_the_delta_republish_keeps_the_earlier_build_too(self) -> None:
        live = feed((200, "x", 1), (150, f"{BASE}/cmux-nightly-next-macos-arm64-150.dmg", 4)).encode()
        self.assertEqual(self.run_with([live], [0], same_build=True), 0)
        self.assertEqual(self.builds(), [200, 150])

    def test_a_rollback_of_the_written_feed_serves_the_kept_build(self) -> None:
        spec = importlib.util.spec_from_file_location("rollback", ROOT / "scripts" / "ci" / "nightly_next_feed_rollback.py")
        rollback = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(rollback)
        live = feed((150, f"{BASE}/cmux-nightly-next-macos-arm64-150.dmg", 4)).encode()
        self.assertEqual(self.run_with([live], [0]), 0)
        _, summary = rollback.plan(self.path.read_text(encoding="utf-8"))
        self.assertEqual(summary["pulled"], ["200"])
        self.assertEqual(summary["serving"], "150")


class UploadTests(unittest.TestCase):
    def test_every_file_goes_up_at_once_and_each_failure_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, ENV):
            files = [Path(tmp) / f"cmux-nightly-next-macos-arm64-{n}.delta" for n in range(3)]
            for f in files:
                f.write_bytes(b"x")
            seen = []

            def fake_one(path: Path) -> str:
                seen.append(path.name)
                if path.name.endswith("1.delta"):
                    raise RuntimeError("boom")
                return path.name

            with mock.patch.object(r2, "upload_one", fake_one):
                self.assertEqual(r2.upload(files), 1)
            self.assertEqual(sorted(seen), sorted(f.name for f in files))



class ReadbackTests(unittest.TestCase):
    """upload_one reads the object back from R2 and compares its bytes' SHA-256 with the local
    file's, not only the length, and still needs the public base to serve it at that length."""

    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        for patcher in (mock.patch.dict(os.environ, ENV), mock.patch.object(r2, "guard_key", lambda key: None),
                        mock.patch.object(r2, "_sleep", lambda seconds: None)):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.path = Path(self.dir.name) / "cmux-nightly-next-macos-arm64-200.dmg"
        self.path.write_bytes(b"the built dmg")
        self.calls: list[list[str]] = []

    def upload_storing(self, stored: bytes, public: int | None = None) -> str:
        def fake_run(args, *rest, **kwargs):
            self.calls.append(args)
            if "--download-to" in args:
                Path(args[args.index("--download-to") + 1]).write_bytes(stored)
            return subprocess.CompletedProcess(args, 0)

        served = len(stored) if public is None else public
        with mock.patch.object(r2.subprocess, "run", fake_run), \
                mock.patch.object(r2, "public_length", lambda url, attempts=5: served):
            return r2.upload_one(self.path)

    def test_the_same_bytes_pass_and_name_their_digest(self) -> None:
        line = self.upload_storing(b"the built dmg")
        self.assertIn(hashlib.sha256(b"the built dmg").hexdigest(), line)
        readback = self.calls[-1]
        self.assertEqual(readback[readback.index("--key") + 1], "nightly-next/next/cmux-nightly-next-macos-arm64-200.dmg")

    def test_other_bytes_of_the_same_length_fail(self) -> None:
        stale = b"a stale dmg!!"
        self.assertEqual(len(stale), self.path.stat().st_size)
        with self.assertRaisesRegex(RuntimeError, "SHA-256"):
            self.upload_storing(stale)

    def test_a_short_object_fails(self) -> None:
        with self.assertRaises(RuntimeError):
            self.upload_storing(b"the built")

    def test_a_public_base_serving_another_length_fails(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "serves"):
            self.upload_storing(b"the built dmg", public=3)

    def test_a_failed_readback_fails(self) -> None:
        def fake_run(args, *rest, **kwargs):
            if "--download-to" in args:
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0)

        with mock.patch.object(r2.subprocess, "run", fake_run), self.assertRaises(subprocess.CalledProcessError):
            r2.upload_one(self.path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
