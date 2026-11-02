#!/usr/bin/env python3
"""What the cmux NEXT post-publish launch smoke does with a verdict (nightly-next-launch-smoke.yml).

The feed publishes without waiting on anything here. After a build is on the feed, the workflow
launches it from a fresh home (scripts/ci/fresh_home_launch_smoke.py) and this script decides:

  verdict --dir DIR
      The verdict of up to two harness runs (DIR/status-N and DIR/attempt-N/report.json). An attempt
      crashed only on the harness's own evidence: exit 1, report verdict fail, and the launched app's
      pid, plus a nonzero app exit, a crash report, or an uncaught exception in that report. A live
      app that never rendered Home is a failed smoke, but is not a launch crash and cannot trigger a
      rollback. Anything else could not run (no GUI session, no app, a hop or harness error before
      launch). A crash counts only when both attempts crashed: a check cut short after one crash (a
      step timeout) is cannot-run, and so is any cannot-run attempt. Prints pass, crash or cannot-run.

  pick --feed LIVE.xml [--build BUILD]
      The build to smoke, as GITHUB_OUTPUT lines (build=, url=, length=, ed_signature=, the item's
      sparkle:edSignature the smoke checks the downloaded DMG against): the newest feed item that
      Nightly apps are offered (untagged, cmux-next or cmux-next-stable) and that has a nightly-next
      DMG, or BUILD when given. A Dev-ring (cmux-next-dev) or Canary-only item is never picked, so a
      newer Dev-only build is skipped and the Nightly build below it is smoked. Exit 1 with no pick.

  decide --feed LIVE.xml --build BUILD --verdict VERDICT
      Whether to roll the feed back, as JSON {"action": "rollback"|"none", "why": ...}. Only a crash
      rolls back, only of a build Nightly apps are offered (never a Dev-only one), only while BUILD
      is still the feed's newest build, and only while an earlier build that Nightly apps are offered
      stays to serve. So a second crash report of the same build, after its rollback, does nothing,
      and a rollback never pulls a newer build (a Dev one included) or goes past the kept good one.
      The rollback itself is nightly-next-rollback.yml (bad_build=BUILD).

  in-flight --build BUILD
      Another run's smoke of BUILD that is queued or running, as a GITHUB_OUTPUT line (in_flight=RUN or
      in_flight= ), read live from this workflow's runs (GITHUB_REPOSITORY, GITHUB_RUN_ID, GH_TOKEN). A
      scheduled tick skips such a build, so each build has one smoke at a time: on 2026-10-29 the smokes
      waited 45 minutes to 2 hours for a Mac and the 10-minute ticks queued up to three per build. A read
      that fails prints a warning and in_flight=unknown; scheduled ticks skip dispatch until the next
      successful read. Manual and pull-request runs still proceed.

  evidence --report report.json --out FILE [--app-log app.log] [--crash FILE]...
      The crash issue's body: the harness failures, the app's system-log errors, the crash
      report's exception and termination, and the app output's last lines.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from pathlib import Path
from typing import Callable, Mapping

PASS, CRASH, CANNOT_RUN, UNKNOWN = "pass", "crash", "cannot-run", "unknown"
ITEM = re.compile(r"<item>.*?</item>", re.S)
VERSION = re.compile(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>")
CHANNEL = re.compile(r"<sparkle:channel>\s*([^<]*?)\s*</sparkle:channel>")
# The channels a Nightly app accepts (nightly_next_live_feed_check.NIGHTLY_ACCEPTED): a stable-ring
# build is served to Nightly apps, so it is a rollback target too.
NIGHTLY_CHANNELS = (None, "cmux-next-stable", "cmux-next")
LOG_TAIL = 40


def attempt_result(status: int, report: dict) -> str:
    """One harness run's result.

    A crash needs both the harness's evidence that the app ran (exit 1, a failed report and its pid)
    and evidence from the app itself: a nonzero process exit, a crash report or an uncaught exception.
    A failed report from a live app that never rendered Home is not a launch crash, so it cannot roll a
    build back. Exit 1 without the harness or app evidence (a console-session hop or setup error) could
    not run.
    """
    if status == 0 and report.get("verdict") == "pass":
        return PASS
    exit_status = report.get("exit")
    app_crashed = (
        isinstance(exit_status, int) and not isinstance(exit_status, bool) and exit_status != 0
    ) or bool(report.get("crash_reports")) or bool(report.get("run_exceptions"))
    if status == 1 and report.get("verdict") == "fail" and report.get("pid") and app_crashed:
        return CRASH
    return CANNOT_RUN


def verdict(attempts: list[tuple[int, dict]], required: int = 2) -> str:
    for status, report in attempts:
        result = attempt_result(status, report)
        if result != CRASH:
            return result
    # Every attempt crashed; fewer than REQUIRED means the check was cut short (a timeout).
    return CRASH if attempts and len(attempts) >= required else CANNOT_RUN


def read_attempts(directory: Path) -> list[tuple[int, dict]]:
    """attempt-N/{status,report.json} under DIRECTORY, in order; a missing report reads as {}."""
    found = []
    for n in range(1, 10):
        status_file = directory / f"status-{n}"
        if not status_file.exists():
            break
        try:
            status = int(status_file.read_text().strip())
        except ValueError:
            status = -1
        try:
            report = json.loads((directory / f"attempt-{n}" / "report.json").read_text())
        except (OSError, ValueError):
            report = {}
        found.append((status, report if isinstance(report, dict) else {}))
    return found


ENCLOSURE = re.compile(r'<enclosure\s[^>]*?url="([^"]+\.dmg)"[^>]*?length="(\d+)"[^>]*>')
ED_SIGNATURE = re.compile(r'\ssparkle:edSignature="([^"]*)"')
DMG_PREFIXES = ("https://github.com/manaflow-ai/cmux/releases/download/nightly-next/",
                "https://files-next.cmux.com/nightly-next/next/")


def nightly_offered(item: str) -> bool:
    channel = CHANNEL.search(item)
    return (channel.group(1) if channel else None) in NIGHTLY_CHANNELS


def pick(text: str, wanted: str = "") -> tuple[int, str, str, str]:
    """(build, DMG url, length, edSignature) to smoke: the newest Nightly-offered item with a DMG, or
    WANTED. The edSignature is empty when the enclosure has none (the DMG check then fails)."""
    items = []
    for item in ITEM.findall(text):
        version = VERSION.search(item)
        enclosure = ENCLOSURE.search(item)
        if version and enclosure:
            signature = ED_SIGNATURE.search(enclosure.group(0))
            items.append((int(version.group(1)), enclosure.group(1), enclosure.group(2), nightly_offered(item),
                          signature.group(1) if signature else ""))
    if wanted:
        items = [i for i in items if str(i[0]) == wanted]
        if items and not items[0][3]:
            raise ValueError(f"build {wanted} is not offered to Nightly apps (a Dev or Canary ring build)")
    items = [i for i in items if i[3]]
    if not items:
        raise ValueError(f"no Nightly feed item {'for build ' + wanted if wanted else 'with a DMG'}")
    build, url, length, _, signature = max(items)
    if not url.startswith(DMG_PREFIXES):
        raise ValueError(f"{url} is not a nightly-next download")
    return build, url, length, signature


def feed_builds(text: str) -> list[tuple[int, bool]]:
    """(build, offered to Nightly apps) for each feed item."""
    found = []
    for item in ITEM.findall(text):
        version = VERSION.search(item)
        if version is None:
            continue
        found.append((int(version.group(1)), nightly_offered(item)))
    return found


def decide(feed: str, build: int, result: str) -> dict:
    if result != CRASH:
        return {"action": "none", "why": f"the smoke's verdict is {result}; only a launch crash rolls back"}
    builds = feed_builds(feed)
    if not builds:
        return {"action": "none", "why": "the live feed has no items"}
    newest = max(b for b, _ in builds)
    if build not in {b for b, _ in builds}:
        return {"action": "none", "why": f"build {build} is no longer on the feed (already rolled back)"}
    if build not in {b for b, nightly in builds if nightly}:
        return {"action": "none", "why": f"build {build} is not offered to Nightly apps (a Dev or Canary ring "
                                         f"build); the launch smoke never rolls one back"}
    if build != newest:
        return {"action": "none", "why": f"the feed's newest build is {newest}, newer than {build}; "
                                         f"a rollback of {build} would pull it too"}
    earlier = sorted({b for b, nightly in builds if nightly and b < build}, reverse=True)
    if not earlier:
        return {"action": "none", "why": f"no earlier Nightly build on the feed to serve instead of {build}"}
    return {"action": "rollback", "why": f"build {build} crashed at launch; the feed serves {earlier[0]} again",
            "serving": earlier[0]}


def crash_summary(path: Path) -> list[str]:
    """The .ips header's app and version, and its exception and termination (JSON after the first line)."""
    text = path.read_text(errors="replace")
    head, _, body = text.partition("\n")
    lines = [f"`{path.name}`"]
    try:
        meta = json.loads(head)
        lines.append(f"- app {meta.get('app_name', '?')} {meta.get('app_version', '?')} build {meta.get('build_version', '?')}")
    except ValueError:
        pass
    try:
        report = json.loads(body)
    except ValueError:
        return lines + ["- (not a JSON crash report; see the evidence artifact)"]
    exception = report.get("exception") or {}
    if exception:
        lines.append(f"- exception {exception.get('type', '?')} {exception.get('signal', '')} {exception.get('subtype', '')}".rstrip())
    termination = report.get("termination") or {}
    if termination:
        lines.append(f"- termination {termination.get('namespace', '?')} {termination.get('indicator', termination.get('code', ''))}")
    asi = report.get("asi") or {}
    for key, values in asi.items():
        for value in values[:3]:
            lines.append(f"- {key}: {str(value)[:300]}")
    return lines


def evidence(report: dict, app_log: str | None, crashes: list[Path]) -> str:
    out = ["**Harness failures**", ""]
    out += [f"- {failure}" for failure in report.get("failures") or ["(none recorded)"]]
    errors = report.get("system_log_errors") or []
    if errors:
        out += ["", "**The app's errors in the system log**", "", "```", *errors[:20], "```"]
    for path in crashes:
        out += ["", "**Crash report**", "", *crash_summary(path)]
    if app_log:
        tail = [line for line in app_log.splitlines() if not line.startswith("objc[")][-LOG_TAIL:]
        out += ["", f"**App output (last {len(tail)} lines)**", "", "```", *tail, "```"]
    return "\n".join(out) + "\n"


SMOKE_WORKFLOW = "nightly-next-launch-smoke.yml"
API = "https://api.github.com"


def smoke_job(build: int | str) -> str:
    """The smoke job's name for BUILD (the workflow's `name: smoke ${{ needs.pick.outputs.build }}`)."""
    return f"smoke {build}"


def in_flight(runs: list[dict], jobs_of: Callable[[int], list[dict]], build: int | str, own_run: int) -> int | None:
    """The id of another run that has a smoke of BUILD queued or running, else None.

    `runs` are this workflow's runs, newest first (the REST list). A run that has not completed (a pull
    request's too: its smoke takes a Mac like any other) holds BUILD while its `smoke BUILD`
    job exists and was not skipped: queued for a runner, running, or done while its run still records the
    verdict or files the crash. Only a completed run lets the next tick smoke BUILD again, which a recorded
    pass or cannot-run then stops in pick and a crash does not (it is retried until its rollback lands).
    """
    name = smoke_job(build)
    for run in runs:
        if run.get("status") == "completed" or int(run.get("id") or 0) == own_run:
            continue
        for job in jobs_of(int(run["id"])):
            if job.get("name") == name and job.get("conclusion") != "skipped":
                return int(run["id"])
    return None


def read_in_flight(build: int | str, env: Mapping[str, str]) -> int | None:
    """in_flight() over the live runs, read with GH_TOKEN (the repository is public, so any token reads it)."""
    repo = env["GITHUB_REPOSITORY"]
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
               "User-Agent": "cmux-nightly-next-launch-smoke"}
    if env.get("GH_TOKEN"):
        headers["Authorization"] = f"Bearer {env['GH_TOKEN']}"

    def get(path: str) -> dict:
        request = urllib.request.Request(f"{API}/repos/{repo}{path}", headers=headers)
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)

    runs = get(f"/actions/workflows/{SMOKE_WORKFLOW}/runs?per_page=100").get("workflow_runs") or []
    return in_flight(runs, lambda run: get(f"/actions/runs/{run}/jobs?filter=latest&per_page=100").get("jobs") or [],
                     build, int(env.get("GITHUB_RUN_ID") or 0))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    k = sub.add_parser("pick")
    k.add_argument("--feed", type=Path, required=True)
    k.add_argument("--build", default="")
    v = sub.add_parser("verdict")
    v.add_argument("--dir", type=Path, required=True)
    d = sub.add_parser("decide")
    d.add_argument("--feed", type=Path, required=True)
    d.add_argument("--build", type=int, required=True)
    d.add_argument("--verdict", choices=[PASS, CRASH, CANNOT_RUN], required=True)
    f = sub.add_parser("in-flight")
    f.add_argument("--build", required=True)
    e = sub.add_parser("evidence")
    e.add_argument("--report", type=Path, required=True)
    e.add_argument("--app-log", type=Path)
    e.add_argument("--crash", type=Path, action="append", default=[])
    e.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == "pick":
        try:
            build, url, length, signature = pick(args.feed.read_text(encoding="utf-8"), args.build)
        except ValueError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"build={build}\nurl={url}\nlength={length}\ned_signature={signature}")
    elif args.command == "in-flight":
        try:
            run = read_in_flight(args.build, os.environ)
        except Exception as error:  # noqa: BLE001 - preserve manual/PR behavior, fail closed on schedule
            message = f"could not read the in-flight smokes ({error}); scheduled dispatch is paused"
            print(f"::warning title=nightly-next launch smoke::{message}", file=sys.stderr)
            summary = os.environ.get("GITHUB_STEP_SUMMARY")
            if summary:
                try:
                    with open(summary, "a", encoding="utf-8") as output:
                        output.write("### cmux NEXT launch smoke: in-flight state unknown\n\n")
                        output.write(f"{message}. The next scheduled tick will retry the read.\n")
                except OSError as summary_error:
                    print(f"::warning title=nightly-next launch smoke::could not write the step summary "
                          f"({summary_error})", file=sys.stderr)
            print(f"in_flight={UNKNOWN}")
            return 0
        if run:
            print(f"::notice title=nightly-next launch smoke::run {run} already has a smoke of build {args.build} "
                  "queued or running; this tick does not start another", file=sys.stderr)
        print(f"in_flight={run or ''}")
    elif args.command == "verdict":
        print(verdict(read_attempts(args.dir)))
    elif args.command == "decide":
        print(json.dumps(decide(args.feed.read_text(encoding="utf-8"), args.build, args.verdict)))
    else:
        report = json.loads(args.report.read_text()) if args.report.exists() else {}
        log = args.app_log.read_text(errors="replace") if args.app_log and args.app_log.exists() else None
        args.out.write_text(evidence(report, log, [p for p in args.crash if p.exists()]), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
