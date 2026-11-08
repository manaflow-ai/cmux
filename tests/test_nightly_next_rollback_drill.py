#!/usr/bin/env python3
"""The weekly rollback drill's feed half (scripts/ci/nightly_next_rollback_drill.py, nightly-next-rollback-drill.yml)."""
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

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


drill = load("rollback_drill", ROOT / "scripts/ci/nightly_next_rollback_drill.py")
rollback = load("feed_rollback_for_drill", ROOT / "scripts/ci/nightly_next_feed_rollback.py")
GUARD = ROOT / "scripts/ci/nightly-next-guard.py"
BASE = "https://files-next.cmux.com/nightly-next/"


def item(build: str, channel: str = "cmux-next", delta_from: str | None = None) -> str:
    delta = ""
    if delta_from:
        delta = (f'            <sparkle:deltas>\n                <enclosure url="{BASE}cmux-nightly-next-macos-arm64-'
                 f'{build}-{delta_from}.delta" sparkle:deltaFrom="{delta_from}" length="7" '
                 'type="application/octet-stream" sparkle:edSignature="d=="/>\n            </sparkle:deltas>\n')
    return (f"        <item>\n            <sparkle:channel>{channel}</sparkle:channel>\n"
            f"            <title>1.0.0-nightly.{build}</title>\n            <sparkle:version>{build}</sparkle:version>\n"
            f'            <enclosure url="{BASE}cmux-nightly-next-macos-arm64-{build}.dmg" length="1" '
            f'type="application/octet-stream" sparkle:edSignature="s{build}=="/>\n{delta}        </item>\n')


def feed(*entries: str) -> str:
    return ('<?xml version="1.0" standalone="yes"?>\n<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/'
            'sparkle" version="2.0">\n    <channel>\n        <title>cmux NEXT</title>\n'
            + "".join(entries) + "    </channel>\n</rss>\n")


N, K = item("300", delta_from="200"), item("200")
LIVE = feed(item("400", channel="cmux-next-canary"), N, K, item("100"))


class PickTests(unittest.TestCase):
    def test_keeps_n_and_k_byte_for_byte_and_names_the_run(self):
        text, summary = drill.pick(LIVE, "42", "2")
        self.assertEqual(summary["bad"], "300")
        self.assertEqual(summary["kept"], "200")
        self.assertTrue(summary["kept_url"].endswith("-200.dmg"))
        run = drill.drill_run_element("42", "2")
        self.assertEqual(text, feed(run, N, K))

    def test_a_canary_only_item_is_never_n(self):
        # A NIGHTLY on its default ring is never offered cmux-next-canary, so N is the newest Nightly-ring build.
        _, summary = drill.pick(LIVE, "1", "1")
        self.assertNotEqual(summary["bad"], "400")

    def test_a_feed_with_one_nightly_item_cannot_be_drilled(self):
        with self.assertRaisesRegex(drill.Refused, "1 Nightly-ring item"):
            drill.pick(feed(N), "1", "1")

    def test_a_second_pick_replaces_the_run_element(self):
        once, _ = drill.pick(LIVE, "1", "1")
        twice, _ = drill.pick(once, "2", "1")
        self.assertEqual(twice.count("<cmux:drillRun"), 1)
        self.assertIn(">2</cmux:drillRun>", twice)

    def test_the_real_pull_keeps_the_run_and_k_and_the_guard_allows_both(self):
        text, _ = drill.pick(LIVE, "42", "1")
        pulled, summary = rollback.plan(text, bad="300", if_newest="300")
        self.assertEqual((summary["pulled"], summary["serving"]), (["300"], "200"))
        self.assertIn(drill.drill_run_element("42", "1"), pulled)
        self.assertEqual(pulled, feed(drill.drill_run_element("42", "1"), K))
        env = {**os.environ, "NIGHTLY_NEXT_FEED_BASE": BASE.rstrip("/")}
        with tempfile.TemporaryDirectory() as tmp:
            for name, body in (("drill.xml", text), ("pulled.xml", pulled)):
                path = Path(tmp) / name
                path.write_text(body)
                result = subprocess.run([sys.executable, str(GUARD), "appcast", str(path)], env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)


AT = "2026-11-09T09:15:04Z"
RUN = {"run_id": "7", "run_attempt": "1", "run_url": "https://github.com/manaflow-ai/cmux/actions/runs/7"}


class ReceiptTests(unittest.TestCase):
    def test_publish_leaves_the_pull_empty(self):
        receipt = drill.publish_receipt("300", "200", AT, RUN)
        self.assertEqual(receipt["outcome"], "published")
        self.assertEqual((receipt["pull_ordered_at"], receipt["served_at"]), ("", ""))
        self.assertEqual(receipt["feed_route"], "r2")
        self.assertEqual(receipt["publish"]["run_id"], "7")

    def test_check_takes_only_a_fresh_unpulled_publish(self):
        receipt = drill.publish_receipt("300", "200", AT, RUN)
        self.assertEqual(drill.check_receipt(receipt, "2026-11-09T10:15:00Z"), {"bad": "300", "kept": "200"})
        with self.assertRaisesRegex(drill.Refused, "not this week's"):
            drill.check_receipt(receipt, "2026-11-16T10:15:00Z")
        with self.assertRaisesRegex(drill.Refused, "not this week's"):
            drill.check_receipt(receipt, "2026-11-09T09:00:00Z")
        pulled = drill.pull_receipt(receipt, "2026-11-09T10:15:00Z", "2026-11-09T10:16:10Z", "served", RUN)
        with self.assertRaisesRegex(drill.Refused, "already pulled"):
            drill.check_receipt(pulled, "2026-11-09T10:20:00Z")

    def test_pull_records_both_times_or_a_failure(self):
        receipt = drill.publish_receipt("300", "200", AT, RUN)
        pull_run = {**RUN, "run_id": "8"}
        done = drill.pull_receipt(receipt, "2026-11-09T10:15:00Z", "2026-11-09T10:16:10Z", "served", pull_run)
        self.assertEqual((done["outcome"], done["publish"]["run_id"], done["pull"]["run_id"]), ("served", "7", "8"))
        failed = drill.pull_receipt(receipt, "2026-11-09T10:15:00Z", "", "failed", pull_run)
        self.assertEqual((failed["outcome"], failed["served_at"]), ("failed", ""))
        with self.assertRaisesRegex(drill.Refused, "at or after"):
            drill.pull_receipt(receipt, "2026-11-09T10:15:00Z", "2026-11-09T10:14:00Z", "served", pull_run)
        with self.assertRaisesRegex(drill.Refused, "not a published drill"):
            drill.pull_receipt(done, "2026-11-09T10:15:00Z", "", "failed", pull_run)

    def test_cli_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "receipt.json"
            common = ["--run-id", "7", "--attempt", "1", "--run-url", RUN["run_url"], "--out", str(out)]
            self.assertEqual(drill.main(["receipt", "publish", "--bad", "300", "--kept", "200", "--at", AT, *common]), 0)
            self.assertEqual(drill.main(["receipt", "check", "--existing", str(out), "--now", "2026-11-09T10:15:00Z"]), 0)
            self.assertEqual(drill.main(["receipt", "pull", "--existing", str(out), "--ordered-at",
                                         "2026-11-09T10:15:00Z", "--served-at", "2026-11-09T10:15:40Z",
                                         "--outcome", "served", *common]), 0)
            self.assertEqual(json.loads(out.read_text())["served_at"], "2026-11-09T10:15:40Z")
            self.assertEqual(drill.main(["receipt", "check", "--existing", str(out), "--now", "2026-11-09T10:20:00Z"]), 1)


class ServedTests(unittest.TestCase):
    def test_served_once_n_is_off_k_is_on_and_pulled_json_lists_n(self):
        pulled = json.dumps([{"build": "300", "serve": "200"}])
        self.assertEqual(drill.served(feed(K), pulled, "300", "200"), [])
        self.assertEqual(len(drill.served(feed(N, K), "[]", "300", "200")), 2)
        self.assertIn("does not offer 200", drill.served(feed(), pulled, "300", "200")[0])
        self.assertEqual(drill.served(feed(K), "not json", "300", "200"), ["pulled.json does not list 300"])


class WorkflowTests(unittest.TestCase):
    text = (ROOT / ".github/workflows/nightly-next-rollback-drill.yml").read_text()
    rollback_text = (ROOT / ".github/workflows/nightly-next-rollback.yml").read_text()

    def job(self, text: str, name: str) -> str:
        start = text.index(f"\n  {name}:\n")
        nxt = re.search(r"\n  [a-z][a-z0-9-]*:\n", text[start + 1:])
        return text[start:start + 1 + nxt.start()] if nxt else text[start:]

    def test_the_drill_calls_the_real_rollback_on_its_own_folder(self):
        job = self.job(self.text, "rollback")
        self.assertIn("uses: ./.github/workflows/nightly-next-rollback.yml", job)
        self.assertIn("drill: true", job)
        self.assertIn("if_newest: ${{ needs.order.outputs.bad }}", job)

    def test_the_rollback_reads_and_writes_the_drill_folder_and_skips_the_fix_forward(self):
        self.assertIn("workflow_call:", self.rollback_text)
        self.assertIn("NIGHTLY_FEED_DIR: ${{ inputs.drill && 'drill/' || '' }}", self.rollback_text)
        self.assertIn("NIGHTLY_NEXT_PULLED_PREFIX: ${{ inputs.drill && 'nightly-next/drill/' || 'nightly-next/next/' }}",
                      self.rollback_text)
        self.assertNotIn("${NIGHTLY_NEXT_FEED_BASE}/${NIGHTLY_APPCAST}", self.rollback_text)
        self.assertNotIn("${NIGHTLY_NEXT_R2_PREFIX}${NIGHTLY_APPCAST}", self.rollback_text)
        self.assertIn("&& !inputs.drill", self.job(self.rollback_text, "fix-forward"))

    def test_the_called_rollback_never_waits_on_its_caller(self):
        caller = re.search(r"\nconcurrency:\n  group: (.*)\n", self.text).group(1)
        called = re.search(r"\nconcurrency:\n  group: (.*)\n", self.rollback_text).group(1)
        self.assertIn("nightly-next-rollback-drill-call-", called)
        self.assertNotIn("drill-call", caller)

    def test_every_write_is_guarded_and_runs_only_on_nightly_next(self):
        for name in ("publish", "receipt"):
            job = self.job(self.text, name)
            self.assertIn("environment: release-next", job)
            self.assertIn("nightly-next-guard.py r2-key", job)
        for name in ("publish", "order"):
            self.assertIn("github.ref == 'refs/heads/nightly-next'", self.job(self.text, name))

    def test_main_s_cron_dispatches_each_step_on_nightly_next(self):
        self.assertIn('- cron: "15 9 * * 1"', self.text)
        self.assertIn('- cron: "15 10 * * 1"', self.text)
        job = self.job(self.text, "start")
        self.assertIn("github.event_name == 'schedule'", job)
        self.assertIn("github.event.schedule == '15 9 * * 1' && 'publish' || 'pull'", job)
        self.assertIn("--ref nightly-next -f step=\"$STEP\"", job)
        self.assertNotIn("secrets.", job)

    def test_a_failed_pull_still_writes_its_receipt(self):
        job = self.job(self.text, "receipt")
        self.assertIn("if: always() && needs.order.result == 'success'", job)
        self.assertIn("--outcome \"$outcome\"", job)


if __name__ == "__main__":
    unittest.main()
