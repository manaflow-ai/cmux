#!/usr/bin/env python3
"""Helpers for .github/workflows/billing-nightly.yml.

    billing_nightly.py config --environment ENV NAME...   # ready=true|false to $GITHUB_OUTPUT
    billing_nightly.py alert --title T --workflow FILE [--no-slack]

`config` reads HAS_<NAME>=true|false for each NAME (the workflow sets them
from `secrets.NAME != ''` or `vars.NAME != ''`, so no value reaches this
script). A missing name makes the job skip with a summary naming what an
operator must add to the `billing-nightly` environment; the night stays green.
With everything present it also reads the environment's deployment-branch
rule and fails unless it allows main alone: any workflow on any branch can
name an environment, so that rule is what keeps the secrets on main.

`alert` reads NEEDS (the workflow's `toJSON(needs)`). A failed or cancelled
job makes the night red: it opens one issue with the given title, or rewrites
the open one's body, and the next green night closes it, as
cloud-journey-prod.yml does. When the state changes (no open issue and red,
or an open issue and green) it also posts one message to Slack through the
notify-only CMUX_NOTIFY_TOKEN, as cloud-vm-canary.yml does. A missing token
or a failed post only warns: the issue is the record, and the night's verdict
comes from the jobs alone. `--no-slack` (feat-cmux-next's file) skips Slack.
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


def environment_allows_only_main(policy: dict | None, rules: list[list[str]] | None) -> bool:
    """The deployment_branch_policy and its custom rules ([name, type]) allow the main branch alone."""
    if not policy or not policy.get("custom_branch_policies") or policy.get("protected_branches"):
        return False
    return rules == [["main", "branch"]]


def _environment_rule(environment: str) -> tuple[dict | None, list[list[str]] | None]:
    repo = os.environ["GITHUB_REPOSITORY"]
    policy = json.loads(_gh("api", f"repos/{repo}/environments/{environment}", "--jq", ".deployment_branch_policy") or "null")
    rules = None
    if policy and policy.get("custom_branch_policies"):
        rules = json.loads(_gh("api", f"repos/{repo}/environments/{environment}/deployment-branch-policies",
                               "--jq", '[.branch_policies[] | [.name, (.type // "branch")]]'))
    return policy, rules


def config(environment: str, names: list[str]) -> int:
    if not names:
        print(__doc__, file=sys.stderr)
        return 2
    missing = missing_config(dict(os.environ), names)
    if missing:
        _write("GITHUB_OUTPUT", "ready=false\n")
        text = (
            "### Skipped: not configured\n\n"
            f"Limit the `{environment}` environment's deployment branches to main (Settings > Environments), "
            "then add these to it to turn this check on: " + ", ".join(f"`{name}`" for name in missing) + ".\n"
        )
        print(f"::notice title=Billing nightly check skipped::missing {', '.join(missing)}")
        _write("GITHUB_STEP_SUMMARY", text)
        return 0
    try:
        policy, rules = _environment_rule(environment)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
        _write("GITHUB_OUTPUT", "ready=false\n")
        print(f"::error::could not read the {environment} environment's deployment-branch rule: {error}")
        return 1
    if not environment_allows_only_main(policy, rules):
        _write("GITHUB_OUTPUT", "ready=false\n")
        print(f"::error::the {environment} environment holds secrets but its deployment branches are not main alone "
              f"(policy {json.dumps(policy)}, rules {rules}); any branch's workflow could read them. "
              "Restrict it to main in Settings > Environments.")
        return 1
    _write("GITHUB_OUTPUT", "ready=true\n")
    print("configuration present; environment limited to main")
    return 0


def _gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, text=True, capture_output=True).stdout.strip()


def _notify(text: str) -> None:
    """Posts to Slack; every failure is a warning, never the night's verdict."""
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
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            ok = json.loads(response.read() or b"{}").get("ok")
    except (OSError, ValueError) as error:
        print(f"::warning::the Slack post failed ({error}); the issue still records the state")
        return
    if not ok:
        print("::warning::the notify endpoint did not answer ok; the issue still records the state")


def alert(title: str, workflow: str, slack: bool = True) -> int:
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
    if not slack:
        pass
    elif plan["slack"] == "red":
        _notify(f":rotating_light: Billing nightly is red ({', '.join(bad)}). <{run_url}|run>")
    elif plan["slack"] == "green":
        _notify(f":white_check_mark: Billing nightly is green again. <{run_url}|run>")
    if bad:
        print(f"::error::billing nightly jobs did not pass: {', '.join(bad)}")
        return 1
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[0] == "config" and argv[1] == "--environment":
        return config(argv[2], argv[3:])
    if len(argv) in (5, 6) and argv[0] == "alert" and argv[1] == "--title" and argv[3] == "--workflow" \
            and argv[5:] in ([], ["--no-slack"]):
        return alert(argv[2], argv[4], slack=argv[5:] != ["--no-slack"])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
