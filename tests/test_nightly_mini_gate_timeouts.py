"""In one-mini mode a nightly job's timeout leaves room for glaeda's capacity wait on cmux15.

On cmux15 glaeda's job-started hook waits for capacity units inside the job's "Set up runner" step, with no
time limit (teamleaderleo/glaeda scripts/glaeda-cmux-runner-hook, CAPACITY_WAIT), and that wait counts toward
the job's timeout-minutes. With vars.CI_NIGHTLY_MINI every nightly job competes for that one Mac and its
whole-Mac signing claim. On 2026-11-05 nightly-next run 41955554573's build-nightly-remote-daemon
(timeout 20) spent 04:47:32-05:07:28 in "Set up runner" and was cancelled before its first step, and main's
run 41967078498 lost pick-classic-sign-runner (timeout 6) the same way.

So every job the mode sends to the mini has, while the mode is on, a timeout of its own limit plus
GATE_MINUTES; with the mode off it keeps its own limit exactly.
"""
from __future__ import annotations

import random
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_nightly_never_blacksmith import JOBS, evaluate, parse_expression, sample  # noqa: E402

GATE_MINUTES = 120
ON = {"vars.CI_NIGHTLY_MINI": "glaeda-nightly-mini", "vars.CI_NIGHTLY_MINI_BUILDER": "glaeda-nightly-mini-builder"}
OFF = {"vars.CI_NIGHTLY_MINI": "", "vars.CI_NIGHTLY_MINI_BUILDER": ""}


def on_the_mini(job: dict) -> bool:
    text = str(job.get("runs-on", "")) + str((job.get("strategy") or {}).get("matrix", {}).get("pool", ""))
    return "vars.CI_NIGHTLY_MINI" in text


def timeout(value: object, context: dict, rng: random.Random, base: dict | None = None) -> object:
    if not isinstance(value, str) or not value.startswith("${{"):
        return value
    expression = value.removeprefix("${{").removesuffix("}}")
    result = evaluate(parse_expression(expression), {**(base if base is not None else sample(expression, rng)), **context})
    # GitHub reads a number literal of the expression as a number; the test evaluator keeps its text.
    return int(result) if isinstance(result, str) and result.isdigit() else result


# A limit that is an expression of its own, at least SIGNING_DRAIN_MINUTES above glaeda's bounded signing drain
# (SIGNING_DRAIN_WAIT_S = 3600): build-sign-notarize-nightly's shortest limit is 160 minutes.
OWN_LIMIT = {"build-sign-notarize-nightly"}
SIGNING_DRAIN_MINUTES = 60


class MiniGateTimeouts(unittest.TestCase):
    def test_a_mini_job_has_room_for_the_capacity_wait(self) -> None:
        rng = random.Random(41955554573)
        short = {}
        for name, job in JOBS.items():
            if job.get("uses") or not on_the_mini(job) or "timeout-minutes" not in job:
                continue
            raw = job["timeout-minutes"]
            for _ in range(50):
                base = sample(raw.removeprefix("${{").removesuffix("}}"), rng) if isinstance(raw, str) else {}
                off, on = timeout(raw, OFF, rng, base), timeout(raw, ON, rng, base)
                if name in OWN_LIMIT:
                    if min(off, on) < 100 + SIGNING_DRAIN_MINUTES:
                        short[name] = (off, on)
                    continue
                if not isinstance(off, (int, float)) or off >= 6 * 60:
                    break  # an expression limit of its own (the signing job) or GitHub's default already
                if on != off + GATE_MINUTES:
                    short[name] = (off, on)
                    break
        self.assertEqual(short, {}, "mini jobs whose timeout has no room for glaeda's capacity wait")

    def test_the_mode_off_keeps_every_limit(self) -> None:
        rng = random.Random(7)
        job = JOBS["build-nightly-remote-daemon"]
        self.assertEqual(timeout(job["timeout-minutes"], OFF, rng), 20)
        self.assertEqual(timeout(job["timeout-minutes"], ON, rng), 20 + GATE_MINUTES)


if __name__ == "__main__":
    unittest.main()
