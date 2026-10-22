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
      exit 0 to publish the build, 1 to refuse it: only `enforce` with a
      `fail` verdict refuses. A build with no verdict is published (with a
      warning in enforce): a gate that could not judge never blocks.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.parse
import urllib.request
from typing import Callable, Iterable

# One week after the canary went live in report mode on main (#21900,
# 2026-10-19) and the train design (leo-workspace#624, 2026-10-20).
DEFAULT_ENFORCE_AFTER = "2026-10-27T16:00:00Z"
REPORT_WEEK = dt.timedelta(days=7)
ISSUE_TITLE = "nightly-next canary failed"
# Every entry the canary writes starts with this (nightly-next-canary.yml).
FAILURE_PREFIX = "cmux NEXT build "
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
        passed = failures_in(entries, start, when, pass_prefix) if pass_prefix else []
        if len(passed) < min_passes:
            return "report", (f"auto: the {gate} passed {len(passed)} build(s) in the report week before {stamp}, "
                              f"fewer than the {min_passes} it needs to enforce; set {variable}=enforce or move "
                              f"{variable}_ENFORCE_AFTER")
        return "enforce", (f"auto: enforce since {stamp} (no {gate} failure and {len(passed)} pass(es) "
                           "in the report week)")
    return "enforce", f"auto: enforce since {stamp} (no {gate} failure in the report week)"


def github_entries(repo: str, token: str,
                   issue_title: str = ISSUE_TITLE) -> Callable[[dt.datetime], list[tuple[dt.datetime, str]]]:
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
        result = get("search/issues", {
            "q": f'repo:{repo} is:issue in:title "{issue_title}"', "per_page": "20"})
        entries: list[tuple[dt.datetime, str]] = []
        for issue in result.get("items", []):  # type: ignore[union-attr]
            if issue.get("title") != issue_title:
                continue
            entries.append((stamp(issue["created_at"]), issue.get("body") or ""))
            page = 1
            while page <= 10:
                comments = get(f"repos/{repo}/issues/{issue['number']}/comments", {
                    "since": since.strftime("%Y-%m-%dT%H:%M:%SZ"), "per_page": "100", "page": str(page)})
                entries.extend((stamp(c["created_at"]), c.get("body") or "") for c in comments)  # type: ignore[union-attr]
                if len(comments) < 100:  # type: ignore[arg-type]
                    break
                page += 1
        return entries

    return read


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
    args = parser.parse_args(argv)
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
