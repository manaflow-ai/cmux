"""launch-bare: a launch with nothing to restore, and what restoring adds on top of it (launch-shell-first piece 8).

launch-ready.sh with state=bare: every launch starts from an empty home, as a fresh install's does, and the probe
opens a terminal once Home takes keys. Each launch is measured in both cases a launch needs: back to back (prerun=0)
and after a 60 s full run and quit (prerun=60). One more step relaunches into a kept home (state=kept, session=small:
one window on Home, one pane on screen) back to back, and each restore_over_bare_* row is that launch's median less
the bare one's: what restoring a pane costs above a launch with nothing to restore. Rows as the launch bench's, labeled
state=bare|kept and prerun=0|60; the nightly runs the three steps, about 15 minutes on a fleet Mac.

The nightly compares each row with the last NIGHTLY's (cmux-bench nightly): a bare launch that takes keys or shows
its first frame later past its threshold, or a restore that grows past one pane's worth above bare, files the issue.

  --arg runs=N        measured relaunches per step (1 to 10, default 5)
  --import FILE       one launch-ready.sh step's log or report.tgz; --arg state= and --arg prerun= label its rows
"""
from __future__ import annotations

import statistics
from pathlib import Path

from benchlib.bench import Context

from benches.launch import Launch, _metric

# (state, prerun) per step: bare in both launch cases, then the restoring launch the rule compares with bare.
STEPS = (("bare", "0"), ("bare", "60"), ("kept", "0"))
# The marks restore_over_bare_* compares: the first frame, and the window taking keys (Home's message field).
RESTORE_MARKS = ("first_window_frame_committed", "window_usable")


class LaunchBare(Launch):
    name = "launch-bare"
    summary = "Launch with nothing to restore (back to back and after a 60 s run), and restore's cost above it"
    units = "ms, count"
    version = "1"
    # A relaunch's marks move by 5 to 10 % run to run on one Mac. restore_over_bare_* is a difference of two medians
    # of tens of ms, so its floor is a frame's worth of noise on each side rather than a percent.
    thresholds = {"request_to_start": 50.0, "failed_launches": 0.0, "unusable_launches": 0.0,
                  **{f"restore_over_bare_{m}": 25.0 for m in RESTORE_MARKS}}
    floors = {"request_to_start": 10.0, "failed_launches": 0.0, "unusable_launches": 0.0,
              **{f"restore_over_bare_{m}": 40.0 for m in RESTORE_MARKS}}
    nightly = True
    nightly_args = {"runs": "5"}

    def run(self, ctx: Context) -> None:
        finished = {}
        for state, prerun in STEPS:
            res = self.ready_step(ctx, state=state, prerun=prerun)
            finished[(state, prerun)] = self.ingest_step(ctx, res.log_path, state, prerun)
        restore_rows(ctx, finished[("bare", "0")], finished[("kept", "0")])

    def ingest(self, ctx: Context, path: Path) -> None:
        self.ingest_step(ctx, path, ctx.arg("state", "bare"), ctx.arg("prerun", "0"))

    def ingest_step(self, ctx: Context, path: Path, state: str, prerun: str) -> dict[str, list[dict]]:
        """One step's rows; a bare step also counts its finished launches whose window never took keys
        (unusable_launches: no window_usable before the probe quit it)."""
        labels = {"state": state, "prerun": prerun}
        finished = self.ingest_ready(ctx, path, labels)
        if state == "bare":
            for side, runs in finished.items():
                ctx.row("unusable_launches", sum("window_usable" not in (r.get("marks") or {}) for r in runs), "count",
                        labels={"arm": side, **labels})
        return finished


def restore_rows(ctx: Context, bare: dict[str, list[dict]], kept: dict[str, list[dict]]) -> None:
    """restore_over_bare_MARK per side: the kept launches' median MARK less the bare launches', one pane on screen."""
    for side in bare.keys() & kept.keys():
        for mark in RESTORE_MARKS:
            times = [[r["marks"][mark] for r in runs if mark in (r.get("marks") or {})] for runs in (kept[side], bare[side])]
            if not all(times):
                ctx.notes.append(f"restore_over_bare_{_metric(mark)} {side}: no {mark} on one side")
                continue
            ctx.row(f"restore_over_bare_{_metric(mark)}", statistics.median(times[0]) - statistics.median(times[1]),
                    "ms", labels={"arm": side, "panes": "1"})


BENCH = LaunchBare()
