#!/usr/bin/env python3
"""One row per signer for a hedged nightly-next build, and the flake signal when they disagree.

Leo: "YOU CANNOT HAVE A SINGLE LANE THAT IS UNRELIABLE FOR NIGHTLIES. YOU CANNOT. YOU MUST HAVE MORE."

nightly-next-one builds, signs and publishes the tip on the signer Mac the pick took; nightly-next-hedge
compiles the same tip on the other signer Mac with no signing and no publishing. This step reads both
results, writes a row per signer (role, host, sha, compile result, minutes) to the job summary and to
ROWS_OUT (JSON lines, uploaded as an artifact), and warns when one signer compiled the tree and the
other did not: the same tree red on one Mac and green on the other is a host flake, not a code red.

It never fails: the hedge is advisory and nothing waits on it.

Env: TIP_SHA, PRIMARY_HOST, PRIMARY_COMPILE_RED, PRIMARY_LEFT, PRIMARY_RESULT, HEDGE_HOST, HEDGE_COMPILE,
ROWS_OUT, GITHUB_STEP_SUMMARY; for the minutes, GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_RUN_ID,
GITHUB_RUN_ATTEMPT, GITHUB_API_URL (optional: no minutes without them).
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request
from datetime import datetime

PASS, FAIL, NOT_BUILT = "pass", "fail", "not built"
JOBS = {"primary": "nightly-next-one", "hedge": "nightly-next-hedge"}


def primary_compile(compile_red: str, left: str, result: str) -> str:
    if compile_red == "true":
        return FAIL
    if left == "true" or result in ("", "skipped", "cancelled"):
        return NOT_BUILT
    # A red after the compile (signing, notarizing, publishing) still compiled the tree.
    return PASS


def hedge_compile(value: str) -> str:
    return value if value in (PASS, FAIL) else NOT_BUILT


def split(primary: str, hedge: str) -> bool:
    return {primary, hedge} == {PASS, FAIL}


def minutes(job: dict) -> float | None:
    try:
        start = datetime.fromisoformat(job["started_at"].replace("Z", "+00:00"))
        end = datetime.fromisoformat(job["completed_at"].replace("Z", "+00:00"))
    except (KeyError, TypeError, AttributeError, ValueError):
        return None
    return round((end - start).total_seconds() / 60, 1)


def job_minutes(env: dict) -> dict[str, float | None]:
    """One bounded read of this run's jobs; any failure gives no minutes, never a red."""
    out: dict[str, float | None] = {role: None for role in JOBS}
    token, repo, run = env.get("GITHUB_TOKEN"), env.get("GITHUB_REPOSITORY"), env.get("GITHUB_RUN_ID")
    if not (token and repo and run):
        return out
    api = env.get("GITHUB_API_URL", "https://api.github.com")
    attempt = env.get("GITHUB_RUN_ATTEMPT", "1")
    url = f"{api}/repos/{repo}/actions/runs/{run}/attempts/{attempt}/jobs?per_page=100"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}",
                                               "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            jobs = json.load(resp).get("jobs", [])
    except Exception as err:  # noqa: BLE001 - advisory read
        print(f"no job minutes: {err}", file=sys.stderr)
        return out
    for role, name in JOBS.items():
        for job in jobs:
            if job.get("name") == name:
                out[role] = minutes(job)
                break
    return out


def rows(env: dict, mins: dict[str, float | None]) -> list[dict]:
    sha = env.get("TIP_SHA", "")
    return [
        {"role": "primary", "host": env.get("PRIMARY_HOST", ""), "sha": sha,
         "compile": primary_compile(env.get("PRIMARY_COMPILE_RED", ""), env.get("PRIMARY_LEFT", ""),
                                    env.get("PRIMARY_RESULT", "")),
         "minutes": mins.get("primary")},
        {"role": "hedge", "host": env.get("HEDGE_HOST", ""), "sha": sha,
         "compile": hedge_compile(env.get("HEDGE_COMPILE", "")), "minutes": mins.get("hedge")},
    ]


def summary(table: list[dict], flake: bool) -> str:
    lines = ["### Hedged nightly-next compile", "",
             "| role | signer | sha | compile | minutes |", "| --- | --- | --- | --- | --- |"]
    for r in table:
        m = "" if r["minutes"] is None else f"{r['minutes']}"
        lines.append(f"| {r['role']} | {r['host']} | {r['sha'][:12]} | {r['compile']} | {m} |")
    lines.append("")
    lines.append("**Flake signal:** the two signers disagree on the same tree." if flake
                 else "The signers agree (or one did not build).")
    return "\n".join(lines) + "\n"


def main(env: dict | None = None) -> int:
    env = dict(os.environ) if env is None else env
    table = rows(env, job_minutes(env))
    flake = split(table[0]["compile"], table[1]["compile"])
    for r in table:
        print(json.dumps(r, sort_keys=True))
    if flake:
        print(f"::warning title=nightly-next flake signal::the same tree {table[0]['sha'][:12]} compiled "
              f"{table[0]['compile']} on the primary signer and {table[1]['compile']} on the hedge signer")
    out = env.get("ROWS_OUT")
    if out:
        with open(out, "w", encoding="utf-8") as f:
            for r in table:
                f.write(json.dumps({**r, "flake": flake}, sort_keys=True) + "\n")
    step = env.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a", encoding="utf-8") as f:
            f.write(summary(table, flake))
    return 0


if __name__ == "__main__":
    sys.exit(main())
