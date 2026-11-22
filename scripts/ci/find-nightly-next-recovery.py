#!/usr/bin/env python3
"""List earlier nightly-next runs whose notarization is still pending.

A published nightly-next build whose notarization wait ran out leaves the
recovery artifact cmux-nightly-notarization-recovery-arm64-<short sha>. This
prints, as a JSON list newest first, the earlier completed nightly.yml runs on
branch nightly-next that still hold one, up to --limit of them. A run qualifies
only while its build (run id and two-digit attempt, as build-nightly-app
numbers it) is above every build on every --feed: nightly-next never publishes
a build below one either feed already offers. Run ids only grow, so the first
run that is not above them ends the search.

Usage: find-nightly-next-recovery.py --repo OWNER/NAME --current-run-id ID
           --feed URL_OR_PATH [--feed ...] [--limit N]
Reads the runs and their artifacts with `gh api`; an unreadable feed fails.

       find-nightly-next-recovery.py check-manifest MANIFEST --run-id ID
           --channel CHANNEL --release-tag TAG --dmg-dir DIR
checks a downloaded recovery manifest against the run it came from and the
exact DMG next to it, and prints shell-quoted KEY=value lines (BUILD,
BUILD_SHA, TIP_SHA, BEHIND, BEHIND_HOURS, SUBMISSION_ID, STATE_NAME,
APP_NAME, DMG_NAME, IMMUTABLE_NAME) for the recovery job to source. A
manifest from before the build commit was recorded is refused.
"""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys

RECOVERY_PREFIX = "cmux-nightly-notarization-recovery-arm64-"
PUBLISHED_EVENTS = {"push", "schedule", "workflow_dispatch"}


def load_nightly_version():
    path = Path(__file__).with_name("nightly_version.py")
    spec = importlib.util.spec_from_file_location("nightly_version", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def gh_api(path):
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"gh api {path} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def safe_relative(value, what):
    path = PurePosixPath(value or "")
    if not value or path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"recovery manifest {what} is not a relative path: {value!r}")
    return str(path)


def check_manifest(argv):
    parser = argparse.ArgumentParser(prog="find-nightly-next-recovery.py check-manifest")
    parser.add_argument("manifest")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--dmg-dir", required=True)
    args = parser.parse_args(argv)
    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    expected = {
        "schema": 1,
        "track": "nightly-next",
        "variant": "arm64",
        "should_publish": True,
        "source_run_id": args.run_id,
        "channel": args.channel,
        "release_tag": args.release_tag,
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise SystemExit(f"recovery manifest {key} is {manifest.get(key)!r}, not {value!r}")
    for key in ("build_sha", "tip_sha"):
        if not re.fullmatch(r"[0-9a-f]{40}", manifest.get(key) or ""):
            raise SystemExit(f"recovery manifest has no {key} (written before the build commit was recorded)")
    for key in ("build", "behind", "behind_hours"):
        if not re.fullmatch(r"[0-9]+(\.[0-9]+)?" if key == "behind_hours" else r"[0-9]+", str(manifest.get(key) or "")):
            raise SystemExit(f"recovery manifest {key} is not a number: {manifest.get(key)!r}")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", manifest.get("submission_id") or ""):
        raise SystemExit("recovery manifest has no valid Apple submission id")
    dmg_name = safe_relative(manifest.get("dmg_path"), "dmg_path")
    dmg = Path(args.dmg_dir) / dmg_name
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest() if dmg.is_file() else None
    if digest != manifest.get("dmg_sha256"):
        raise SystemExit(f"{dmg} is not the submitted DMG (SHA-256 {digest}, manifest {manifest.get('dmg_sha256')})")
    values = {
        "BUILD": str(manifest["build"]),
        "BUILD_SHA": manifest["build_sha"],
        "TIP_SHA": manifest["tip_sha"],
        "BEHIND": str(manifest["behind"]),
        "BEHIND_HOURS": str(manifest["behind_hours"]),
        "SUBMISSION_ID": manifest["submission_id"],
        "STATE_NAME": safe_relative(manifest.get("state_path"), "state_path"),
        "APP_NAME": safe_relative(manifest.get("app_path"), "app_path"),
        "DMG_NAME": dmg_name,
        "IMMUTABLE_NAME": PurePosixPath(manifest.get("immutable_path") or "").name,
    }
    if not values["IMMUTABLE_NAME"].endswith(".dmg"):
        raise SystemExit(f"recovery manifest immutable_path is not a DMG: {manifest.get('immutable_path')!r}")
    for key, value in values.items():
        print(f"{key}={shlex.quote(value)}")
    return 0


def main(argv):
    if argv[:1] == ["check-manifest"]:
        return check_manifest(argv[1:])
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--current-run-id", required=True, type=int)
    parser.add_argument("--feed", action="append", required=True)
    parser.add_argument("--limit", type=int, default=3)
    args = parser.parse_args(argv)

    nightly_version = load_nightly_version()
    try:
        highest = max(
            (max(nightly_version.feed_builds(nightly_version.read_feed(source)), default=0) for source in args.feed),
            default=0,
        )
    except nightly_version.Refused as error:
        print(f"find-nightly-next-recovery: {error}", file=sys.stderr)
        return 1

    runs = gh_api(
        f"repos/{args.repo}/actions/workflows/nightly.yml/runs?branch=nightly-next&status=completed&per_page=50"
    )["workflow_runs"]
    runs = [
        run
        for run in runs
        if run["id"] < args.current_run_id
        and run.get("head_branch") == "nightly-next"
        and run.get("event") in PUBLISHED_EVENTS
        and run.get("path", "").split("@")[0] == ".github/workflows/nightly.yml"
        and (run.get("head_repository") or {}).get("full_name") == args.repo
    ]
    found = []
    for run in sorted(runs, key=lambda run: run["id"], reverse=True):
        build = f"{run['id']}{int(run.get('run_attempt') or 1):02d}"
        if int(build) <= highest:
            print(f"run {run['id']}: build {build} is not above the feeds' {highest}; stopping", file=sys.stderr)
            break
        live = [
            artifact["name"]
            for artifact in gh_api(f"repos/{args.repo}/actions/runs/{run['id']}/artifacts?per_page=100")["artifacts"]
            if artifact["name"].startswith(RECOVERY_PREFIX) and not artifact.get("expired")
        ]
        if not live:
            continue
        found.append(
            {
                "run_id": run["id"],
                "run_attempt": int(run.get("run_attempt") or 1),
                "build": build,
                "head_sha": run["head_sha"],
                "artifact": live[0],
            }
        )
        if len(found) >= args.limit:
            break
    print(json.dumps(found))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
