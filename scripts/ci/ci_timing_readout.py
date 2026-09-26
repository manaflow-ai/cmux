#!/usr/bin/env python3
"""Write a CI run's timing readout to the job summary.

It lists this run attempt's jobs (one or two GitHub API calls), finds the
chain of jobs that set the wall time, and places each of them, and their
longest steps, against the last week of the same jobs on the same trigger.
The history comes from the build controller's webhook feed
(CI_TIMING_STATS_URL, no GitHub API budget); without it the readout still
shows this run's own numbers.

The critical path is read from timestamps: a job is queued the moment the
last job it needs finishes, so each job's predecessor is the job that
finished last before it was created.

Never fails the job: any error prints a short note instead.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import urllib.parse
import urllib.request

# Jobs that wait for everything else; the readout is about what they wait on.
EXCLUDED_JOBS = {"ci-status", "CI timing"}
# A job whose start is before its creation was copied from an earlier
# attempt by "re-run failed jobs"; it did not run in this attempt.
REUSED_SLACK_SECONDS = 5
# How far a predecessor's completion may trail the dependent job's creation.
LINK_SLACK_SECONDS = 3
STEP_FLOOR_SECONDS = 20
# Chain links shorter than this (status roll-ups) stay out of the headline.
HEADLINE_FLOOR_SECONDS = 30
STEPS_PER_JOB = 3
QUANTILE_POINTS = (10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 99)


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def fmt_duration(seconds: float | None) -> str:
    if seconds is None:
        return "-"
    seconds = int(round(seconds))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m{seconds % 60:02d}s"
    return f"{seconds // 3600}h{(seconds % 3600) // 60:02d}m"


def segment(event: str, ref_name: str) -> str:
    """The controller's trigger segment for this run."""
    if event in ("pull_request", "pull_request_target"):
        return "pr"
    if event == "merge_group" or ref_name.startswith("gh-readonly-queue/"):
        return "queue"
    if ref_name == "main":
        return "main"
    return "other"


def short_name(name: str) -> str:
    """Drop the calling job's prefix: "macos / X" is X, "guards / tests / ci" is "tests / ci"."""
    return name.split(" / ", 1)[-1]


def cell(text: str) -> str:
    """text safe inside a Markdown table cell."""
    return text.replace("\\", "\\\\").replace("|", "\\|").replace("\n", " ")


def shard_group(name: str) -> str | None:
    head, sep, tail = name.rpartition(" (")
    if sep and tail.endswith(")") and "/" in tail and tail[:-1].replace("/", "").isdigit():
        return f"{head} (*)"
    return None


def where(job: dict) -> str:
    runner = job.get("runner_name") or ""
    labels = " ".join(job.get("labels") or [])
    text = f"{runner} {labels}".lower()
    if "glaeda" in text or "mac-mini" in text or "self-hosted" in text:
        return f"mini {runner.removesuffix('-glaeda')}".strip()
    if "blacksmith" in text:
        label = next((label for label in job.get("labels") or [] if label.startswith("blacksmith")), "")
        return f"Blacksmith {label.removeprefix('blacksmith-')}".strip()
    if runner.lower().startswith("github actions"):
        return "GitHub-hosted"
    return runner or "-"


class Job:
    def __init__(self, raw: dict):
        self.raw = raw
        self.name: str = raw.get("name") or ""
        self.created = parse_time(raw.get("created_at"))
        self.started = parse_time(raw.get("started_at"))
        self.completed = parse_time(raw.get("completed_at"))
        self.conclusion = raw.get("conclusion") or raw.get("status") or ""
        self.ran = bool(raw.get("runner_name")) and self.started is not None and self.conclusion != "skipped"
        self.reused = bool(
            self.ran and self.created and self.started
            and (self.created - self.started).total_seconds() > REUSED_SLACK_SECONDS
        )

    @property
    def fresh(self) -> bool:
        return self.ran and not self.reused and self.completed is not None and self.created is not None

    @property
    def queue(self) -> float | None:
        if not self.fresh:
            return None
        return max(0.0, (self.started - self.created).total_seconds())

    @property
    def run(self) -> float | None:
        if not self.fresh:
            return None
        return max(0.0, (self.completed - self.started).total_seconds())

    def steps(self) -> list[tuple[str, float]]:
        out = []
        for step in self.raw.get("steps") or []:
            start, end = parse_time(step.get("started_at")), parse_time(step.get("completed_at"))
            if start and end and step.get("name"):
                out.append((step["name"], (end - start).total_seconds()))
        return out


def critical_path(jobs: list[Job]) -> list[Job]:
    """The chain of jobs that set the wall time, first to last."""
    fresh = [j for j in jobs if j.fresh and j.name not in EXCLUDED_JOBS]
    if not fresh:
        return []
    current = max(fresh, key=lambda j: j.completed)
    chain = [current]
    while True:
        limit = current.created + dt.timedelta(seconds=LINK_SLACK_SECONDS)
        before = [j for j in fresh if j.completed <= limit and j.completed < current.completed and j not in chain]
        if not before:
            break
        current = max(before, key=lambda j: j.completed)
        chain.append(current)
    return list(reversed(chain))


class History:
    """Percentiles from the controller's /ci-timing.json answer."""

    def __init__(self, stats: dict | None):
        self.series: dict[tuple, dict] = {}
        self.ok = bool(stats)
        for series in (stats or {}).get("series") or []:
            key = (series.get("metric"), series.get("job") or "", series.get("step") or "", series.get("runner") or "")
            self.series[key] = series

    def find(self, metric: str, job: str = "", step: str = "") -> dict | None:
        for name in (job, shard_group(job)):
            if name is None:
                continue
            found = self.series.get((metric, name, step, ""))
            if found:
                return found
        return None


def rank(value: float, quantiles: list[float]) -> str:
    """Where value falls in [n, p10..p90, p95, p99], as pNN."""
    points = list(zip(QUANTILE_POINTS, quantiles[1:]))
    if len(points) != len(QUANTILE_POINTS):
        return ""
    if value < points[0][1]:
        return "<p10"
    if value > points[-1][1]:
        return ">p99"
    for (p_lo, v_lo), (p_hi, v_hi) in zip(points, points[1:]):
        if v_lo <= value <= v_hi:
            if v_hi == v_lo:
                return f"p{p_lo}"
            return f"p{round(p_lo + (p_hi - p_lo) * (value - v_lo) / (v_hi - v_lo))}"
    return ""


def compare(value: float | None, series: dict | None) -> tuple[str, str, bool]:
    """(rank, 'p50 X, p90 Y', above p90) for value against series."""
    if value is None or not series:
        return "", "", False
    q = series.get("q") or []
    if len(q) < 12:
        return "", "", False
    p50, p90 = q[5], q[9]
    return rank(value, q), f"p50 {fmt_duration(p50)}, p90 {fmt_duration(p90)}", value > p90 and value - p90 >= 30


def trend(series: dict | None) -> str:
    """Last 24 h p50 against the 6 days before, with a direction arrow."""
    if not series:
        return ""
    recent, past = series.get("recent") or [0], series.get("past") or [0]
    if recent[0] < 3 or past[0] < 3:
        return ""
    r, p = recent[1], past[1]
    arrow = "→"
    if p > 0 and (r - p) / p > 0.1 and r - p >= 15:
        arrow = "↑"
    elif p > 0 and (p - r) / p > 0.1 and p - r >= 15:
        arrow = "↓"
    return f"{fmt_duration(r)} vs {fmt_duration(p)} {arrow}"


def build_readout(raw_jobs: list[dict], stats: dict | None, seg: str, run_attempt: int = 1, stats_note: str = "") -> str:
    jobs = [Job(raw) for raw in raw_jobs]
    history = History(stats)
    fresh = [j for j in jobs if j.fresh and j.name not in EXCLUDED_JOBS]
    lines = ["### CI timing", ""]
    if not fresh:
        lines.append("No job ran in this attempt.")
        return "\n".join(lines) + "\n"

    start = min(j.created for j in fresh)
    end = max(j.completed for j in fresh)
    wall = (end - start).total_seconds()
    chain = critical_path(jobs)

    def flag(text: str, high: bool) -> str:
        return f"**{text}, above p90**" if high else text

    heads = []
    for job in chain:
        if (job.queue or 0) + (job.run or 0) < HEADLINE_FLOOR_SECONDS:
            continue
        run_rank, _, run_high = compare(job.run, history.find("run", job.name))
        queue_rank, _, queue_high = compare(job.queue, history.find("queue", job.name))
        part = short_name(job.name)
        if job.queue and job.queue >= 60:
            part += f" queued {fmt_duration(job.queue)}{' (above p90)' if queue_high else ''} +"
        part += f" {fmt_duration(job.run)}"
        if run_rank:
            part += f" ({run_rank})"
        heads.append(part)
    wall_rank, _, _ = compare(wall, history.find("wall"))
    headline = f"wall {fmt_duration(wall)}{f' ({wall_rank})' if wall_rank else ''}"
    if run_attempt > 1:
        headline += f", attempt {run_attempt}"
    if chain:
        headline += "; critical path: " + " → ".join(heads)
    lines += [f"**{headline}**", ""]

    lines += [
        "| critical path | where | queue | run | run vs last 7 days | p50 last 24 h vs 6 d before |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for job in chain:
        run_series = history.find("run", job.name)
        run_rank, run_ref, run_high = compare(job.run, run_series)
        queue_rank, queue_ref, queue_high = compare(job.queue, history.find("queue", job.name))
        queue = fmt_duration(job.queue)
        if queue_rank:
            queue = flag(f"{queue} ({queue_rank})", queue_high)
        vs = flag(f"{run_rank} ({run_ref})", run_high) if run_rank else "-"
        lines.append(
            f"| {cell(job.name)} | {cell(where(job.raw))} | {queue} | {fmt_duration(job.run)} | {vs} | {trend(run_series) or '-'} |"
        )

    step_rows = []
    for job in chain:
        steps = sorted((s for s in job.steps() if s[1] >= STEP_FLOOR_SECONDS), key=lambda s: -s[1])[:STEPS_PER_JOB]
        for name, seconds in steps:
            series = history.find("step", job.name, name)
            step_rank, step_ref, high = compare(seconds, series)
            vs = flag(f"{step_rank} ({step_ref})", high) if step_rank else "-"
            step_rows.append(f"| {cell(short_name(job.name))} | {cell(name)} | {fmt_duration(seconds)} | {vs} |")
    if step_rows:
        lines += ["", "| job | longest steps | time | vs last 7 days |", "| --- | --- | --- | --- |", *step_rows]

    elsewhere = []
    for job in sorted(fresh, key=lambda j: j.name):
        if job in chain:
            continue
        for label, value, metric in (("run", job.run, "run"), ("queued", job.queue, "queue")):
            r, ref, high = compare(value, history.find(metric, job.name))
            if high:
                elsewhere.append(f"- {job.name}: {label} {fmt_duration(value)} ({r}; {ref}), {where(job.raw)}")
    if elsewhere:
        lines += ["", "Above p90 off the critical path:", *elsewhere[:8]]

    reused = [j for j in jobs if j.reused and j.name not in EXCLUDED_JOBS]
    notes = []
    if run_attempt > 1 and reused:
        notes.append(f"{len(reused)} job{'s' if len(reused) != 1 else ''} reused from an earlier attempt left out")
    if history.ok:
        notes.append(f"history: `{seg}` runs over the last 7 days from the controller's webhook feed")
    else:
        notes.append(f"no history ({stats_note or 'unavailable'})")
    lines += ["", "<sub>" + "; ".join(notes) + ".</sub>"]
    return "\n".join(lines) + "\n"


def get_json(url: str, token: str | None = None, timeout: float = 15) -> dict:
    headers = {"Accept": "application/json", "User-Agent": "cmux-ci-timing-readout"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
        headers["X-GitHub-Api-Version"] = "2022-11-28"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as response:
        return json.load(response)


def fetch_jobs(api: str, repo: str, run_id: str, attempt: str, token: str) -> list[dict]:
    jobs: list[dict] = []
    for page in (1, 2, 3):
        data = get_json(f"{api}/repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}", token)
        jobs += data.get("jobs") or []
        if len(jobs) >= int(data.get("total_count") or 0) or not data.get("jobs"):
            break
    return jobs


def main() -> int:
    env = os.environ
    repo, run_id = env.get("GITHUB_REPOSITORY", ""), env.get("GITHUB_RUN_ID", "")
    attempt = env.get("GITHUB_RUN_ATTEMPT", "1")
    seg = segment(env.get("GITHUB_EVENT_NAME", ""), env.get("GITHUB_REF_NAME", ""))
    summary_path = env.get("GITHUB_STEP_SUMMARY")
    try:
        jobs = fetch_jobs(env.get("GITHUB_API_URL", "https://api.github.com"), repo, run_id, attempt, env.get("GH_TOKEN", ""))
    except Exception as error:  # noqa: BLE001 - a readout never fails CI
        print(f"ci timing readout: could not list this run's jobs: {error}", file=sys.stderr)
        return 0
    stats, note = None, ""
    base = env.get("CI_TIMING_STATS_URL", "").strip()
    if base:
        query = urllib.parse.urlencode({"repo": repo, "workflow": env.get("GITHUB_WORKFLOW", "CI"), "seg": seg})
        try:
            stats = get_json(f"{base}?{query}", timeout=10)
        except Exception as error:  # noqa: BLE001
            note = f"stats unreachable: {type(error).__name__}"
    else:
        note = "CI_TIMING_STATS_URL unset"
    try:
        text = build_readout(jobs, stats, seg, int(attempt or 1), note)
    except Exception as error:  # noqa: BLE001
        print(f"ci timing readout failed: {error}", file=sys.stderr)
        return 0
    print(text)
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as stream:
            stream.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
