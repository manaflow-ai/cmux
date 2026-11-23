"""launch-bare: the three launch-ready.sh steps (bare back to back, bare after a 60 s run, kept) become labeled rows,
and restore_over_bare_* is the kept median less the bare one; a restore that grows past its floor is a regression."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib import compare as cmp  # noqa: E402
from benchlib.bench import Context, FleetResult  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

NIGHTLY = {"channel": "nightly", "version": "4403028304201", "sha": None,
           "url": "https://files-next.cmux.com/nightly-next/cmux-next-4403028304201.dmg"}


def log(frame: float, usable: float, shell: float | None) -> str:
    """A launch-ready.sh step log: a priming launch and three relaunches, each 10 ms apart."""
    lines = ['LR host cmux14 chip="Apple M4 Pro" macOS 26.7']
    for i, label in enumerate(("prime", "run1", "run2", "run3")):
        step = 1000.0 if label == "prime" else 10.0 * i
        marks = {"main_start": 17 + step, "first_window_frame_committed": frame + step, "window_usable": usable + step}
        if shell is not None:
            marks["first_shell_live"] = shell + step
        run = {"label": label, "finished_launching": 400 + step, "window_on_screen": frame + 20 + step,
               "active": 390 + step, "request_to_start": 15.0, "marks": marks}
        if shell is not None:
            run["shell_requested"] = usable + 2 + step
        lines.append(f"LR-RUN head {json.dumps(run)}")
    return "\n".join(lines) + "\n"


class Steps:
    """Context.fleet_step's stand-in: each launch-ready.sh step answers the log its state and prerun name."""

    def __init__(self, tmp: Path, logs: dict[tuple[str, str], str]) -> None:
        self.tmp, self.logs, self.calls = tmp, logs, []

    def __call__(self, script, args, artifact=None, **kw):
        self.calls.append((script, list(args), kw))
        opts = dict(a.split("=", 1) for a in args)
        path = self.tmp / f"step{len(self.calls)}.log"
        path.write_text(self.logs[(opts.get("state", "kept"), opts.get("prerun", "0"))])
        return FleetResult(job_id="0" * 24, exit_code=0, log_path=path, artifact_path=None)


def run(logs: dict[tuple[str, str], str], **args: str) -> tuple[Context, Steps]:
    bench = load_all()["launch-bare"]
    ctx = Context(bench=bench, build=dict(NIGHTLY), host_role="fleet", args=dict(args))
    tmp = Path(tempfile.mkdtemp())
    steps = Steps(tmp, logs)
    ctx.fleet_step = steps
    bench.run(ctx)
    return ctx, steps


def rows(ctx: Context) -> dict[tuple[str, str], dict]:
    return {(r["metric"], ",".join(f"{k}={v}" for k, v in sorted(r["labels"].items()))): r for r in ctx.rows}


LOGS = {("bare", "0"): log(480, 600, 900), ("bare", "60"): log(650, 780, 1100), ("kept", "0"): log(520, 660, None)}


class LaunchBareRun(unittest.TestCase):
    def test_steps_and_rows(self) -> None:
        ctx, steps = run(LOGS)
        self.assertEqual([c[0] for c in steps.calls], ["scripts/measure/launch-ready.sh"] * 3)
        args = [c[1] for c in steps.calls]
        self.assertIn("state=bare", args[0])
        self.assertIn("prerun=60", args[1])
        self.assertIn("state=kept", args[2])
        self.assertTrue(all(a[0] == f"dmg={NIGHTLY['url']}" for a in args), args)
        # A prerun adds its seconds per launch (runs + the priming one) to the step's bound.
        self.assertEqual(steps.calls[1][2]["timeout"], steps.calls[0][2]["timeout"] + 60 * 6)
        got = rows(ctx)
        # Medians of 3 relaunches 10 ms apart: the middle one, +20 ms.
        self.assertEqual(got[("window_usable", "arm=head,prerun=0,state=bare")]["value"], 620)
        self.assertEqual(got[("window_usable", "arm=head,prerun=60,state=bare")]["value"], 800)
        self.assertEqual(got[("first_shell_live", "arm=head,prerun=0,state=bare")]["value"], 920)
        self.assertEqual(got[("shell_requested", "arm=head,prerun=0,state=bare")]["value"], 622)
        self.assertNotIn(("shell_requested", "arm=head,prerun=0,state=kept"), got, "a kept launch opens no terminal")
        self.assertEqual(got[("failed_launches", "arm=head,prerun=0,state=bare")]["value"], 0)
        self.assertEqual(got[("restore_over_bare_window_usable", "arm=head,panes=1")]["value"], 60)
        self.assertEqual(got[("restore_over_bare_first_window_frame_committed", "arm=head,panes=1")]["value"], 40)
        self.assertEqual(ctx.host["name"], "cmux14")

    def test_regressions_against_the_last_nightly(self) -> None:
        before, _ = run(LOGS)
        slower = dict(LOGS)
        slower[("bare", "0")] = log(480, 700, 1000)  # takes keys 100 ms (16 %) later
        after, _ = run(slower)
        bench = load_all()["launch-bare"]

        def regressed(a: Context, b: Context) -> set[tuple[str, str]]:
            result = cmp.compare({"run_id": "a", "bench": bench.name, "build": NIGHTLY, "host": a.host,
                                  "harness": {"version": "1"}, "timestamp": "", "rows": a.rows},
                                 {"run_id": "b", "bench": bench.name, "build": NIGHTLY, "host": b.host,
                                  "harness": {"version": "1"}, "timestamp": "", "rows": b.rows},
                                 bench.thresholds, floors=bench.floors)
            return {(r["metric"], r["labels"]) for r in result["regressions"]}

        self.assertIn(("window_usable", "arm=head,prerun=0,state=bare"), regressed(before, after))
        # The same kept launch over a slower bare one: restoring costs less above bare, not a regression.
        self.assertNotIn(("restore_over_bare_window_usable", "arm=head,panes=1"), regressed(before, after))
        # A restore that grows by 40 ms or less (here 30) is under the floor; by 100 it is a regression.
        for extra, expected in ((30, False), (100, True)):
            grown = dict(LOGS)
            grown[("kept", "0")] = log(520, 660 + extra, None)
            later, _ = run(grown)
            self.assertEqual(("restore_over_bare_window_usable", "arm=head,panes=1") in regressed(before, later),
                             expected, extra)

    def test_import_labels_one_step(self) -> None:
        bench = load_all()["launch-bare"]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "step.log"
            path.write_text(LOGS[("bare", "60")])
            ctx = Context(bench=bench, build=dict(NIGHTLY), host_role="fleet", args={"prerun": "60"})
            bench.ingest(ctx, path)
        self.assertEqual(rows(ctx)[("window_usable", "arm=head,prerun=60,state=bare")]["value"], 800)

    def test_unusable_launches(self) -> None:
        # A bare launch whose window never took keys has no window_usable: counted per bare step, never for kept.
        logs = dict(LOGS)
        logs[("bare", "0")] = log(480, 600, 900).replace('"window_usable": 610.0, ', "", 1)
        ctx, _ = run(logs)
        got = rows(ctx)
        self.assertEqual(got[("unusable_launches", "arm=head,prerun=0,state=bare")]["value"], 1)
        self.assertEqual(got[("unusable_launches", "arm=head,prerun=60,state=bare")]["value"], 0)
        self.assertNotIn(("unusable_launches", "arm=head,prerun=0,state=kept"), got)

    def test_real_bare_report(self) -> None:
        # runs.jsonl of a fleet run (b44d23c2, prerun=60, 10 relaunches): 6 of the 10 never took keys.
        bench = load_all()["launch-bare"]
        ctx = Context(bench=bench, build=dict(NIGHTLY), host_role="fleet", args={"prerun": "60"})
        bench.ingest(ctx, Path(__file__).resolve().parent / "fixtures" / "launch" / "launch-ready-bare-prerun60.jsonl")
        got = rows(ctx)
        self.assertEqual(got[("unusable_launches", "arm=head,prerun=60,state=bare")]["value"], 6)
        self.assertEqual(got[("window_usable", "arm=head,prerun=60,state=bare")]["n"], 4)
        self.assertEqual(got[("failed_launches", "arm=head,prerun=60,state=bare")]["value"], 0)

    def test_registered_nightly(self) -> None:
        bench = load_all()["launch-bare"]
        self.assertTrue(bench.nightly)
        self.assertEqual(bench.harness, "scripts/measure/launch-ready.sh")


if __name__ == "__main__":
    unittest.main()
