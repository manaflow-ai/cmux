#!/usr/bin/env python3
"""Each cron in cloud-journey-prod.yml starts exactly the matrix rows meant for it.

2026-11-25 review of #56076: the Claude rows were selected by `(schedule == '17 * * * *') == (model == 'stub')`, so the
new 15-minute Codex stub tick (false == false) also ran the real-Claude canary four more times an hour, spending the
journey login whose weekly limit already turned the real leg into skips. Every row now names its own crons and
SELECTED is one exact-element `contains(matrix.crons, github.event.schedule)` for all of them; this evaluates which
rows each registered cron selects.
"""
from pathlib import Path
import unittest

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cloud-journey-prod.yml"
SELECTED = (
    "${{ (github.event_name == 'schedule' && contains(matrix.crons, github.event.schedule)) || "
    "(github.event_name == 'workflow_dispatch' && inputs.model == matrix.model && inputs.agent == matrix.agent) }}"
)
WANT = {
    "17 * * * *": {("claude", "stub")},
    "47 */6 * * *": {("claude", "real"), ("codex", "real")},
    "47 1-5,7-11,13-17,19-23 * * *": {("claude", "real")},
    "7,22,37,52 * * * *": {("codex", "stub")},
}


def load():
    doc = yaml.safe_load(WORKFLOW.read_text())
    on = doc.get("on", doc.get(True))  # PyYAML reads a bare `on:` key as True.
    crons = [entry["cron"] for entry in on["schedule"]]
    job = next(j for j in doc["jobs"].values() if "matrix" in j.get("strategy", {}))
    return crons, job


class ScheduleRowsTest(unittest.TestCase):
    def test_selected_is_the_per_row_crons_rule(self):
        _, job = load()
        self.assertEqual(job["env"]["SELECTED"].strip(), SELECTED)

    def test_each_cron_selects_its_rows(self):
        crons, job = load()
        self.assertEqual(sorted(crons), sorted(WANT))
        rows = job["strategy"]["matrix"]["include"]
        for cron in crons:
            # contains() on an array is an exact element match, as Python's `in` on a list.
            got = {(r["agent"], r["model"]) for r in rows if cron in r["crons"]}
            self.assertEqual(got, WANT[cron], cron)

    def test_every_row_cron_is_registered(self):
        crons, job = load()
        for row in job["strategy"]["matrix"]["include"]:
            self.assertIsInstance(row["crons"], list, row)
            for cron in row["crons"]:
                self.assertIn(cron, crons, f"{row['agent']}/{row['model']} never fires: {cron!r} not in on.schedule")


if __name__ == "__main__":
    unittest.main()
