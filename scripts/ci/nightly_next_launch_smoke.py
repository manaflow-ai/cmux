#!/usr/bin/env python3
"""What the cmux NEXT post-publish launch smoke does with a verdict (nightly-next-launch-smoke.yml).

The feed publishes without waiting on anything here. After a build is on the feed, the workflow
launches it from a fresh home (scripts/ci/fresh_home_launch_smoke.py) and this script decides:

  verdict --dir DIR
      The verdict of up to two harness runs (DIR/status-N and DIR/attempt-N/report.json). An attempt
      crashed only on the harness's own evidence: exit 1, report verdict fail, and the launched app's
      pid (the app exited, wrote a crash report, or never rendered Home). Anything else could not run
      (no GUI session, no app, a hop or harness error before launch). A crash counts only when both
      attempts crashed: a check cut short after one crash (a step timeout) is cannot-run, and so is
      any cannot-run attempt. Prints pass, crash or cannot-run.

  pick --feed LIVE.xml [--build BUILD]
      The build to smoke, as GITHUB_OUTPUT lines (build=, url=, length=): the newest feed item that
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

  evidence --report report.json --out FILE [--app-log app.log] [--crash FILE]...
      The crash issue's body: the harness failures, the app's system-log errors, the crash
      report's exception and termination, and the app output's last lines.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PASS, CRASH, CANNOT_RUN = "pass", "crash", "cannot-run"
ITEM = re.compile(r"<item>.*?</item>", re.S)
VERSION = re.compile(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>")
CHANNEL = re.compile(r"<sparkle:channel>\s*([^<]*?)\s*</sparkle:channel>")
# The channels a Nightly app accepts (nightly_next_live_feed_check.NIGHTLY_ACCEPTED): a stable-ring
# build is served to Nightly apps, so it is a rollback target too.
NIGHTLY_CHANNELS = (None, "cmux-next-stable", "cmux-next")
LOG_TAIL = 40


def attempt_result(status: int, report: dict) -> str:
    """One harness run's result. A crash needs the harness's own evidence that the app ran: exit 1,
    a report whose verdict is fail, and the launched app's pid. Exit 1 without that (a console-session
    hop that failed, an uncaught setup error) could not run."""
    if status == 0 and report.get("verdict") == "pass":
        return PASS
    if status == 1 and report.get("verdict") == "fail" and report.get("pid"):
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


ENCLOSURE = re.compile(r'<enclosure\s[^>]*?url="([^"]+\.dmg)"[^>]*?length="(\d+)"')
DMG_PREFIXES = ("https://github.com/manaflow-ai/cmux/releases/download/nightly-next/",
                "https://files-next.cmux.com/nightly-next/next/")


def nightly_offered(item: str) -> bool:
    channel = CHANNEL.search(item)
    return (channel.group(1) if channel else None) in NIGHTLY_CHANNELS


def pick(text: str, wanted: str = "") -> tuple[int, str, str]:
    """(build, DMG url, length) to smoke: the newest Nightly-offered item with a DMG, or WANTED."""
    items = []
    for item in ITEM.findall(text):
        version = VERSION.search(item)
        enclosure = ENCLOSURE.search(item)
        if version and enclosure:
            items.append((int(version.group(1)), enclosure.group(1), enclosure.group(2), nightly_offered(item)))
    if wanted:
        items = [i for i in items if str(i[0]) == wanted]
        if items and not items[0][3]:
            raise ValueError(f"build {wanted} is not offered to Nightly apps (a Dev or Canary ring build)")
    items = [i for i in items if i[3]]
    if not items:
        raise ValueError(f"no Nightly feed item {'for build ' + wanted if wanted else 'with a DMG'}")
    build, url, length, _ = max(items)
    if not url.startswith(DMG_PREFIXES):
        raise ValueError(f"{url} is not a nightly-next download")
    return build, url, length


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
    e = sub.add_parser("evidence")
    e.add_argument("--report", type=Path, required=True)
    e.add_argument("--app-log", type=Path)
    e.add_argument("--crash", type=Path, action="append", default=[])
    e.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == "pick":
        try:
            build, url, length = pick(args.feed.read_text(encoding="utf-8"), args.build)
        except ValueError as error:
            print(error, file=sys.stderr)
            return 1
        print(f"build={build}\nurl={url}\nlength={length}")
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
