#!/usr/bin/env python3
"""The nightly-next canary's effective mode (docs/ci/nightly-next-canary.md).

Both canaries read it: nightly.yml's verify-signed-nightly (before
publication) and nightly-next-canary.yml (after). One resolver, so the two
always agree.

  resolve [--value V] [--enforce-after WHEN] [--now ISO] [--repo OWNER/NAME]

Repository variable NIGHTLY_NEXT_CANARY (--value):

  report | enforce | off   the toggle: used as given, nothing else is read.
  unset | auto             the default: report until NIGHTLY_NEXT_CANARY_ENFORCE_AFTER
                           (--enforce-after, an ISO date or time in UTC, or
                           `never`; empty means DEFAULT_ENFORCE_AFTER), then
                           enforce, but only when the post-publication canary
                           failed no build in the week before that time (the
                           report week). A failure there keeps auto in report
                           until someone triages it and sets `enforce` or moves
                           the date. The decision depends only on that fixed
                           week, so it does not flap.

The report week is read from the `nightly-next canary failed` issue the canary
opens or comments on (one entry per failed build). That needs GH_TOKEN with
issues: read. When the read fails, auto stays in report and says so.

Prints `mode=...` and `why=...` lines for $GITHUB_OUTPUT. Exit 0 always for a
valid input; 2 for a value it does not know (a typo must not silently enforce
or silently skip).

Other report-then-enforce gates on the nightly reuse this resolver with their
own names (docs/ci/nightly-next-visual-gate.md):

  resolve --variable NIGHTLY_NEXT_VISUAL_GATE --issue-title "nightly-next visual gate"
          --failure-prefix "cmux NEXT visual gate failed " --default-enforce-after WHEN
          --pass-prefix "cmux NEXT visual gate passed " --min-passes 3

--variable names the toggle in messages and the default for --value and
--enforce-after (read from $VARIABLE and $VARIABLE_ENFORCE_AFTER).
--min-passes N (default 0, the canary's rule) also needs N entries starting
with --pass-prefix in the report week before auto enforces: a week in which
the gate judged nothing is no evidence that it judges well.

A gate whose issue holds one entry per judged build (`<prefix><build sha>: ...`)
is that gate's record of each build's verdict:

  verdicts --issue-title T --pass-prefix P --failure-prefix F [--days 14]
      prints {"<build sha>": "pass" | "fail"} (the newest entry per build) as
      one JSON line; {} when the issue cannot be read.
  admit --mode MODE --build-sha SHA --verdicts JSON [--gate NAME]
      classify a recorded verdict for callers that need an advisory message.
      Visual coverage never controls nightly publication or recovery: signing,
      notarization, provenance and feed-order checks are the publication gates.

The visual gate runs on an owned Mac, and a self-hosted job that queues can
wait a day. The advisory verdict job reads the gate for a bounded time:

  await-gate --repo R --run-id ID --attempt N --job visual-gate-nightly
             [--queue-budget-minutes 15] [--gate-timeout-minutes 75]
             [--hold-minutes M] [--mode MODE]
      reads the run attempt's jobs every minute. A gate still queued when the
      queue budget is spent, a gate that never finishes, a missing gate or an
      unreadable API all give `verdict=unavailable` and `blocks=false`; it
      cancels nothing. A finished gate blocks only when its `Hold publication`
      step succeeded (enforce mode, failing verdict). --hold-minutes bounds the
      whole wait (else the queue budget plus the gate's timeout plus 5 min),
      from now, or with --since-job from when those jobs finished (GitHub's
      timestamps), and a hold then counts only when the gate finished within
      it. A --mode other than `enforce` can never hold the build, so it
      waits for nothing and gives `verdict=report`. Prints `verdict=` and
      `blocks=` lines for $GITHUB_OUTPUT.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from typing import Any, Callable, Iterable, Mapping

# One week after the canary went live in report mode on main (#21900,
# 2026-10-19) and the train design (leo-workspace#624, 2026-10-20).
DEFAULT_ENFORCE_AFTER = "2026-10-27T16:00:00Z"
REPORT_WEEK = dt.timedelta(days=7)
ISSUE_TITLE = "nightly-next canary failed"
# Every entry the canary writes starts with this (nightly-next-canary.yml).
FAILURE_PREFIX = "cmux NEXT build "
WRITER = "github-actions[bot]"  # the workflows' GITHUB_TOKEN writes every record entry
EXPLICIT = ("report", "enforce", "off")
VARIABLE = "NIGHTLY_NEXT_CANARY"


class BadValue(Exception):
    pass


def parse_when(text: str, default: str = DEFAULT_ENFORCE_AFTER, variable: str = VARIABLE) -> dt.datetime | None:
    """None for `never`; a UTC datetime otherwise (`default` when empty)."""
    text = text.strip()
    if text.lower() == "never":
        return None
    if not text:
        text = default
    try:
        when = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as err:
        raise BadValue(f"{variable}_ENFORCE_AFTER {text!r} is not an ISO date or `never`") from err
    if when.tzinfo is None:
        when = when.replace(tzinfo=dt.timezone.utc)
    return when.astimezone(dt.timezone.utc)


def failures_in(entries: Iterable[tuple[dt.datetime, str]], start: dt.datetime, end: dt.datetime,
                prefix: str = FAILURE_PREFIX) -> list[str]:
    """The failure entries (issue body or comment) written in [start, end)."""
    found = []
    for at, body in entries:
        if start <= at < end and body.lstrip().startswith(prefix):
            found.append(f"{at.strftime('%Y-%m-%dT%H:%MZ')} {body.strip().splitlines()[0][:120]}")
    return sorted(found)


def build_verdicts(entries: Iterable[tuple[dt.datetime, str]], pass_prefix: str,
                   failure_prefix: str) -> dict[str, str]:
    """{build sha: "pass" | "fail"} from entries `<prefix><sha>: ...`; the newest entry per build wins."""
    found: dict[str, str] = {}
    for _, body in sorted(entries, key=lambda entry: entry[0]):
        text = body.lstrip()
        for prefix, verdict in ((pass_prefix, "pass"), (failure_prefix, "fail")):
            if prefix and text.startswith(prefix):
                words = text[len(prefix):].split(maxsplit=1)
                sha = words[0].rstrip(":,.").lower() if words else ""
                if len(sha) == 40 and all(c in "0123456789abcdef" for c in sha):
                    found[sha] = verdict
                break
    return found


def admit(mode: str, build_sha: str, verdicts: dict[str, str],
          gate: str = "visual gate") -> tuple[bool, str, str]:
    """(publish?, annotation level, why) for one build: refused only in enforce mode with a recorded `fail`."""
    verdict = verdicts.get(build_sha.strip().lower())
    said = {"pass": "passed", "fail": "failed"}.get(verdict or "", "recorded no verdict for")
    if mode != "enforce":
        return True, "notice", f"the {gate} {said} {build_sha} and is in {mode or 'no'} mode; publishing it"
    if verdict == "fail":
        return False, "error", f"the {gate} failed {build_sha} and is in enforce mode; not publishing it"
    if verdict is None:
        return True, "warning", f"the {gate} recorded no verdict for {build_sha}; publishing it unchecked"
    return True, "notice", f"the {gate} passed {build_sha}; publishing it"


def resolve(value: str, enforce_after: str, now: dt.datetime,
            read_entries: Callable[[dt.datetime], list[tuple[dt.datetime, str]]], *,
            variable: str = VARIABLE, default_enforce_after: str = DEFAULT_ENFORCE_AFTER,
            failure_prefix: str = FAILURE_PREFIX, gate: str = "canary",
            pass_prefix: str = "", min_passes: int = 0) -> tuple[str, str]:
    value = value.strip().lower()
    if value in EXPLICIT:
        return value, f"{variable}={value}"
    if value not in ("", "auto"):
        raise BadValue(f"{variable}={value!r}: use report, enforce, off, auto or leave it unset")
    when = parse_when(enforce_after, default_enforce_after, variable)
    if when is None:
        return "report", f"auto: {variable}_ENFORCE_AFTER=never"
    stamp = when.strftime("%Y-%m-%dT%H:%MZ")
    if now < when:
        return "report", f"auto: report until {stamp}, then enforce"
    start = when - REPORT_WEEK
    try:
        entries = read_entries(start)
    except Exception as err:  # noqa: BLE001 - any read failure keeps report
        return "report", f"auto: could not read the report week ({err}); staying in report"
    failed = failures_in(entries, start, when, failure_prefix)
    if failed:
        return "report", (f"auto: the {gate} failed {len(failed)} build(s) in the report week before {stamp} "
                          f"(first: {failed[0]}); triage, then set {variable}=enforce or move "
                          f"{variable}_ENFORCE_AFTER")
    if min_passes > 0:
        # Distinct builds, not comments: a rerun of one build can record its pass more than once.
        in_week = [(at, body) for at, body in entries if start <= at < when]
        verdicts = build_verdicts(in_week, pass_prefix, failure_prefix) if pass_prefix else {}
        passed = sorted(sha for sha, verdict in verdicts.items() if verdict == "pass")
        if len(passed) < min_passes:
            return "report", (f"auto: the {gate} passed {len(passed)} build(s) in the report week before {stamp}, "
                              f"fewer than the {min_passes} it needs to enforce; set {variable}=enforce or move "
                              f"{variable}_ENFORCE_AFTER")
        return "enforce", (f"auto: enforce since {stamp} (no {gate} failure and {len(passed)} pass(es) "
                           "in the report week)")
    return "enforce", f"auto: enforce since {stamp} (no {gate} failure in the report week)"


def github_entries(repo: str, token: str, issue_title: str = ISSUE_TITLE, author: str = WRITER,
                   fetch: Callable[[str, dict[str, str]], object] | None = None,
                   ) -> Callable[[dt.datetime], list[tuple[dt.datetime, str]]]:
    """The record's entries (issue body and comments) written by `author` alone.

    The repository is public, so anyone can comment on the record or open an
    issue with its title; only the workflow's own token writes a verdict.
    """
    def get(path: str, query: dict[str, str]) -> object:
        url = f"https://api.github.com/{path}?{urllib.parse.urlencode(query)}"
        req = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "cmux-nightly-next-canary-mode/1",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.load(resp)

    def stamp(text: str) -> dt.datetime:
        return dt.datetime.fromisoformat(text.replace("Z", "+00:00"))

    def read(since: dt.datetime) -> list[tuple[dt.datetime, str]]:
        if not token:
            raise RuntimeError("no GH_TOKEN")
        read_json = fetch or get
        result = read_json("search/issues", {
            "q": f'repo:{repo} is:issue in:title "{issue_title}"', "per_page": "20"})
        entries: list[tuple[dt.datetime, str]] = []
        for issue in result.get("items", []):  # type: ignore[union-attr]
            if issue.get("title") != issue_title or (issue.get("user") or {}).get("login") != author:
                continue
            entries.append((stamp(issue["created_at"]), issue.get("body") or ""))
            page = 1
            while page <= 10:
                comments = read_json(f"repos/{repo}/issues/{issue['number']}/comments", {
                    "since": since.strftime("%Y-%m-%dT%H:%M:%SZ"), "per_page": "100", "page": str(page)})
                entries.extend((stamp(c["created_at"]), c.get("body") or "") for c in comments  # type: ignore[union-attr]
                               if (c.get("user") or {}).get("login") == author)
                if len(comments) < 100:  # type: ignore[arg-type]
                    break
                page += 1
        return entries

    return read


# The step of visual-gate-nightly that marks an enforce-mode failing verdict;
# its conclusion is what await-gate reads for advisory reporting.
GATE_MARKER = "Hold publication"
# A job not listed yet right after both jobs were queued is given this long to appear.
MISSING_GRACE_S = 300
# How late past the budget await_gate's last look may start and still count a hold (a sleep's jitter).
DEADLINE_SLACK_S = 5


def gate_job(jobs: Iterable[Mapping[str, Any]], job_name: str) -> Mapping[str, Any] | None:
    """The newest job named `job_name` in a run attempt's jobs, or None."""
    found = [job for job in jobs if job.get("name") == job_name]
    return max(found, key=lambda j: j.get("id") or 0) if found else None


def gate_action(jobs: Iterable[Mapping[str, Any]], job_name: str, elapsed_s: float, queue_budget_s: float,
                run_budget_s: float, marker: str = GATE_MARKER,
                missing_grace_s: float = MISSING_GRACE_S) -> tuple[str, str, bool, str]:
    """(action, verdict, blocks, why) for the gate job in a run attempt's `jobs`.

    action is `wait` (look again later) or `done`. Only a finished gate whose
    marker step succeeded blocks; a gate still waiting for a runner past the
    queue budget, one still running past the run budget, or one that is
    missing is `unavailable` and blocks nothing.
    """
    job = gate_job(jobs, job_name)
    if job is None:
        if elapsed_s < min(missing_grace_s, queue_budget_s):
            return "wait", "", False, f"{job_name} is not listed yet"
        return "done", "unavailable", False, f"{job_name} is not in this run attempt"
    status = job.get("status")
    if status == "completed":
        conclusion = str(job.get("conclusion") or "unknown")
        held = any(step.get("name") == marker and step.get("conclusion") == "success"
                   for step in job.get("steps") or [] if isinstance(step, Mapping))
        if held:
            return "done", "fail", True, f"{job_name} failed the build in enforce mode ({marker!r} ran)"
        return "done", conclusion, False, f"{job_name} finished ({conclusion}) without holding publication"
    minutes = int(elapsed_s // 60)
    if status != "in_progress" and not job.get("runner_name"):
        if elapsed_s >= queue_budget_s:
            return "done", "unavailable", False, (
                f"{job_name} waited {minutes} min for a runner, past the {int(queue_budget_s // 60)} min "
                "queue budget (the runner picked as idle was taken or went away)")
        return "wait", "", False, f"{job_name} is waiting for a runner ({minutes} min)"
    if elapsed_s >= run_budget_s:
        return "done", "unavailable", False, (
            f"{job_name} did not finish within {int(run_budget_s // 60)} min")
    return "wait", "", False, f"{job_name} is running ({minutes} min)"


def finished_at(job: Mapping[str, Any] | None) -> float | None:
    """A job's completed_at as a POSIX time, or None when it has none GitHub wrote."""
    try:
        return dt.datetime.fromisoformat(str(job["completed_at"]).replace("Z", "+00:00")).timestamp()
    except (KeyError, TypeError, ValueError):
        return None


def all_finished_at(jobs: Iterable[Mapping[str, Any]], prefix: str) -> float | None:
    """When the last job named `prefix`... finished, or None while any is unfinished or none is listed."""
    found = [job for job in jobs if str(job.get("name") or "").startswith(prefix)]
    times = [finished_at(job) if job.get("status") == "completed" else None for job in found]
    return max(times) if times and None not in times else None  # type: ignore[type-var]


def await_gate(fetch: Callable[[], list[Mapping[str, Any]]], job_name: str, queue_budget_s: float,
               run_budget_s: float, *, clock: Callable[[], float] = time.monotonic,
               sleep: Callable[[float], None] = time.sleep, interval_s: float = 60,
               max_errors: int = 5, since: str = "",
               wall: Callable[[], float] = time.time) -> tuple[str, bool, str]:
    """(verdict, blocks, why): polls `fetch` (the attempt's jobs) at most run_budget/interval times.

    With `since` (a job name prefix), the budgets run from when those jobs finished, by GitHub's own
    timestamps, rather than from this call: time this job spent queued for its own runner counts.
    A hold then counts only when the gate itself finished within the budget.
    """
    start = clock()
    anchored = not since
    errors = 0
    polls = int(run_budget_s // interval_s) + max_errors + 2
    why = "never looked"

    def rest() -> None:
        # The last look lands on the budget itself, never a whole interval past it.
        sleep(max(0.0, min(interval_s, run_budget_s - (clock() - start))))

    for _ in range(polls):
        elapsed = clock() - start
        try:
            jobs = fetch()
        except Exception as err:  # noqa: BLE001 - an unreadable API never holds publication
            errors += 1
            why = f"could not read the run's jobs ({err})"
            if errors >= max_errors or elapsed >= run_budget_s:
                return "unavailable", False, why
            rest()
            continue
        errors = 0
        if not anchored:
            anchored = True
            done_at = all_finished_at(jobs, since)
            if done_at is not None:
                # Both clocks read together, after the read: the anchor is when the jobs finished.
                start = clock() - max(0.0, wall() - done_at)
        # When the answer arrived, not when it was asked for: a read can take a while.
        elapsed = clock() - start
        action, verdict, blocks, why = gate_action(jobs, job_name, elapsed, queue_budget_s, run_budget_s)
        if action == "done":
            gate_done = finished_at(gate_job(jobs, job_name))
            deadline = wall() - elapsed + run_budget_s + DEADLINE_SLACK_S
            late = gate_done > deadline if gate_done is not None else elapsed > run_budget_s + DEADLINE_SLACK_S
            if blocks and late:
                # Seen only after the budget ran out: publication was promised it would not wait this long.
                return "unavailable", False, f"{why}, but only after the {int(run_budget_s // 60)} min budget"
            return verdict, blocks, why
        rest()
    return "unavailable", False, f"gave up after {polls} looks: {why}"


def github_jobs(repo: str, token: str, run_id: str, attempt: str,
                get: Callable[[str], object] | None = None) -> Callable[[], list[Mapping[str, Any]]]:
    """The jobs of one run attempt (GET .../actions/runs/ID/attempts/N/jobs), up to 500."""
    def read(url: str) -> object:
        req = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "cmux-nightly-next-canary-mode/1",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.load(resp)

    def jobs() -> list[Mapping[str, Any]]:
        if not token:
            raise RuntimeError("no GH_TOKEN")
        found: list[Mapping[str, Any]] = []
        for page in range(1, 6):
            data = (get or read)(f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/attempts/{attempt}"
                                 f"/jobs?per_page=100&page={page}")
            batch = data.get("jobs") if isinstance(data, dict) else None
            if not isinstance(batch, list):
                raise RuntimeError("the jobs response has no `jobs` list")
            found.extend(job for job in batch if isinstance(job, dict))
            if len(batch) < 100:
                break
        return found

    return jobs


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("resolve")
    r.add_argument("--variable", default=VARIABLE, help="the toggle's repository variable name")
    r.add_argument("--value", default=None, help="default: $VARIABLE")
    r.add_argument("--enforce-after", default=None, help="default: $VARIABLE_ENFORCE_AFTER")
    r.add_argument("--default-enforce-after", default=DEFAULT_ENFORCE_AFTER)
    r.add_argument("--issue-title", default=ISSUE_TITLE, help="the issue holding the report week's failures")
    r.add_argument("--failure-prefix", default=FAILURE_PREFIX, help="how each failure entry starts")
    r.add_argument("--gate", default="canary", help="the gate's name in messages")
    r.add_argument("--pass-prefix", default="", help="how each pass entry starts")
    r.add_argument("--min-passes", type=int, default=0, help="pass entries the report week needs to enforce")
    r.add_argument("--now", default="")
    r.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    v = sub.add_parser("verdicts")
    v.add_argument("--issue-title", required=True)
    v.add_argument("--pass-prefix", required=True)
    v.add_argument("--failure-prefix", required=True)
    v.add_argument("--days", type=float, default=14.0)
    v.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    a = sub.add_parser("admit")
    a.add_argument("--mode", required=True)
    a.add_argument("--build-sha", required=True)
    a.add_argument("--verdicts", default="{}")
    a.add_argument("--gate", default="visual gate")
    w = sub.add_parser("await-gate")
    w.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    w.add_argument("--run-id", required=True)
    w.add_argument("--attempt", default="1")
    w.add_argument("--job", default="visual-gate-nightly")
    w.add_argument("--queue-budget-minutes", type=float, default=15.0)
    w.add_argument("--gate-timeout-minutes", type=float, default=75.0)
    w.add_argument("--hold-minutes", type=float, default=None,
                   help="the longest this waits, from now, in all (default: queue budget + gate timeout + 5)")
    w.add_argument("--mode", default="", help="the gate's resolved mode; anything but `enforce` waits for nothing")
    w.add_argument("--since-job", default="",
                   help="a job name prefix: the budgets run from when those jobs finished, not from now")
    w.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY", ""))
    args = parser.parse_args(argv)
    if args.command == "await-gate":
        queue_s = args.queue_budget_minutes * 60
        run_s = (args.hold_minutes * 60 if args.hold_minutes is not None
                 else queue_s + args.gate_timeout_minutes * 60 + 300)
        mode = args.mode.strip().lower()
        token = os.environ.get("GH_TOKEN", "")
        if mode and mode != "enforce":
            # Only enforce runs the gate's `Hold publication` step, so no verdict can hold this
            # build: publication does not wait for the gate (it still reports its own verdict).
            verdict, blocks, why = "report", False, f"the gate is in `{mode}` mode, so it cannot hold this build"
        elif token:
            verdict, blocks, why = await_gate(github_jobs(args.repo, token, args.run_id, args.attempt), args.job,
                                              queue_s, run_s, since=args.since_job)
        else:
            verdict, blocks, why = "unavailable", False, f"no GH_TOKEN to read {args.job}"
        print(f"verdict={verdict}")
        print(f"blocks={'true' if blocks else 'false'}")
        level = "error" if blocks else ("warning" if verdict == "unavailable" else "notice")
        said = ("this run's build is not published" if blocks else
                "this nightly publishes unchecked" if verdict == "unavailable" else "publication goes ahead")
        print(f"::{level} title=nightly-next visual gate::{why}; {said}", file=sys.stderr)
        if verdict == "unavailable" and args.summary:
            with open(args.summary, "a", encoding="utf-8") as out:
                out.write(f"## Nightly visual gate\n\nVerdict `unavailable`: {why}. {said[0].upper() + said[1:]}. "
                          "Nothing was cancelled.\n")
        return 0
    if args.command == "verdicts":
        since = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=args.days)
        try:
            entries = github_entries(args.repo, os.environ.get("GH_TOKEN", ""), args.issue_title)(since)
        except Exception as err:  # noqa: BLE001 - unreadable: no verdicts, so nothing is refused
            print(f"::warning title=nightly-next verdicts::could not read {args.issue_title!r} ({err})",
                  file=sys.stderr)
            entries = []
        print(json.dumps(build_verdicts(entries, args.pass_prefix, args.failure_prefix), sort_keys=True,
                         separators=(",", ":")))
        return 0
    if args.command == "admit":
        try:
            verdicts = json.loads(args.verdicts or "{}")
        except ValueError:
            verdicts = {}
        ok, level, why = admit(args.mode.strip().lower(), args.build_sha,
                               verdicts if isinstance(verdicts, dict) else {}, args.gate)
        print(f"::{level} title=nightly-next {args.gate}::{why}")
        return 0 if ok else 1
    value = args.value if args.value is not None else os.environ.get(args.variable, "")
    enforce_after = (args.enforce_after if args.enforce_after is not None
                     else os.environ.get(f"{args.variable}_ENFORCE_AFTER", ""))
    now = parse_when(args.now) if args.now else dt.datetime.now(dt.timezone.utc)
    assert now is not None
    try:
        mode, why = resolve(value, enforce_after, now,
                            github_entries(args.repo, os.environ.get("GH_TOKEN", ""), args.issue_title),
                            variable=args.variable, default_enforce_after=args.default_enforce_after,
                            failure_prefix=args.failure_prefix, gate=args.gate,
                            pass_prefix=args.pass_prefix, min_passes=args.min_passes)
    except BadValue as err:
        print(f"::error title=nightly-next {args.gate} mode::{err}", file=sys.stderr)
        return 2
    print(f"mode={mode}")
    print(f"why={why}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
