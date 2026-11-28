#!/usr/bin/env python3
"""Shipped iPhone builds against the deployed mobile API (scripts/ci/mobile-old-phones.sh).

A phone on TestFlight keeps its link code until its owner installs a newer build, while the
mobile Worker (cmux-mobile-api-dev, cmux-mobile-api-prod) and the Mac host move on every
deploy and every NIGHTLY. Nothing ran a deployed server, or a new Mac host, against the
phone builds people already have, so a deploy could break shipped phones while CI stayed
green (Leo, 11-27: "so between mac and ios connections something broke").

  resolve  --repo OWNER/REPO [--count 3]   the source commits of the newest TestFlight uploads
  verdict  --dir DIR                       read every leg's dial output, print the table, exit 1 on a failure

`resolve` reads the INTERNAL builder's successful runs (ios-internal-nightly.yml): each run's
title names the feat-cmux-next commit it built and uploaded ("cmux-next-ios INTERNAL <sha>").
It prints one `<sha> <run id> <created>` line per distinct commit, newest first.

`verdict` reads DIR/<mac>/<phone sha>/{pair.out,hold.out,meta.json} as the shell script writes
them and checks four legs per phone build:
  pair     the link comes up over each transport the script asked for
  attach   the Mac's daemon channel answers `identify` ok
  stream   the echo channel moved the bytes asked for
  reconnect the hold leg's link answered a probe after the Mac host restarted, after a redial
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

TITLE = re.compile(r"^cmux-next-ios INTERNAL ([0-9a-f]{40})\b")
LEGS = ("pair", "attach", "stream", "reconnect")


def shipped_commits(runs: list[dict], count: int) -> list[dict]:
    """Newest-first distinct source commits of successful builder runs."""
    seen: set[str] = set()
    out: list[dict] = []
    for run in sorted(runs, key=lambda r: r.get("created_at", ""), reverse=True):
        if run.get("conclusion") != "success":
            continue
        m = TITLE.match(run.get("display_title") or run.get("name") or "")
        if not m or m.group(1) in seen:
            continue
        seen.add(m.group(1))
        out.append({"sha": m.group(1), "run": run.get("id"), "created": run.get("created_at", "")})
        if len(out) == count:
            break
    return out


def runs_request(repo: str, token: str) -> urllib.request.Request:
    """GitHub's API answers 403 to urllib's default "Python-urllib/3.x" agent, so name ours."""
    url = (f"https://api.github.com/repos/{repo}/actions/workflows/ios-internal-nightly.yml/runs"
           "?status=success&per_page=50")
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
               "User-Agent": "cmux-ci-mobile-old-phones/1"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.Request(url, headers=headers)


RETRY_CODES = {403, 429, 500, 502, 503, 504}


# The longest wait for GitHub's quota reset when no earlier list can answer instead. The job's 30 min timeout
# covers it plus the retries.
RESET_WAIT_MAX_S = 20 * 60


def fetch_runs(repo: str, token: str, *, opener=urllib.request.urlopen, sleep=time.sleep, now=time.time,
               waits=(5, 20, 60), reset_wait_max: float = 0) -> list[dict]:
    """Read the shipped phone runs; a 403/429/5xx (a busy repo's token rate limit) retries, and the last
    one names GitHub's own reason instead of a bare traceback. With RESET_WAIT_MAX set, a spent quota
    (x-ratelimit-remaining=0) whose x-ratelimit-reset is that close gets one more read after the reset:
    run 46141489174 had no earlier list to fall back on (the runner's cache is per host) and died 90 s
    in, with the quota due back within the hour."""
    reset_waited = False
    attempt = 0
    while True:
        try:
            with opener(runs_request(repo, token), timeout=30) as r:
                return json.load(r).get("workflow_runs", [])
        except urllib.error.HTTPError as e:
            body = e.read()[:300].decode("utf-8", "replace")
            why = (f"GitHub answered {e.code} for the ios-internal-nightly runs "
                   f"(x-ratelimit-remaining={e.headers.get('x-ratelimit-remaining')}): {body}")
            if e.code not in RETRY_CODES:
                raise SystemExit(f"::error::{why}") from None
            if attempt < len(waits):
                print(f"::warning::{why}; retrying in {waits[attempt]} s", file=sys.stderr)
                sleep(waits[attempt])
                attempt += 1
                continue
            reset = e.headers.get("x-ratelimit-reset", "")
            left = float(reset) - now() if reset.isdigit() else -1
            if (reset_waited or e.headers.get("x-ratelimit-remaining") != "0"
                    or not 0 <= left <= reset_wait_max):
                raise SystemExit(f"::error::{why}") from None
            print(f"::warning::{why}; the quota resets in {int(left)} s, reading again then", file=sys.stderr)
            sleep(left + 5)
            reset_waited = True


def resolve(repo: str, token: str, count: int, cache: Path | None, *, fetch=fetch_runs) -> tuple[list[str], bool]:
    """The phone build lines and whether they are fresh. The repo's token shares one hourly quota with every
    workflow, and runs 46116606886 and 46125947911 died on "API rate limit exceeded for installation"
    (x-ratelimit-remaining=0) after every retry. Builds ship about nightly, so the last list read
    (kept in CACHE, which the workflow carries between runs) answers until the quota resets. The runner's
    cache is per host, so most runs have none: those wait for the reset instead (fetch_runs)."""
    have_old = bool(cache and cache.is_file() and cache.read_text().strip())
    try:
        got = shipped_commits(fetch(repo, token, reset_wait_max=0 if have_old else RESET_WAIT_MAX_S), count)
    except SystemExit as e:
        old = cache.read_text().split("\n") if cache and cache.is_file() else []
        old = [line for line in old if line.strip()]
        if not old:
            raise
        print(f"{e}; using the last list read ({cache}), which may miss a build shipped since",
              file=sys.stderr)
        return old, False
    if len(got) < count:
        print(f"::warning::only {len(got)} shipped phone builds found", file=sys.stderr)
    lines = [f"{g['sha']} {g['run']} {g['created']}" for g in got]
    if cache and lines:
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text("\n".join(lines) + "\n")
    return lines, True


def json_lines(path: Path) -> list[dict]:
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def judge_leg_set(pair_rows: list[dict], hold_rows: list[dict], meta: dict) -> dict[str, str]:
    """One verdict string per leg: 'ok ...' or 'FAIL ...'."""
    want = set(meta.get("transports") or ["webrtc", "wireguard"])
    want_bytes = int(meta.get("bytes") or 0)
    restart_ms = int(meta.get("restart_epoch_ms") or 0)
    by_t = {r.get("transport"): r for r in pair_rows if r.get("transport")}
    v: dict[str, str] = {}

    missing = sorted(t for t in want if t not in by_t or by_t[t].get("error"))
    if missing:
        errs = "; ".join(f"{t}: {(by_t.get(t) or {}).get('error') or 'no link'}" for t in missing)
        v["pair"] = f"FAIL {errs}"
    else:
        v["pair"] = "ok " + ", ".join(f"{t} {by_t[t].get('path')} {by_t[t].get('connect_ms')} ms" for t in sorted(want))

    bad_attach = []
    for t in sorted(want):
        answers = [json.loads(a) for a in (by_t.get(t, {}).get("daemon") or "").splitlines() if a.strip().startswith("{")]
        identify = next((a for a in answers if a.get("id") == 1), None)
        if not (identify and identify.get("ok")):
            bad_attach.append(t)
    v["attach"] = f"FAIL identify did not answer ok over {', '.join(bad_attach)}" if bad_attach else "ok identify"

    bad_stream = [t for t in sorted(want) if int(by_t.get(t, {}).get("echo_bytes") or 0) < want_bytes]
    v["stream"] = (f"FAIL echo moved under {want_bytes} bytes over {', '.join(bad_stream)}" if bad_stream
                   else "ok " + ", ".join(f"{t} {by_t[t].get('echo_mbit_per_s_each_way')} Mbit/s" for t in sorted(want)))

    redials = [r for r in hold_rows if r.get("event") == "redial" and int(r.get("epoch_ms") or 0) >= restart_ms]
    after = [r for r in hold_rows if r.get("event") == "probe" and int(r.get("epoch_ms") or 0) > restart_ms]
    if not restart_ms:
        v["reconnect"] = "FAIL the Mac host was never restarted"
    elif not redials:
        v["reconnect"] = "FAIL no redial after the Mac host restarted"
    elif not after:
        v["reconnect"] = "FAIL no probe answered after the Mac host restarted"
    else:
        back = min(int(r["epoch_ms"]) for r in after) - restart_ms
        v["reconnect"] = f"ok back in {back} ms ({len(redials)} redial)"
    return v


def verdict(root: Path) -> tuple[list[str], bool]:
    lines = ["| API | Mac host | phone build | pair | attach | stream | reconnect |",
             "|---|---|---|---|---|---|---|"]
    failed = False
    cells = sorted(p for p in root.glob("*/*") if p.is_dir())
    if not cells:
        return ["no legs ran"], True
    for cell in cells:
        meta = json.loads((cell / "meta.json").read_text()) if (cell / "meta.json").exists() else {}
        v = judge_leg_set(json_lines(cell / "pair.out"), json_lines(cell / "hold.out"), meta)
        failed |= any(x.startswith("FAIL") for x in v.values())
        lines.append(f"| {meta.get('api', '?')} | {cell.parent.name} {meta.get('mac_sha', '')[:10]} | "
                     f"{cell.name[:10]} ({meta.get('phone_created', '')}) | "
                     + " | ".join(v[leg] for leg in LEGS) + " |")
    return lines, failed


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("resolve")
    r.add_argument("--repo", required=True)
    r.add_argument("--count", type=int, default=3)
    r.add_argument("--cache", help="last list read: written on success, read when GitHub refuses")
    d = sub.add_parser("verdict")
    d.add_argument("--dir", required=True)
    a = ap.parse_args()
    if a.cmd == "resolve":
        lines, fresh = resolve(a.repo, os.environ.get("GH_TOKEN", ""), a.count,
                               Path(a.cache) if a.cache else None)
        if not lines:
            return 1
        print("\n".join(lines))
        out = os.environ.get("GITHUB_OUTPUT")
        if out:
            with open(out, "a") as f:
                f.write(f"fresh={'true' if fresh else 'false'}\n")
        return 0
    lines, failed = verdict(Path(a.dir))
    print("\n".join(lines))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write("### Shipped iPhone builds vs the deployed mobile API\n\n" + "\n".join(lines) + "\n")
    for line in lines:
        if "FAIL" in line:
            print(f"::error::{line}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
