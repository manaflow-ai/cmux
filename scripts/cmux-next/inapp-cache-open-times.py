#!/usr/bin/env python3
"""Open-to-content for cmux NEXT's in-app caches, read through the installed app's CLI.

Each case runs the CLI read a surface's open waits on (the daemon or app RPC behind it) --runs
times, one after another, and reports the first run (as cold as the app is now), the median and the
worst. It changes nothing, launches nothing and runs one command at a time, so it may drive the
person's own NIGHTLY at light load (machines/wiki/his-app.md). The same script gives the before and
after number of each move onto the tagged cache.

  python3 inapp-cache-open-times.py [--app "/Applications/cmux NIGHTLY.app"] [--runs 5]
      [--repo DIR] [--json out.json]

A case whose command fails is reported with its exit code and first error line, not timed.
"""
import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import time

DEFAULT_APP = "/Applications/cmux NIGHTLY.app"


def cases(cmux, acpmux, repo):
    # (name, surface, argv, cwd): the read each surface's open waits on today.
    acp = [acpmux] if acpmux else [cmux, "acp"]
    return [
        ("session_info_usage", "Session Info (usage pass over every chat)", acp + ["ls", "-a", "-w", "--machine", "local"], None),
        ("sidebar_sessions", "sidebar session list (first page of 200)",
         acp + ["--json", "ls", "-a", "--machine", "local", "--limit", "200", "--fields", "name,status"], None),
        ("chats_index", "chat index (Home, chats list)", acp + ["chats", "list", "--json", "-n", "200"], None),
        ("workspaces", "workspace list", [cmux, "workspace", "list", "--json"], None),
        ("spaces", "space list", [cmux, "space", "list", "--json"], None),
        ("machines", "host / machine list", [cmux, "app", "machines", "--json"], None),
        ("machines_cached", "host / machine list, no refresh", [cmux, "app", "machines", "--no-refresh", "--json"], None),
        ("models", "model picker (every harness's models)", acp + ["--json", "daemon", "models"], None),
        ("harnesses", "model picker (harness catalog)", acp + ["--json", "daemon", "harnesses"], None),
        ("git_status", "git status (branch badge, changes panel)", [cmux, "git", "status", "--json"], repo),
        ("settings", "settings snapshot", [cmux, "settings", "get", "--json"], None),
    ]


def run_once(argv, cwd, env):
    start = time.monotonic()
    proc = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
    ms = (time.monotonic() - start) * 1000
    return ms, proc


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--app", default=DEFAULT_APP)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--repo", default=os.path.expanduser("~/Projects/leo-workspace"))
    ap.add_argument("--only", action="append", help="case name (repeatable)")
    ap.add_argument("--json")
    opts = ap.parse_args()

    bindir = os.path.join(opts.app, "Contents/Resources/bin")
    cmux = os.path.join(bindir, "cmux")
    if not os.path.exists(cmux):
        sys.exit(f"no cmux CLI at {cmux}")
    acpmux = os.path.join(bindir, "acpmux")
    acpmux = acpmux if os.path.exists(acpmux) else shutil.which("acpmux")
    env = dict(os.environ)
    if "NIGHTLY" in opts.app:
        env["CMUX_BUNDLE_ID"] = "com.cmuxterm.app.nightly"

    version = subprocess.run([cmux, "--version"], env=env, capture_output=True, text=True).stdout.strip()
    layers = subprocess.run([cmux, "customize", "library", "status"], env=env, capture_output=True, text=True)
    print(f"app: {opts.app}\ncli: {version}\nacpmux: {acpmux or 'cmux acp'}")
    print("layers on:\n" + (layers.stdout.strip() or layers.stderr.strip() or "(none)"))

    results = []
    for name, surface, argv, cwd in cases(cmux, acpmux, opts.repo):
        if opts.only and name not in opts.only:
            continue
        if cwd and not os.path.isdir(cwd):
            cwd = None
        times, failure, out_bytes = [], None, 0
        for _ in range(opts.runs):
            try:
                ms, proc = run_once(argv, cwd, env)
            except subprocess.TimeoutExpired:
                failure = "timeout 120 s"
                break
            if proc.returncode != 0:
                first = (proc.stderr.strip() or proc.stdout.strip()).splitlines()[:1]
                failure = f"exit {proc.returncode}: {first[0] if first else ''}"[:200]
                break
            times.append(ms)
            out_bytes = len(proc.stdout)
            time.sleep(0.3)
        row = {"case": name, "surface": surface, "argv": argv[1:], "runs_ms": [round(t, 1) for t in times],
               "first_ms": round(times[0], 1) if times else None,
               "median_ms": round(statistics.median(times), 1) if times else None,
               "max_ms": round(max(times), 1) if times else None, "bytes": out_bytes, "failure": failure}
        results.append(row)
        if failure:
            print(f"{name:20} FAILED  {failure}")
        else:
            print(f"{name:20} first {row['first_ms']:8.1f} ms  median {row['median_ms']:8.1f} ms  "
                  f"max {row['max_ms']:8.1f} ms  {out_bytes} B")
    if opts.json:
        with open(opts.json, "w") as out:
            json.dump({"app": opts.app, "cli": version, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                       "results": results}, out, indent=2)


if __name__ == "__main__":
    main()
