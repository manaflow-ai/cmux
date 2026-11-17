#!/usr/bin/env python3
"""Helpers for .github/workflows/billing-nightly.yml.

    billing_nightly.py config NAME...   # ready=true|false to $GITHUB_OUTPUT
    billing_nightly.py alert --title T --workflow FILE

`config` reads HAS_<NAME>=true|false for each NAME (the workflow sets them
from `secrets.NAME != ''` or `vars.NAME != ''`, so no value reaches this
script). A missing name makes the job skip with a summary naming what an
operator must add to the `billing-nightly` environment; the night stays green.

`alert` reads NEEDS (the workflow's `toJSON(needs)`). A failed or cancelled
job makes the night red: it opens one issue with the given title, or rewrites
the open one's body, and the next green night closes it, as
cloud-journey-prod.yml does. When the state changes (no open issue and red,
or an open issue and green) it also posts one message to Slack through the
notify-only CMUX_NOTIFY_TOKEN, as cloud-vm-canary.yml does. A missing token
only warns: the issue is the record.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

RED_RESULTS = ("failure", "cancelled")


def missing_config(env: dict[str, str], names: list[str]) -> list[str]:
    return [name for name in names if env.get(f"HAS_{name}") != "true"]


def red_jobs(needs: dict[str, dict]) -> list[str]:
    return sorted(job for job, data in needs.items() if data.get("result") in RED_RESULTS)


def plan_alert(red: bool, open_issue: str) -> dict[str, str]:
    """What to do with the issue and Slack given tonight's verdict and the open issue, if any."""
    if red:
        return {"issue": "edit" if open_issue else "create", "slack": "" if open_issue else "red"}
    return {"issue": "close" if open_issue else "", "slack": "green" if open_issue else ""}


def issue_body(needs: dict[str, dict], run_url: str, workflow: str, now: datetime) -> str:
    rows = "\n".join(f"| {job} | {data.get('result', 'unknown')} |" for job, data in sorted(needs.items()))
    return (
        f"The Billing nightly (`.github/workflows/{workflow}`) is red.\n\n"
        f"Latest red run: {run_url} (each job's summary names the failed check).\n\n"
        f"| Job | Result |\n| --- | --- |\n{rows}\n\n"
        f"Updated {now.strftime('%Y-%m-%dT%H:%MZ')}. The next green night closes this issue.\n"
    )


def _write(path_var: str, text: str) -> None:
    path = os.environ.get(path_var)
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(text)


def config(names: list[str]) -> int:
    if not names:
        print(__doc__, file=sys.stderr)
        return 2
    missing = missing_config(dict(os.environ), names)
    _write("GITHUB_OUTPUT", f"ready={'false' if missing else 'true'}\n")
    if missing:
        text = (
            "### Skipped: not configured\n\n"
            "Add these to the `billing-nightly` environment (Settings > Environments; deployment branches: "
            "main only) to turn this check on: " + ", ".join(f"`{name}`" for name in missing) + ".\n"
        )
        print(f"::notice title=Billing nightly check skipped::missing {', '.join(missing)}")
        _write("GITHUB_STEP_SUMMARY", text)
    else:
        print("configuration present")
    return 0


def _gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, text=True, capture_output=True).stdout.strip()


def _notify(text: str) -> None:
    token = os.environ.get("CMUX_NOTIFY_TOKEN", "").strip()
    if not token:
        print(f"::warning::CMUX_NOTIFY_TOKEN is not set in the billing-nightly environment; not posting: {text}")
        return
    request = urllib.request.Request(
        os.environ["CMUX_NOTIFY_URL"].rstrip("/") + "/api/notify",
        data=json.dumps({"text": text, "sender": "billing-nightly",
                         "channel": os.environ["CMUX_NOTIFY_CHANNEL"]}).encode(),
        headers={"authorization": f"Bearer {token}", "content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        if not json.loads(response.read() or b"{}").get("ok"):
            raise RuntimeError("the notify endpoint did not answer ok")


def alert(title: str, workflow: str) -> int:
    needs = json.loads(os.environ["NEEDS"])
    run_url = os.environ["RUN_URL"]
    bad = red_jobs(needs)
    for job, data in sorted(needs.items()):
        print(f"{job}: {data.get('result')}")
    open_issue = _gh("issue", "list", "--state", "open", "--search", f'"{title}" in:title',
                     "--json", "number,title", "--jq", f'map(select(.title == {json.dumps(title)}))[0].number // ""')
    plan = plan_alert(bool(bad), open_issue)
    if plan["issue"] == "create":
        _gh("issue", "create", "--title", title, "--body", issue_body(needs, run_url, workflow, datetime.now(timezone.utc)))
    elif plan["issue"] == "edit":
        _gh("issue", "edit", open_issue, "--body", issue_body(needs, run_url, workflow, datetime.now(timezone.utc)))
    elif plan["issue"] == "close":
        _gh("issue", "close", open_issue, "--comment", f"Green again ([run]({run_url})).")
    if plan["slack"] == "red":
        _notify(f":rotating_light: Billing nightly is red ({', '.join(bad)}). <{run_url}|run>")
    elif plan["slack"] == "green":
        _notify(f":white_check_mark: Billing nightly is green again. <{run_url}|run>")
    if bad:
        print(f"::error::billing nightly jobs did not pass: {', '.join(bad)}")
        return 1
    return 0


def main(argv: list[str]) -> int:
    if argv and argv[0] == "config":
        return config(argv[1:])
    if len(argv) == 5 and argv[0] == "alert" and argv[1] == "--title" and argv[3] == "--workflow":
        return alert(argv[2], argv[4])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
