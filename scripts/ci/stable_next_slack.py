#!/usr/bin/env python3
"""cmux NEXT Stable's Slack messages (stable-next.yml): one message per run, kept current.

A publish run posts one message to the channel when its gates start, answers in that message's thread
as each gate ends (with what failed and why), and edits the message when the run ends: shipped, or
blocked and by which gates. A run blocked before its gates (plan refused the build) posts the final
message alone. Nothing is posted for a night with nothing new to test.

  stable_next_slack.py start
      Posts the run's message; writes ts= and channel= to GITHUB_OUTPUT.
  stable_next_slack.py lane --lane NAME --result RESULT [--detail TEXT]
      Answers in the thread: NAME passed, failed, was cancelled or skipped, with DETAIL.
  stable_next_slack.py final --results NAME=RESULT[,NAME=RESULT...] [--detail NAME=TEXT ...]
      Edits the run's message (TS and CHANNEL from the environment), or posts a new one when there
      is none: shipped or blocked, every gate's result, and the mention when blocked.

Environment: SLACK_BOT_TOKEN (a bot with chat:write that is a member of the channel) and SLACK_CHANNEL
(a channel id). With either missing the script says so and exits 0: Slack is a report, never a gate.
A Slack error is a warning, for the same reason. Also BUILD, SHORT_VERSION, COMMIT, RUN_URL, MENTION
(optional, "<@U...>" or "<!subteam^S...>"), TS and CHANNEL_ID (final and lane). A failed gate's reason is
its job's error annotations (GITHUB_TOKEN with actions: read and checks: read): every gate writes why it
failed as an ::error line.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

# Gate order and plain names, as people read them in Slack.
LANES = [
    ("crash-class", "Crash-risk scan"),
    ("perf-budgets", "Speed check (perf budgets)"),
    ("sign", "Re-sign and notarize"),
    ("smoke-27", "First-session UI test, macOS 27"),
    ("smoke-26", "First-session UI test, macOS 26"),
    ("soak", "Pulled, canary and crash-report check"),
    ("publish", "Publish to the Stable feed"),
]
NAMES = dict(LANES)
ICON = {"success": ":white_check_mark:", "failure": ":x:", "cancelled": ":no_entry_sign:",
        "skipped": ":white_circle:", "pending": ":hourglass_flowing_sand:"}
WORD = {"success": "passed", "failure": "failed", "cancelled": "was cancelled", "skipped": "was skipped"}
FEED = "https://files-next.cmux.com/nightly-next/stable/appcast-arm64.xml"
DETAIL_LIMIT = 2800  # a section block's text is at most 3000 characters


def clip(text: str, limit: int = DETAIL_LIMIT) -> str:
    text = text.strip()
    return text if len(text) <= limit else text[: limit - 20].rstrip() + "\n… (see the run)"


def header(env: dict) -> str:
    build, short = env.get("BUILD", ""), env.get("SHORT_VERSION", "")
    commit, run = env.get("COMMIT", ""), env.get("RUN_URL", "")
    parts = [f"build `{build}`" + (f" ({short})" if short and short != build else "") if build else "no build picked"]
    if commit:
        parts.append(f"commit `{commit[:10]}`")
    if run:
        parts.append(f"<{run}|run>")
    return " · ".join(parts)


def lanes_line(results: dict) -> str:
    return "\n".join(f"{ICON.get(results.get(lane, 'pending'), ICON['pending'])} {name}" for lane, name in LANES)


def message(title: str, env: dict, results: dict, extra: str = "") -> dict:
    text = f"{title}\n{header(env)}"
    blocks = [
        {"type": "section", "text": {"type": "mrkdwn", "text": f"{title}\n{header(env)}"}},
        {"type": "section", "text": {"type": "mrkdwn", "text": lanes_line(results)}},
    ]
    if extra:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": clip(extra)}})
    return {"text": text, "blocks": blocks}


def start_message(env: dict) -> dict:
    return message(":crescent_moon: *cmux NEXT Stable* is testing tonight's build", env, {})


FENCE = "`" * 3


def escape(text: str) -> str:
    """Text safe inside a Slack code block: Slack's control characters escaped (no mention or link can
    fire), and no fence of its own to end the block early."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace(FENCE, "ʼʼʼ")


def lane_message(lane: str, result: str, detail: str, env: dict) -> dict:
    name = NAMES.get(lane, lane)
    word, icon = WORD.get(result, result), ICON.get(result, ICON["pending"])
    if result == "success" and detail.strip():  # passed with a caveat (a ::warning): never a clean pass
        word, icon = "passed, with a warning", ":warning:"
    line = f"{icon} *{name}* {word}"
    if detail.strip():
        line += f"\n{FENCE}{clip(escape(detail), DETAIL_LIMIT - len(line) - 8)}{FENCE}"
    return {"text": f"{name} {word}", "blocks": [{"type": "section", "text": {"type": "mrkdwn", "text": line}}]}


def final_message(results: dict, details: dict, env: dict) -> dict:
    if results.get("publish") == "success":
        title = f":rocket: *cmux NEXT Stable shipped* {env.get('SHORT_VERSION') or env.get('BUILD', '')}"
        return message(title, env, results, f"Stable apps get it on their next update check. <{FEED}|Feed>")
    if results.get("plan") not in (None, "success"):
        reason = details.get("plan", "").strip() or "it could not pick a build"
        title = ":x: *cmux NEXT Stable is blocked*: no build was tested"
        extra = f"Plan: {reason}"
    else:
        failed = [lane for lane, _ in LANES if results.get(lane) in ("failure", "cancelled")]
        names = ", ".join(NAMES[lane] for lane in failed) or "the run did not finish"
        title = f":x: *cmux NEXT Stable is blocked*: {names}"
        extra = "Stable keeps serving its last build. Why each gate failed is in this thread."
    mention = env.get("MENTION", "").strip()
    if mention:
        extra = f"{mention} {extra}"
    return message(title, env, results, extra)


# why a gate failed ----------------------------------------------------------------------------------

NOISE = ("Process completed with exit code", "The operation was canceled", "The job was not started")


def reasons(annotations: list[dict], level: str = "failure") -> str:
    """A job's annotations of LEVEL as lines: each gate writes why it failed as an ::error, and a pass
    with a caveat (perf measured nothing, crash reports unreadable) as a ::warning."""
    lines = []
    for note in annotations:
        if note.get("annotation_level") != level:
            continue
        # Warnings only from this pipeline ("cmux NEXT Stable…", "stable perf"), never the runner's own
        # (an action's Node deprecation): those would turn a clean pass into "passed, with a warning".
        if level == "warning" and "stable" not in (note.get("title") or "").lower():
            continue
        text = (note.get("message") or "").strip()
        if not text or text.startswith(NOISE):
            continue
        title = (note.get("title") or "").replace("cmux NEXT Stable: ", "").replace("cmux NEXT Stable", "").strip(": ")
        lines.append(f"{title}: {text}" if title and title not in text else text)
    return "\n".join(dict.fromkeys(lines))


def github(path: str) -> object:
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    request = urllib.request.Request(f"{api}{path}", headers={
        "Authorization": f"Bearer {os.environ.get('GITHUB_TOKEN', '')}", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def job_reasons(job: str, level: str = "failure") -> str:
    """Job JOB's annotations of LEVEL in this run; empty when they cannot be read."""
    repo, run = os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_RUN_ID", "")
    if not repo or not run or not os.environ.get("GITHUB_TOKEN"):
        return ""
    try:
        jobs = github(f"/repos/{repo}/actions/runs/{run}/jobs?per_page=100").get("jobs", [])
        found = [j for j in jobs if j.get("name") == job]
        if not found:
            return ""
        return reasons(github(f"/repos/{repo}/check-runs/{found[-1]['id']}/annotations?per_page=50"), level)
    except Exception as error:  # noqa: BLE001 - a report never fails the run
        warn(f"annotations of {job}: {error}")
        return ""


# slack --------------------------------------------------------------------------------------------

def call(method: str, token: str, body: dict) -> dict:
    request = urllib.request.Request(
        f"{os.environ.get('SLACK_API_URL', 'https://slack.com/api')}/{method}", data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=utf-8"})
    with urllib.request.urlopen(request, timeout=30) as response:
        answer = json.load(response)
    if not answer.get("ok"):
        raise RuntimeError(f"{method}: {answer.get('error', 'not ok')}")
    return answer


def warn(text: str) -> None:
    print(f"::warning title=cmux NEXT Stable Slack::{text}")


def output(**values: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            for key, value in values.items():
                handle.write(f"{key}={value}\n")


def parse_pairs(items: list[str]) -> dict:
    pairs = {}
    for item in items:
        for part in item.split(","):
            if "=" in part:
                key, value = part.split("=", 1)
                pairs[key.strip()] = value.strip()
    return pairs


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("start")
    lane = sub.add_parser("lane")
    lane.add_argument("--lane", required=True)
    lane.add_argument("--result", required=True)
    lane.add_argument("--detail", default="")
    final = sub.add_parser("final")
    final.add_argument("--results", action="append", default=[])
    final.add_argument("--detail", action="append", default=[])
    args = parser.parse_args(argv)

    env = dict(os.environ)
    token, channel = env.get("SLACK_BOT_TOKEN", ""), env.get("SLACK_CHANNEL", "")
    if not token or not channel:
        warn("not posted: SLACK_BOT_TOKEN (secret STABLE_NEXT_SLACK_BOT_TOKEN) or SLACK_CHANNEL "
             "(variable STABLE_NEXT_SLACK_CHANNEL) is not set")
        return 0
    try:
        if args.command == "start":
            answer = call("chat.postMessage", token, {"channel": channel, "unfurl_links": False, **start_message(env)})
            output(ts=answer["ts"], channel=answer["channel"])
        elif args.command == "lane":
            ts = env.get("TS", "")
            if not ts:
                return 0
            detail = args.detail
            if not detail and args.result == "failure":
                detail = job_reasons(args.lane)
            elif not detail and args.result == "success":
                detail = job_reasons(args.lane, "warning")
            body = lane_message(args.lane, args.result, detail, env)
            call("chat.postMessage", token, {"channel": env.get("CHANNEL_ID") or channel, "thread_ts": ts,
                                             "unfurl_links": False, **body})
        else:
            results = parse_pairs(args.results)
            details = {}
            for item in args.detail:
                key, _, value = item.partition("=")
                details[key] = value
            if results.get("plan") not in (None, "success") and not details.get("plan"):
                details["plan"] = job_reasons("plan")
            body = final_message(results, details, env)
            ts, where = env.get("TS", ""), env.get("CHANNEL_ID") or channel
            if ts:
                call("chat.update", token, {"channel": where, "ts": ts, **body})
            else:
                call("chat.postMessage", token, {"channel": channel, "unfurl_links": False, **body})
    except Exception as error:  # noqa: BLE001 - Slack is a report: a dropped connection never fails the run
        warn(f"{args.command}: {type(error).__name__}: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
