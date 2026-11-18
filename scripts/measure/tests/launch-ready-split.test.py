#!/usr/bin/env python3
"""launch-ready.sh splits macOS's checks before `main` (verify) from the app's main to Home, and its headline is main
to Home with verify beside it, never inside it (CMUX-629; Leo: "for the startup times we shouldnt even count the mac
verifying bit per se or at least split it off from the other parts of startup times").

    python3 scripts/measure/tests/launch-ready-split.test.py

Runs launch-ready.sh's own LR-MEDIAN step (its inline Python, cut out of the script) over the driver's LR-RUN rows: a
copy=fresh side (each launch a new copy's first exec, about 2.4 s before main) and a warm relaunch side, and over a
real NIGHTLY step log from before the split (rows with no verify field get it from their marks).
"""
from __future__ import annotations

import json
import re
import statistics
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
MEASURE = HERE.parent
SCRIPT = MEASURE / "launch-ready.sh"
SPLIT = MEASURE / "launch-ready-split.py"
FIXTURE = HERE / "fixtures" / "launch-ready-verify-split.log"
NIGHTLY = MEASURE.parent / "bench" / "tests" / "fixtures" / "launch" / "launch-ready-nightly.log"
RUN = re.compile(r"^LR-RUN (\w+) (\{.*\})\s*$")


def median_step() -> str:
    """launch-ready.sh's LR-MEDIAN Python: the heredoc after `python3 -I - "$out/runs.jsonl"`."""
    text = SCRIPT.read_text()
    start = text.index("<<'PY'\n", text.index('python3 -I - "$out/runs.jsonl"')) + len("<<'PY'\n")
    return text[start:text.index("\nPY\n", start)]


def driver_rows(log: Path) -> list[dict]:
    rows = []
    for line in log.read_text().splitlines():
        m = RUN.match(line)
        if m:
            row = json.loads(m.group(2))
            row["side"] = m.group(1)
            rows.append(row)
    return rows


def run_median_step(rows: list[dict]) -> dict[str, list[str]]:
    with tempfile.TemporaryDirectory() as tmp:
        runs = Path(tmp) / "runs.jsonl"
        runs.write_text("".join(json.dumps(r) + "\n" for r in rows))
        out = subprocess.run([sys.executable, "-I", "-", str(runs), "kept", str(SPLIT)], input=median_step(),
                             capture_output=True, text=True, check=True).stdout
    lines: dict[str, list[str]] = {}
    for line in out.splitlines():
        kind, _, rest = line.partition(" ")
        lines.setdefault(kind, []).append(rest)
    return lines


def medians(lines: dict[str, list[str]]) -> dict[str, dict]:
    return {rest.split(" ", 1)[0]: json.loads(rest.split(" ", 1)[1]) for rest in lines.get("LR-MEDIAN", [])}


class VerifySplit(unittest.TestCase):
    def test_fresh_and_warm_sides_split_verify_from_main_to_home(self) -> None:
        rows = driver_rows(FIXTURE)
        lines = run_median_step(rows)
        med = medians(lines)
        for side in ("fresh", "warm"):
            done = [r for r in rows if r["side"] == side]
            want_verify = statistics.median(r["marks"]["main_start"] for r in done)
            want_home = statistics.median(r["marks"]["home.first_page"] - r["marks"]["main_start"] for r in done)
            got = med[side]
            self.assertEqual(got["headline"], "main_to_home", side)
            self.assertAlmostEqual(got["verify"], want_verify, places=1, msg=side)
            self.assertAlmostEqual(got["main_to_home"], round(want_home, 1), places=1, msg=side)
            # The headline leaves verify out: it is less than process start to Home by at least the smallest verify.
            self.assertLessEqual(got["main_to_home"],
                                 got["home.first_page"] - min(r["marks"]["main_start"] for r in done) + 0.05, side)
            # The finished_launching/window_on_screen/active run stays together: a consumer's regex reads it so.
            self.assertRegex(json.dumps(got), r'"finished_launching": [0-9.]+, "window_on_screen": [0-9.]+, "active": ')
        # copy=fresh pays its new copy's checks in verify, not in the headline: main to Home is about the same as warm.
        self.assertGreater(med["fresh"]["verify"], 2000)
        self.assertLess(med["fresh"]["main_to_home"], 1000)
        headline = {rest.split(" ", 1)[0]: rest for rest in lines["LR-HEADLINE"]}
        self.assertEqual(headline["fresh"], "fresh main_to_home=708.2 verify=2412.3 n=3")
        self.assertEqual(headline["warm"], "warm main_to_home=644.8 verify=588.4 n=3")

    def test_rows_from_before_the_split_get_it_from_their_marks(self) -> None:
        # A NIGHTLY step log from before the split: no verify field in its rows; main_start 594.4 median.
        rows = [r for r in driver_rows(NIGHTLY)]
        self.assertTrue(rows and all("verify" not in r for r in rows))
        med = medians(run_median_step(rows))["head"]
        self.assertEqual(med["verify"], 594.4)
        self.assertEqual(med["main_to_home"], 645.4)  # per launch: 645.4, 690.0, 648.9, 626.0, 627.1
        self.assertEqual(med["split_n"], 5)

    def test_driver_writes_both_fields_into_every_row(self) -> None:
        source = (MEASURE / "launch-ready.swift").read_text()
        self.assertIn('row["verify"]', source)
        self.assertIn('row["main_to_home"]', source)


if __name__ == "__main__":
    unittest.main()
