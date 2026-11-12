"""A red job's log without its passing steps' lines (failed_steps_log), and the one owner of a log line's step
(step_owners): what base_red_excuse.py compares and quotes, and what cmuxterm-hq's and leo-workspace's base-red-watch
quote and name files from, so none of them reads a passing step's expected stderr as the red
(cmuxterm-hq docs/handbook/red-quoted-from-a-passing-step.md).

This file is the source; base_red_excuse.py uses it, never a copy. Standard library only, so another repository vendors
it whole: cmuxterm-hq tools/fleet-reconcilers/failed_steps_log.py and leo-workspace tools/failed_steps_log.py are byte
copies, each beside a failed_steps_log.pin naming the cmux commit it was copied at and its sha256. Each repository's
test fails when its copy's sha256 is not its pin's, and cmux's tests/test_base_red_excuse.py (VendoredCopies) fails when
a copy it can read differs from this file at its pinned commit. A change lands here, then is copied with a new pin.
"""
from __future__ import annotations

import bisect
import re
from datetime import datetime, timedelta

# Every line boundary of a log: exactly what str.splitlines() splits on (\r\n is \r then \n), the split every reader
# of lines uses (test_reds.py's log_lines, lines_of and unjudged; failed_steps_log.py's lines_of and step_owners). No
# escape spans one. test_reds.py and failed_steps_log.py each hold this block, byte for byte: readers elsewhere load
# test_reds.py alone, and failed_steps_log.py is vendored whole. tests/test_base_red_excuse.py's SingleSourceLogReader
# fails when the two differ.
LINE_BOUNDARIES = "\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029"
# A terminal escape: a CSI sequence (colour, cursor) or an OSC one (a hyperlink, a title), as base_red_excuse reads them.
# An OSC ends at its FIRST terminator (BEL or ST, `ESC \\`), another escape or a line boundary, whichever comes first:
# a body that ran to the log's last ST deleted every line between two titles, a new failure with them, and the judge
# excused it (cmux#41382's review F1); one that ran across a bare CR deleted the failure line splitlines() puts after
# it (#41390's review F1). One opened on a line and closed on a later one is cut at each line's end, its stray BEL or
# ST removed on its own, so no escape spans a line: its title text stays, never a failure line goes. A CSI's bytes
# (0x20-0x7E) hold no boundary.
ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b" + LINE_BOUNDARIES + r"]*(?:\x07|\x1b\\)?|\\)|\x07")
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")


def lines_of(log: str) -> list[str]:
    """The text of each `job<TAB>step<TAB>stamp text` line of `gh run view --log`."""
    found = []
    for line in log.replace("\ufeff", "").splitlines():  # a log section can open with a BOM; strip() keeps it
        parts = line.split("\t", 2)
        # `gh run view --log` prefixes each line with job and step columns.
        # The job-log API does not; preserve tabs in raw command output.
        text = parts[2] if len(parts) == 3 and STAMP.match(parts[2]) else line
        found.append(ANSI.sub("", STAMP.sub("", text)).strip())
    return found


# The line the runner opens each step's section of a job log with, after "Set up job" (the log's first lines): `Run
# <script's first line>` for a run: step, `Run owner/action@ref` for a uses: step (and a job hook's `Run '/setup.sh'`),
# `Post job cleanup.` for a post step. "Complete job" opens with no such line.
STEP_START = re.compile(r"^(?:##\[group\]Run |Post job cleanup\.$)")
# The line a self-hosted runner prints, outside any step's group, right before a job hook's own header (`Run
# '/setup.sh'`, `Run '/job_completed.sh'`): the CI runners' "Set up runner" and "Complete runner" steps.
# GitHub's own log view puts it in the hook's step, but it sits before that step's header, so _aligned_starts read it
# as the end of the step before. On feat-cmux-next run 43196103785 (job 131107474882, "cmux-next checks"), the
# checkout's post step ended at 10:04:41 and the notice was stamped 10:04:42.0000405, so no choice of headers fit, the
# base log went unplaced and every PR's red of that job was refused with "does not map one to one onto its steps".
# The runner's own fixed text, never a test, an error or a header: _aligned_starts does not time a section by it.
# Only these exact lines; any other line out of its step's times still places nothing.
RUNNER_HOOK_NOTICE = re.compile(r"^A job (?:started|completed) hook has been configured by the self-hosted runner "
                                r"administrator$")


def _stamp_time(value) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        return None
    return parsed if parsed.tzinfo else None


FAILED, ERRORED, PASSED, AMBIGUOUS = "failed", "errored", "passed", "ambiguous"
# A live runner annotation: `##[error]` at the start of a line, outside the group in which the runner echoes the
# step's script (the group its `##[group]Run ...` header opens, proven by step_owners; every other line is live). A
# continue-on-error step that failed is a success to the jobs API, but its section still has its `##[error]` lines and
# the runner's exit line, so it is ERRORED: shown, never base evidence. Text that only reads like one (`expected:
# Process completed with exit code 1.` from a passing negative case) is not (#40542's fourth Codex BLOCK, F1).
SECTION_RED = re.compile(r"^##\[error\]")
# Past this many lines a log is not placed: every line is AMBIGUOUS (kept for a comment, never evidence for an excuse).
STEP_OWNERS_MAX_LINES = 2_000_000


class StepNamesUnknown:
    """STEP_NAMES_UNKNOWN: what a caller of step_owners passes as STEP_NAMES when it cannot read which of the job's
    steps its workflow names (workflow_step_names could not prove it). A choice made at the call site: step_owners and
    every reader of it take STEP_NAMES as a required keyword, so no caller forgets the workflow (#40542's Codex F1 at
    221c7e4d: next_batch's expand_job never read it, and a named "Run package tests (...)" step's red, the same on
    the base, was keyed as new)."""
    __slots__ = ()

    def __repr__(self) -> str:
        return "STEP_NAMES_UNKNOWN"


STEP_NAMES_UNKNOWN = StepNamesUnknown()


def step_owners(job: dict, log: str, *, step_names) -> list[tuple[str, int | None, str]]:
    """Each line of LOG as (line, the index of the step of JOB that printed it or None, its status) when the log maps
    one to one onto the steps that ran (the jobs API's steps[], by number, without skipped ones), AMBIGUOUS for every
    line when it does not. The one owner of a line's step: failed_steps_log, signature, step_lines and every caller of
    theirs read lines through it. A comment shows every line but PASSED ones; an excuse refuses a log with any
    AMBIGUOUS line (judge, package_tests, quarantined_only) and takes a base's FAILED lines alone as evidence.

    The runner opens every step's section with one STEP_START line ("Set up job", whose lines come first, and
    "Complete job", which shares the last section, print none). A one-to-one mapping is never inferred from counts or
    times alone: six reviews of cmux#40542, hq#8936 and LW#4177 found logs where they balance out (a composite action's
    inner `Run` line or a step's own `::group::Run` line standing in for a silent step's missing one, and a
    continue-on-error composite's diagnostic then dropped as a passing step's). The log is placed only when there is
    exactly one STEP_START line per step and each one is that step's own header, by both of:
    - its stamp falls within that step's [started_at, completed_at + 1s) and no other step's that can print one (the
      metadata keeps whole seconds; "Set up job" and "Complete job" are the runner's and print none), so only that
      step can have printed it;
    - its text fits the step's name: an unnamed `run:` or `uses:` step's name is its header (`Run
      actions/checkout@v6` opens with `##[group]Run actions/checkout@v6`), a post step (`Post ...`) opens with
      `Post job cleanup.` and no other step does, and a named step's header (`Run <its script's first line>`) cannot
      be read off its name. A name alone never proves a header is a step's: the workflow's author picks it, so a
      silent step named like a composite's inner `Run` line would take that line (#40542's third Codex BLOCK).
      Whether a step is unnamed is the workflow's to say, never its name's: STEP_NAMES (workflow_step_names, from the
      workflow at the job's head) says True for a step with a `name:` (only its stamp places it, so "Run package
      tests (...)" may open with `Run set -euo pipefail`, #40542's sixth Codex BLOCK) and False for one with none
      (its header must be its name). A step it does not name is unproven: a name that starts with "Run " is then
      taken for an unnamed step's, whose header must be it.
    STEP_NAMES is workflow_step_names' answer, {step number: whether its workflow step has a `name:`}, or
    STEP_NAMES_UNKNOWN; anything else is a TypeError.
    Any composite action, silent step, extra header, mismatch or step with no times places nothing by that reading
    (_one_to_one_starts). When STEP_NAMES carries the workflow's headers (StepNames), a log it does not place is read
    a second way (_aligned_starts): every workflow step prints its own known header first, so a composite's inner
    `Run` lines and steps sharing a second are placed when exactly one choice of own headers fits the headers and every
    line's time; any other choice that fits places nothing. A placed section
    is FAILED when the jobs API says its step did not succeed, ERRORED when its step succeeded but it has a live
    SECTION_RED line outside its script's echo, else PASSED. The last section is "Complete job"'s too: when that failed
    and the step before it succeeded, which of the two its lines belong to is not proven, so they are AMBIGUOUS
    (#40542's fourth Codex BLOCK, F2)."""
    if step_names is not STEP_NAMES_UNKNOWN and not isinstance(step_names, dict):
        raise TypeError(f"step_names must be workflow_step_names' answer or STEP_NAMES_UNKNOWN, not {step_names!r}")
    lines = log.splitlines()
    unknown = [(line, None, AMBIGUOUS) for line in lines]
    steps = [step for step in job.get("steps") or [] if step.get("conclusion") != "skipped"]
    if all(isinstance(step.get("number"), int) for step in steps):
        steps.sort(key=lambda step: step["number"])
    if len(steps) < 2 or len(lines) > STEP_OWNERS_MAX_LINES:
        return unknown
    texts = lines_of(log)
    windows = []
    for step in steps:
        start, end = _stamp_time(step.get("started_at")), _stamp_time(step.get("completed_at"))
        windows.append((start, end + timedelta(seconds=1)) if start is not None and end is not None and end >= start
                       else None)
    if None in windows:
        return unknown
    starts = _one_to_one_starts(steps, lines, texts, windows, step_names)
    if starts is None:
        starts = _aligned_starts(steps, lines, texts, windows, step_names)
    if starts is None:
        return unknown
    bounds = [0, *starts, len(lines)]
    found = []
    for k in range(len(bounds) - 1):
        section = range(bounds[k], bounds[k + 1])
        if steps[k].get("conclusion") != "success":
            status = FAILED
        elif k == len(bounds) - 2 and steps[-1].get("conclusion") != "success":
            status = AMBIGUOUS
        else:
            status = ERRORED if _live_red(texts, bounds[k], bounds[k + 1], opened=k > 0) else PASSED
        found += [(lines[n], k, status) for n in section]
    return found


def _live_red(texts: list[str], low: int, high: int, *, opened: bool) -> bool:
    """Whether the section TEXTS[LOW:HIGH] (OPENED: by its step's own header) has a live SECTION_RED line. Every line
    is live but the runner's echo of the step's script and env: the group its own `##[group]Run ...` header opens, up
    to its `##[endgroup]` with no other group opened before it. A post step's `Post job cleanup.`, a group that is not
    the header's, or a header group with no end skips nothing (#40542's fifth Codex BLOCK: a post step's own
    `##[group]` hid its `##[error]` line)."""
    live = low
    if opened and texts[low].startswith("##[group]Run "):
        for n in range(low + 1, high):
            if texts[n].startswith("##[group]"):
                break
            if texts[n] == "##[endgroup]":
                live = n + 1
                break
    return any(SECTION_RED.match(texts[n]) for n in range(live, high))


def _line_time(line: str) -> datetime | None:
    """The runner's stamp on a raw log LINE (either log format), None when it has none."""
    parts = line.replace("\ufeff", "").split("\t", 2)
    stamp = STAMP.match(parts[2] if len(parts) == 3 and STAMP.match(parts[2]) else parts[0])
    return _stamp_time(stamp.group()) if stamp else None


def _one_to_one_starts(steps: list[dict], lines: list[str], texts: list[str], windows: list, step_names
                       ) -> list[int] | None:
    """step_owners' first reading (its docstring): the STEP_START line of each of STEPS[1:-1] when there is exactly
    one per step, each in its own step's times alone and fitting its name; else None."""
    proven = {} if step_names is STEP_NAMES_UNKNOWN else step_names
    starts = [n for n, text in enumerate(texts) if STEP_START.match(text)]
    if len(starts) != len(steps) - 2:
        return None
    opened, closed = sorted(start for start, _ in windows[1:-1]), sorted(end for _, end in windows[1:-1])
    for k, n in enumerate(starts, 1):
        name = str(steps[k].get("name") or "")  # step-name: validate
        header = texts[n].removeprefix("##[group]")
        # Whether the workflow gives this step a `name:`, as workflow_step_names proved it (absent: not proven).
        named = proven.get(steps[k].get("number"))
        if header == "Post job cleanup." or name.startswith("Post "):
            if not (header == "Post job cleanup." and name.startswith("Post ")):
                return None
        elif (named is False or (named is not True and name.startswith("Run "))) and header != name:
            return None
        at = _line_time(lines[n])
        if at is None or not windows[k][0] <= at < windows[k][1]:
            return None
        # The windows holding AT: those opened at or before it less those closed at or before it.
        if bisect.bisect_right(opened, at) - bisect.bisect_right(closed, at) != 1:
            return None
    return starts


# Past this many STEP_START lines a log is not aligned (_aligned_starts): each is tried against each step's times.
ALIGN_MAX_STARTS = 20_000


def _aligned_starts(steps: list[dict], lines: list[str], texts: list[str], windows: list, step_names
                    ) -> list[int] | None:
    """step_owners' second reading, for a log whose STEP_START lines are not one per step (a composite action's
    inner `Run` lines; cmux#41001's "cmux-next daemon tests", job 130369194352: 38 for 31 steps) or whose steps share
    a second (hq#9191's "Skill policy tests", job 130394322965: five steps in 07:47:29), when its workflow is proven
    (workflow_step_names' answer carries HEADERS, the header the runner opens each step with: `Run <its uses>`, `Run
    <its script's first line>`, `Post job cleanup.` for a post step). Each step's own header is the first STEP_START
    line of its section, where the runner always prints it; a step's other STEP_START lines (a composite's inner
    steps, a script's own `::group::Run`) are its section's too. The log is placed only when exactly one choice of
    own headers, in step order, has every one fitting its step's known header and every stamped line of each section,
    the header's and every line after it up to the next step's, within that step's times [started_at, completed_at +
    1s) (the last section: through "Complete job"'s), and the first STEP_START line the first step's own. Any other
    choice that fits as well (a same-second step's header that could be a composite's inner line), a header the
    workflow does not give, or a step with no times places nothing (None): the whole-log comparison then reads it."""
    headers = getattr(step_names, "headers", None)
    if not isinstance(headers, dict):
        return None
    printing = steps[1:-1]
    starts = [n for n, text in enumerate(texts) if STEP_START.match(text)]
    if not printing or not starts or len(starts) < len(printing) or len(starts) > ALIGN_MAX_STARTS:
        return None
    expected = []
    for step in printing:
        want = headers.get(step.get("number"))
        if not (isinstance(want, tuple) and len(want) == 3 and isinstance(want[0], str) and want[0]):
            return None
        expected.append(want)
    # Each segment: a STEP_START line and the lines after it up to the next one, as the earliest and latest stamp.
    bounds = [*starts, len(lines)]
    low: list[datetime | None] = []
    high: list[datetime | None] = []
    for s in range(len(starts)):
        found = [at for n in range(bounds[s], bounds[s + 1])
                 if (at := _line_time(lines[n])) is not None and not RUNNER_HOOK_NOTICE.match(texts[n])]
        low.append(min(found) if found else None)
        high.append(max(found) if found else None)
    if low[0] is None:
        return None
    spans = [windows[k] for k in range(1, len(steps) - 1)]
    spans[-1] = (spans[-1][0], max(spans[-1][1], windows[-1][1]))  # "Complete job" prints into the last section

    count = len(starts)
    heads = [texts[n].removeprefix("##[group]") for n in starts]

    def fitting(i: int) -> list[bool]:
        text, exact, _ = expected[i]
        return [head == text for head in heads] if exact else [head.startswith(text) for head in heads]

    def reach(i: int) -> list[int]:
        """For each segment s, the first segment u >= s outside step I's times (COUNT when none): step I's own
        header at s lets the next step's be at any t with s < t <= reach[s]."""
        start, end = spans[i]
        found = [count] * (count + 1)
        for u in range(count - 1, -1, -1):
            inside = low[u] is None or (start <= low[u] and high[u] < end)
            found[u] = found[u + 1] if inside else u
        return found

    # ways[s]: how many choices (0, 1, or 2 for "more than one") place steps 0..i with step i's own header at segment
    # s; back[i][s] the segment of step i-1's in the one choice. Each step is one pass over the headers (a difference
    # array over the next step's segments, of counts and of segment-weighted counts, so a count of 1 names its one
    # predecessor): O(steps x headers), never a rescan per candidate (#41220's review F1: 10,000 same-second headers
    # over 3 steps took 17.6 s).
    first = fitting(0)
    ways = {0: 1} if first[0] else {}
    back: list[dict[int, int]] = [{}]
    for i in range(len(printing) - 1):
        far = reach(i)
        added = [0] * (count + 1)
        weighed = [0] * (count + 1)
        for s, n in ways.items():
            top = min(far[s], count - 1)
            if top >= s + 1:
                added[s + 1] += n
                added[top + 1] -= n
                weighed[s + 1] += n * s
                weighed[top + 1] -= n * s
        fit = fitting(i + 1)
        nxt: dict[int, int] = {}
        came: dict[int, int] = {}
        total = weight = 0
        for t in range(count):
            total += added[t]
            weight += weighed[t]
            if total and fit[t]:
                nxt[t] = min(2, total)
                if total == 1:
                    came[t] = weight
        ways, back = nxt, [*back, came]
        if not ways:
            return None
    last = len(printing) - 1
    far = reach(last)
    ends = {s: n for s, n in ways.items() if far[s] == count}
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
        if (step.get("conclusion") == "failure") != _live_red(texts, edges[i], edges[i + 1], opened=True):
            return None
    return chosen


def failed_steps_log(job: dict, log: str, *, step_names) -> str:
    """LOG without the lines of JOB's passing steps: its FAILED, ERRORED and AMBIGUOUS lines (step_owners). A job
    runs many steps, and a passing one may print error-looking stderr on purpose: test_ghostty_licenses.py's negative
    cases print "pinned license manifest digest changed" and pass. 2026-11-10: cmux#40369's static checks failed only
    in "Every page's strings generate with no missing translation" (feat-cmux-next runs 42820823641, 42820590433),
    and the excuse quoted that digest line, sending an agent after the wrong cause. A line whose step cannot be told
    is kept: what is shown of a red never hides its evidence."""
    return "\n".join(line for line, _, status in step_owners(job, log, step_names=step_names) if status != PASSED)
