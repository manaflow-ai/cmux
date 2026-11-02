#!/usr/bin/env python3
"""Pulling bad builds off the cmux NEXT feed (scripts/ci/nightly_next_feed_rollback.py)."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/nightly_next_feed_rollback.py"
spec = importlib.util.spec_from_file_location("feed_rollback", SCRIPT)
rollback = importlib.util.module_from_spec(spec)
sys.modules["feed_rollback"] = rollback
spec.loader.exec_module(rollback)

GUARD = Path(__file__).resolve().parents[1] / "scripts/ci/nightly-next-guard.py"
BASE = "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/"


def item(build: str, delta_from: str | None = None) -> str:
    delta = ""
    if delta_from:
        delta = (f"""            <sparkle:deltas>
                <enclosure url="{BASE}cmux-nightly-next-macos-arm64-{build}-{delta_from}.delta" sparkle:deltaFrom="{delta_from}" length="7" type="application/octet-stream" sparkle:edSignature="d=="/>
            </sparkle:deltas>
""")
    return f"""        <item>
            <sparkle:channel>cmux-next</sparkle:channel>
            <title>1.0.0-nightly.{build}</title>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>1.0.0-nightly.{build}</sparkle:shortVersionString>
            <enclosure url="{BASE}cmux-nightly-next-macos-arm64-{build}.dmg" length="1" type="application/octet-stream" sparkle:edSignature="s=="/>
{delta}        </item>
"""


def feed(*entries: str) -> str:
    return ("""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>cmux NEXT</title>
""" + "".join(entries) + """    </channel>
</rss>
""")


LIVE = feed(item("3917159104301", "3917061587901"), item("3917061587901"))


class PlanTests(unittest.TestCase):
    def test_default_pulls_the_newest_build_and_keeps_the_rest_byte_for_byte(self):
        text, summary = rollback.plan(LIVE)
        self.assertEqual(summary, {"pulled": ["3917159104301"], "serving": "3917061587901",
                                   "serving_url": f"{BASE}cmux-nightly-next-macos-arm64-3917061587901.dmg",
                                   "changed": True, "record": ["3917159104301"], "record_complete": True})
        self.assertEqual(text, feed(item("3917061587901")))

    def test_bad_pulls_that_build_and_every_newer_one(self):
        live = feed(item("30"), item("20"), item("10"))
        text, summary = rollback.plan(live, bad="20")
        self.assertEqual(summary["pulled"], ["30", "20"])
        self.assertEqual(summary["serving"], "10")
        self.assertEqual(text, feed(item("10")))

    def test_to_keeps_that_build_as_the_newest(self):
        live = feed(item("30"), item("20"), item("10"))
        text, summary = rollback.plan(live, to="20")
        self.assertEqual(summary["pulled"], ["30"])
        self.assertEqual(text, feed(item("20"), item("10")))

    def test_builds_compare_as_numbers(self):
        live = feed(item("9"), item("10"))
        _, summary = rollback.plan(live)
        self.assertEqual(summary["pulled"], ["10"])
        self.assertEqual(summary["serving"], "9")

    def test_a_build_already_off_the_feed_is_a_no_op(self):
        # The canary names the build it launched; when an earlier pull already
        # took it off, nothing on the feed is at or above it.
        text, summary = rollback.plan(LIVE, bad="3917159104302")
        self.assertEqual(summary["pulled"], [])
        self.assertEqual(summary["serving"], "3917159104301")
        self.assertFalse(summary["changed"])
        self.assertTrue(summary["serving_url"].endswith("-3917159104301.dmg"))
        self.assertEqual(text, LIVE)

    def test_refuses_to_empty_the_feed(self):
        with self.assertRaisesRegex(rollback.Refused, "empty"):
            rollback.plan(feed(item("10")))
        with self.assertRaisesRegex(rollback.Refused, "empty"):
            rollback.plan(LIVE, bad="1")

    def test_refuses_a_to_build_that_is_not_on_the_feed(self):
        with self.assertRaisesRegex(rollback.Refused, "not on the feed"):
            rollback.plan(LIVE, to="5")

    def test_refuses_non_numeric_input(self):
        with self.assertRaisesRegex(rollback.Refused, "not a number"):
            rollback.plan(LIVE, bad="latest")
        with self.assertRaisesRegex(rollback.Refused, "numeric"):
            rollback.plan(feed(item("10")).replace("<sparkle:version>10", "<sparkle:version>1.0"))
        with self.assertRaisesRegex(rollback.Refused, "no items"):
            rollback.plan("<rss/>")


class CommandTests(unittest.TestCase):
    def run_plan(self, *args: str) -> tuple[int, dict | None, str, Path]:
        work = Path(tempfile.mkdtemp())
        (work / "live.xml").write_text(LIVE, encoding="utf-8")
        out = work / "appcast-arm64.xml"
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "plan", "--feed", str(work / "live.xml"),
                                 "--out", str(out), *args], capture_output=True, text=True)
        summary = json.loads(result.stdout) if result.returncode == 0 else None
        return result.returncode, summary, result.stderr, out

    def test_the_pulled_feed_passes_the_nightly_next_guard(self):
        status, summary, _, out = self.run_plan()
        self.assertEqual(status, 0)
        self.assertTrue(summary["changed"])
        env = {**os.environ, "NIGHTLY_NEXT_FEED_BASE": "https://files-next.cmux.com/nightly-next/next",
               "NIGHTLY_NEXT_R2_BUCKET": "cmux-nightly-next", "NIGHTLY_NEXT_R2_PREFIX": "nightly-next/next/"}
        guard = subprocess.run([sys.executable, "-I", str(GUARD), "appcast", str(out)],
                               capture_output=True, text=True, env=env)
        self.assertEqual(guard.returncode, 0, guard.stdout + guard.stderr)

    def test_no_change_writes_no_file(self):
        status, summary, _, out = self.run_plan("--bad", "4000000000000")
        self.assertEqual(status, 0)
        self.assertFalse(summary["changed"])
        self.assertFalse(out.exists())

    def test_refusal_exits_one(self):
        status, _, stderr, out = self.run_plan("--to", "1")
        self.assertEqual(status, 1)
        self.assertIn("refused", stderr)
        self.assertFalse(out.exists())


class PulledListTests(unittest.TestCase):
    AT = "2026-10-20T21:00:00Z"

    def test_first_pull_lists_every_pulled_build_newest_first(self):
        entries = rollback.pulled_list(None, ["300", "400"], "200", "crashes at launch", self.AT)
        self.assertEqual([e["build"] for e in entries], ["400", "300"])
        self.assertEqual(entries[0], {"build": "400", "reason": "crashes at launch", "pulledAt": self.AT, "serve": "200"})

    def test_merges_into_the_existing_list_and_replaces_a_repeat(self):
        existing = json.dumps([{"build": "150", "reason": "old", "pulledAt": "x", "serve": "140"},
                               {"build": "300", "reason": "first", "pulledAt": "x", "serve": "200"}])
        entries = rollback.pulled_list(existing, ["300"], "250", "again", self.AT)
        self.assertEqual([e["build"] for e in entries], ["300", "150"])
        self.assertEqual(entries[0]["reason"], "again")

    def test_serving_a_pulled_build_again_clears_it(self):
        existing = json.dumps([{"build": "300", "reason": "r", "pulledAt": "x", "serve": "200"}])
        self.assertEqual(rollback.pulled_list(existing, ["400"], "300", "r", self.AT)[0]["build"], "400")
        self.assertNotIn("300", [e["build"] for e in rollback.pulled_list(existing, ["400"], "300", "r", self.AT)])

    def test_unreadable_existing_counts_as_empty_and_bad_builds_refuse(self):
        self.assertEqual(len(rollback.pulled_list("not json", ["5"], "4", "r", self.AT)), 1)
        with self.assertRaises(rollback.Refused):
            rollback.pulled_list(None, ["5x"], "4", "r", self.AT)

    def test_cli_writes_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "pulled.json"
            code = rollback.main(["pulled", "--existing", str(Path(tmp) / "missing.json"), "--pulled", "9 8",
                                  "--serve", "7", "--reason", "r", "--at", self.AT, "--out", str(out)])
            self.assertEqual(code, 0)
            self.assertEqual([e["build"] for e in json.loads(out.read_text())], ["9", "8"])


class RecordTests(unittest.TestCase):
    """plan's "record": the builds pulled.json must list, also on a re-run that pulls nothing."""

    def test_a_real_pull_records_every_pulled_build(self):
        _, summary = rollback.plan(feed(item("30"), item("20"), item("10")), bad="20")
        self.assertEqual(summary["record"], ["30", "20"])

    def test_a_rerun_of_a_named_build_already_off_the_feed_still_records_it(self):
        # The first run pulled 30; its pulled.json write failed. The re-run sees changed false.
        live = feed(item("20"), item("10"))
        for kwargs in ({"bad": "30"}, {"bad": "30", "if_newest": "30"}, {"if_newest": "30"}):
            _, summary = rollback.plan(live, **kwargs)
            self.assertFalse(summary["changed"], kwargs)
            self.assertEqual(summary["pulled"], [], kwargs)
            self.assertEqual(summary["record"], ["30"], kwargs)

    def test_a_rerun_says_when_it_cannot_name_every_build_an_earlier_pull_took(self):
        # bad=20 on [30, 20, 10] pulled 30 and 20; a new run sees only [10] and can name 20 alone.
        _, summary = rollback.plan(feed(item("10")), bad="20")
        self.assertEqual(summary["record"], ["20"])
        self.assertFalse(summary["record_complete"])
        # to=20 on [30, 20, 10] pulled 30; a new run sees [20, 10] and can name nothing.
        _, summary = rollback.plan(feed(item("20"), item("10")), to="20")
        self.assertEqual(summary["record"], [])
        self.assertFalse(summary["record_complete"])
        # An if_newest pull takes that one build alone: the record is complete.
        _, summary = rollback.plan(feed(item("20"), item("10")), bad="30", if_newest="30")
        self.assertEqual((summary["record"], summary["record_complete"]), (["30"], True))

    def test_nothing_is_recorded_for_a_build_still_served_or_below_it(self):
        live = feed(item("30"), item("20"), item("10"))
        # 25 is below the served 30 (a newer build went out after it): nothing to record.
        self.assertEqual(rollback.plan(feed(item("30"), item("10")), bad="25", if_newest="25")[1]["record"], [])
        self.assertEqual(rollback.plan(live, if_newest="20")[1]["record"], [])
        self.assertEqual(rollback.plan(feed(item("20"), item("10")), to="20")[1]["record"], [])


class FakeStore:
    """pulled.json on R2: read() -> bytes or None, write(body, replace_sha256) -> written (False: conflict)."""

    def __init__(self, body: bytes | None = None, script: list | None = None):
        self.body, self.script, self.writes, self.reads = body, list(script or []), [], 0

    def step(self, kind: str):
        if self.script and self.script[0][0] == kind:
            action = self.script.pop(0)[1]
            if isinstance(action, Exception):
                raise action
            return action
        return None

    def read(self):
        self.reads += 1
        self.step("read")
        return self.body

    def write(self, body: bytes, replace_sha256: str | None) -> bool:
        if self.step("write") == "conflict":
            self.body = json.dumps([{"build": "5", "reason": "other run", "pulledAt": "x", "serve": "4"}]).encode()
            return False
        current = None if self.body is None else rollback.sha256(self.body)
        if current != replace_sha256:
            return False
        self.writes.append(body)
        self.body = body
        return True


class ReconcileTests(unittest.TestCase):
    AT = "2026-10-20T21:00:00Z"

    def go(self, store: FakeStore, record=("30",), attempts=4):
        slept = []
        result = rollback.reconcile(store.read, store.write, list(record), "20", "crash", self.AT,
                                    attempts=attempts, delay=1, sleep=slept.append)
        return result, slept

    def listed(self, store: FakeStore) -> list[str]:
        return [entry["build"] for entry in json.loads(store.body)]

    def test_the_first_pull_creates_the_list(self):
        store = FakeStore()
        result, slept = self.go(store)
        self.assertTrue(result["written"])
        self.assertEqual(self.listed(store), ["30"])
        self.assertEqual(slept, [])

    def test_a_concurrent_write_is_read_again_and_merged(self):
        store = FakeStore(script=[("write", "conflict")])
        result, slept = self.go(store)
        self.assertTrue(result["written"])
        self.assertEqual(result["attempts"], 2)
        self.assertEqual(store.reads, 2)
        self.assertEqual(self.listed(store), ["30", "5"], "the other run's entry is kept")
        self.assertEqual(slept, [1])

    def test_http_errors_are_retried(self):
        store = FakeStore(script=[("read", rollback.StoreError("HTTP 503")), ("write", rollback.StoreError("HTTP 500"))])
        result, slept = self.go(store)
        self.assertTrue(result["written"])
        self.assertEqual(result["attempts"], 3)
        self.assertEqual(slept, [1, 2])

    def test_gives_up_after_the_last_attempt(self):
        store = FakeStore(script=[("read", rollback.StoreError("HTTP 503"))] * 3)
        with self.assertRaisesRegex(rollback.StoreError, "3 attempts.*HTTP 503"):
            self.go(store, attempts=3)
        self.assertEqual(store.writes, [])

    def test_a_list_that_already_has_the_builds_is_not_written_again(self):
        existing = json.dumps([{"build": "30", "reason": "first run", "pulledAt": "x", "serve": "20"}]).encode()
        store = FakeStore(body=existing)
        result, _ = self.go(store)
        self.assertFalse(result["written"])
        self.assertEqual(store.writes, [])
        self.assertEqual(store.body, existing)

    def test_nothing_to_record_reads_nothing(self):
        store = FakeStore()
        result, _ = self.go(store, record=())
        self.assertFalse(result["written"])
        self.assertEqual(store.reads, 0)

    def test_cli_fails_when_pulled_json_is_never_written(self):
        # The upload helper answers HTTP errors on every call: exit 1, never 0.
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "helper.py"
            helper.write_text("import sys\nsys.stderr.write('HTTP 500\\n')\nsys.exit(1)\n")
            code = rollback.main(["reconcile", "--record", "30", "--serve", "20", "--reason", "r", "--at", self.AT,
                                  "--endpoint-url", "https://r2.invalid", "--bucket", "b", "--key", "k/pulled.json",
                                  "--work", tmp, "--attempts", "2", "--delay", "0", "--uploader", str(helper)])
            self.assertEqual(code, 1)


ROOT = Path(__file__).resolve().parents[1]


class WorkflowTests(unittest.TestCase):
    """nightly-next-rollback.yml: the run is not green until pulled.json lists the pulled builds."""

    text = (ROOT / ".github/workflows/nightly-next-rollback.yml").read_text()

    def job(self, name: str) -> str:
        start = self.text.index(f"\n  {name}:\n")
        nxt = re.search(r"\n  [a-z][a-z0-9-]*:\n", self.text[start + 1:])
        return self.text[start:start + 1 + nxt.start()] if nxt else self.text[start:]

    def test_no_pulled_json_failure_is_hidden(self):
        self.assertFalse("continue-on-error" in self.text, "a failed pulled.json write must leave the run red")

    def test_pulled_json_is_its_own_job_that_a_rerun_reaches(self):
        job = self.job("pulled-json")
        self.assertIn("needs: rollback", job)
        self.assertIn("environment: release-next", job)
        condition = re.search(r"\n    if: (.*)\n", job).group(1)
        self.assertNotIn("changed", condition, "a re-run pulls nothing (changed false) and must still reconcile")
        self.assertIn("needs.rollback.outputs.record != ''", condition)
        self.assertIn("!inputs.dry_run", condition)
        self.assertIn("scripts/ci/nightly_next_feed_rollback.py reconcile", job)
        self.assertIn("nightly-next-guard.py r2-key", job)
        self.assertIn("record: ${{ steps.plan.outputs.record }}", self.job("rollback"))

    def test_the_exact_recovery_is_named_where_a_new_run_cannot_be_exact(self):
        rollback_job = self.job("rollback")
        self.assertIn("record_complete={", rollback_job)
        self.assertIn("RECORD_COMPLETE: ${{ steps.plan.outputs.record_complete }}", rollback_job)
        self.assertIn("Re-run failed jobs", rollback_job)
        self.assertIn("Re-run failed jobs", self.job("pulled-json"))

    def test_the_fix_forward_does_not_wait_on_pulled_json(self):
        self.assertNotIn("pulled-json", self.job("fix-forward"))
        after_feed = self.job("rollback").split("- name: Read the feed back")[1].split("- name: Summary")[0]
        self.assertFalse("pulled.json" in after_feed, "the rollback job no longer writes pulled.json itself")


if __name__ == "__main__":
    unittest.main()
