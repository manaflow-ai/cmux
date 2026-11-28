#!/usr/bin/env python3
"""Time base_red_excuse._aligned_starts (step_owners' second reading) on logs of same-second step headers.

The worst case #41220's review F1 found: every STEP_START line the same text, every step in the same second, so each
header fits each step and the reading must come back ambiguous. The quadratic first version (FROZEN, kept here
verbatim from 478a15d7 as frozen_aligned_starts, also the reference tests/test_base_red_excuse.py's
AlignedStartsIsLinear compares the current one with) took 17.6 s at 10,000 headers over 3 steps.

    python3 scripts/ci/bench_aligned_starts.py            # the current reading at 1k, 10k, 20k x 3, 10 steps
    python3 scripts/ci/bench_aligned_starts.py --frozen   # and the frozen one (minutes at 10k and 20k)

Not a CI test: run it by hand when the reading changes, and quote its table."""
from __future__ import annotations

import argparse
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import base_red_excuse as excuse  # noqa: E402


def frozen_aligned_starts(steps: list[dict], lines: list[str], texts: list[str], windows: list, step_names
                    ) -> list[int] | None:
    """step_owners' second reading, for a log whose excuse.STEP_START lines are not one per step (a composite action's
    inner `Run` lines; cmux#41001's "cmux-next daemon tests", job 130369194352: 38 for 31 steps) or whose steps share
    a second (hq#9191's "Skill policy tests", job 130394322965: five steps in 07:47:29), when its workflow is proven
    (workflow_step_names' answer carries HEADERS, the header the runner opens each step with: `Run <its uses>`, `Run
    <its script's first line>`, `Post job cleanup.` for a post step). Each step's own header is the first excuse.STEP_START
    line of its section, where the runner always prints it; a step's other excuse.STEP_START lines (a composite's inner
    steps, a script's own `::group::Run`) are its section's too. The log is placed only when exactly one choice of
    own headers, in step order, has every one fitting its step's known header and every stamped line of each section,
    the header's and every line after it up to the next step's, within that step's times [started_at, completed_at +
    1s) (the last section: through "Complete job"'s), and the first excuse.STEP_START line the first step's own. Any other
    choice that fits as well (a same-second step's header that could be a composite's inner line), a header the
    workflow does not give, or a step with no times places nothing (None): the whole-log comparison then reads it."""
    headers = getattr(step_names, "headers", None)
    if not isinstance(headers, dict):
        return None
    printing = steps[1:-1]
    starts = [n for n, text in enumerate(texts) if excuse.STEP_START.match(text)]
    if not printing or not starts or len(starts) < len(printing) or len(starts) > excuse.ALIGN_MAX_STARTS:
        return None
    expected = []
    for step in printing:
        want = headers.get(step.get("number"))
        if not (isinstance(want, tuple) and len(want) == 3 and isinstance(want[0], str) and want[0]):
            return None
        expected.append(want)
    # Each segment: a excuse.STEP_START line and the lines after it up to the next one, as the earliest and latest stamp.
    bounds = [*starts, len(lines)]
    low: list[datetime | None] = []
    high: list[datetime | None] = []
    for s in range(len(starts)):
        found = [at for n in range(bounds[s], bounds[s + 1]) if (at := excuse._line_time(lines[n])) is not None]
        low.append(min(found) if found else None)
        high.append(max(found) if found else None)
    if low[0] is None:
        return None
    spans = [windows[k] for k in range(1, len(steps) - 1)]
    spans[-1] = (spans[-1][0], max(spans[-1][1], windows[-1][1]))  # "Complete job" prints into the last section

    def fits(i: int, s: int) -> bool:
        header = texts[starts[s]].removeprefix("##[group]")
        text, exact, _ = expected[i]
        return header == text if exact else header.startswith(text)

    def within(i: int, s: int) -> bool:
        return low[s] is None or (spans[i][0] <= low[s] and high[s] < spans[i][1])

    # ways[s]: how many choices (0, 1, or 2 for "more than one") place steps 0..i with step i's own header at segment
    # s; back[i][s] the segment of step i-1's in the one choice.
    ways = {0: 1} if fits(0, 0) else {}
    back: list[dict[int, int]] = [{}]
    for i in range(len(printing) - 1):
        nxt: dict[int, int] = {}
        came: dict[int, int] = {}
        for s, count in ways.items():
            t = s + 1
            while t < len(starts) and within(i, t - 1):
                if fits(i + 1, t):
                    nxt[t] = min(2, nxt.get(t, 0) + count)
                    came[t] = s
                t += 1
        ways, back = nxt, [*back, came]
        if not ways:
            return None
    last = len(printing) - 1
    ends = {s: count for s, count in ways.items() if all(within(last, u) for u in range(s, len(starts)))}
    if sum(ends.values()) != 1:
        return None
    s = next(iter(ends))
    own = [s]
    for i in range(last, 0, -1):
        s = back[i][s]
        own.append(s)
    chosen = [starts[s] for s in reversed(own)]
    # The one choice must also agree with what the jobs API says of each workflow step that cannot fail quietly (no
    # `continue-on-error`): failed, its section has a live `##[error]` line (the runner's exit line, an action's
    # failure); passed, it has none. A step that printed no header of its own (a "silent" step, which the runner
    # never makes of a step it ran) would take a composite's same-second inner line for its own and with it the
    # composite's failure: the composite's section then has no `##[error]` line, and nothing is placed
    # (LocalCompositeCannotPose).
    edges = [*chosen, len(lines)]
    for i, step in enumerate(printing):
        if not expected[i][2] or step.get("conclusion") not in ("success", "failure"):
            continue
        if (step.get("conclusion") == "failure") != excuse._live_red(texts, edges[i], edges[i + 1], opened=True):
            return None
    return chosen


def same_second_case(headers: int, steps: int) -> tuple[dict, str, object]:
    """(job, log, step_names): STEPS workflow steps between "Set up job" and "Complete job", all in 12:00:10, and
    HEADERS `##[group]Run x` lines in that second, the header every step's workflow gives."""
    at = "2026-11-10T12:00:10Z"
    job = {"steps": [{"number": 1, "name": "Set up job", "status": "completed", "conclusion": "success",
                      "started_at": "2026-11-10T12:00:00Z", "completed_at": "2026-11-10T12:00:02Z"}]}
    job["steps"] += [{"number": n, "name": f"Step {n}", "status": "completed", "conclusion": "success",
                      "started_at": at, "completed_at": at} for n in range(2, steps + 2)]
    job["steps"].append({"number": steps + 2, "name": "Complete job", "status": "completed",
                         "conclusion": "success", "started_at": at, "completed_at": at})
    names = excuse.StepNames({n: True for n in range(2, steps + 2)})
    names.headers = {n: ("Run x", True, False) for n in range(2, steps + 2)}
    lines = ["2026-11-10T12:00:01.0000000Z Current runner version: '2.338.2'"]
    lines += [f"2026-11-10T12:00:10.{n % 10_000_000:07d}Z ##[group]Run x" for n in range(headers)]
    return job, "\n".join(lines), names


def reading_inputs(job: dict, log: str):
    """_aligned_starts' arguments as step_owners makes them."""
    steps = [step for step in job["steps"] if step.get("conclusion") != "skipped"]
    steps.sort(key=lambda step: step["number"])
    lines = log.splitlines()
    windows = [(excuse._stamp_time(step["started_at"]),
                excuse._stamp_time(step["completed_at"]) + excuse.timedelta(seconds=1)) for step in steps]
    return steps, lines, excuse.lines_of(log), windows


def timed(reading, job: dict, log: str, names) -> tuple[float, object]:
    args = reading_inputs(job, log)
    began = time.perf_counter()
    found = reading(*args, names)
    return time.perf_counter() - began, found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--frozen", action="store_true", help="time the frozen quadratic reading too")
    parser.add_argument("--sizes", default="1000,10000,20000")
    parser.add_argument("--steps", default="3,10")
    args = parser.parse_args()
    print("| headers | steps | current (s) | frozen (s) | same answer |")
    print("|---:|---:|---:|---:|---|")
    for headers in (int(n) for n in args.sizes.split(",")):
        for steps in (int(n) for n in args.steps.split(",")):
            case = same_second_case(headers, steps)
            now, found = timed(excuse._aligned_starts, *case)
            if args.frozen:
                then, was = timed(frozen_aligned_starts, *case)
                print(f"| {headers} | {steps} | {now:.3f} | {then:.3f} | {found == was} |", flush=True)
            else:
                print(f"| {headers} | {steps} | {now:.3f} | - | - |", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
