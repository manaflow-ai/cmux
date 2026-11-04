#!/usr/bin/env python3
"""Stage an outer DMG submission as an exact recovery artifact.

An outer submission is a DMG that a continuation job submitted and could not
finish within its bounded wait: the outer DMG around a helper-finished app
(resume-helper-notarization.sh, state <outer-state>.first) or the DMG around
the stapled app (resume-stapled-app-notarization.sh, state with
stapled_app=true). The artifact has the canonical schema 1 manifest that
resolve-notarization-recovery.py reads, the state and log under their
canonical names, the DMG the state names under the release name, and an
archive of the app as it is now (helper finished, stapled). For a stapled-app
state it also keeps the accepted first DMG (<state DMG>.first.dmg, checked
against first_dmg_sha256) as <release>.first.dmg, for the 6 h fallback, and
requires the recorded submit time (stapled_submitted_at).

usage: stage-outer-notarization-recovery.py <source-manifest> <state> <release-dmg> <app>
       <recovery-dir> [--metadata-dir DIR] [--require-stapled-app] --source-run-id ID
       --head-sha SHA --run-attempt N --channel C --variant V --release-tag T
       --dmg-prefix P --short-sha S [--dmg DMG] [--log LOG]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


def read_state(path: Path) -> dict[str, str]:
    state: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if not sep or key in state:
            raise SystemExit(f"invalid outer state line: {line!r}")
        state[key] = value
    return state


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_manifest", type=Path)
    parser.add_argument("state", type=Path)
    parser.add_argument("release_dmg", type=Path)
    parser.add_argument("app", type=Path)
    parser.add_argument("recovery_dir", type=Path)
    parser.add_argument("--metadata-dir", type=Path)
    parser.add_argument("--require-stapled-app", action="store_true")
    # A state from a recovery artifact names a DMG and log on another runner.
    parser.add_argument("--dmg", type=Path, help="the DMG of the state (default: its dmg_path)")
    parser.add_argument("--log", type=Path, help="the evidence log of the state (default: <state>.log)")
    for name in ("source-run-id", "head-sha", "run-attempt", "channel", "variant", "release-tag", "dmg-prefix", "short-sha"):
        parser.add_argument(f"--{name}", required=True)
    args = parser.parse_args()

    original = json.loads(args.source_manifest.read_text(encoding="utf-8"))
    state = read_state(args.state)
    submission_id = state.get("submission_id", "")
    if not submission_id or not all(ch.isalnum() or ch in "._-" for ch in submission_id):
        raise SystemExit("outer state has no valid Apple submission id")
    stapled_app = state.get("stapled_app") == "true"
    if args.require_stapled_app and not stapled_app:
        raise SystemExit("outer state is not the DMG around the stapled app (stapled_app=true)")
    log = args.log or Path(f"{args.state}.log")
    if not log.is_file() or log.stat().st_size == 0:
        raise SystemExit(f"outer state has no evidence log: {log}")
    dmg = args.dmg or Path(state.get("dmg_path", ""))
    if dmg.name != args.release_dmg.name or not dmg.is_file():
        raise SystemExit(f"outer state names no DMG with the release name: {dmg}")
    digest = sha256(dmg)
    if state.get("dmg_sha256", "").lower() != digest:
        raise SystemExit("outer state SHA-256 does not match its DMG")
    first = Path(f"{dmg}.first.dmg")
    if stapled_app:
        if not state.get("stapled_submitted_at", "").isdigit():
            raise SystemExit("stapled-app state records no submit time (stapled_submitted_at)")
        first_id = state.get("first_submission_id", "")
        if not first_id or not all(ch.isalnum() or ch in "._-" for ch in first_id):
            raise SystemExit("stapled-app state records no first submission id")
        if not first.is_file() or sha256(first) != state.get("first_dmg_sha256", "").lower():
            raise SystemExit(f"the accepted first DMG is missing or does not match its record: {first}")
    if not (args.app / "Contents").is_dir():
        raise SystemExit(f"app not found: {args.app}")

    canonical_state = f"{dmg.name}.notarization.state"
    canonical_log = f"{dmg.name}.notarization.log"
    manifest = {
        "schema": 1,
        "source_run_id": args.source_run_id,
        "source_run_attempt": args.run_attempt,
        "should_publish": True,
        "head_sha": args.head_sha,
        "short_sha": args.short_sha,
        "channel": args.channel,
        "variant": args.variant,
        "release_tag": args.release_tag,
        "dmg_prefix": args.dmg_prefix,
        "build": original["build"],
        "dmg_path": dmg.name,
        "immutable_path": Path(state["immutable_path"]).name,
        "app_path": original["app_path"],
        "app_archive_path": original["app_archive_path"],
        "state_path": canonical_state,
        "log_path": canonical_log,
        "dmg_sha256": digest,
        "submission_id": submission_id,
    }
    targets = [args.recovery_dir] + ([args.metadata_dir] if args.metadata_dir else [])
    for directory in targets:
        directory.mkdir(parents=True, exist_ok=True)
        directory.joinpath("cmux-nightly-notarization-recovery.json").write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        shutil.copyfile(args.state, directory / canonical_state)
        shutil.copyfile(log, directory / canonical_log)
    shutil.copyfile(dmg, args.recovery_dir / dmg.name)
    if stapled_app:
        # The accepted, stapled first DMG: it ships at the 6 h fallback.
        shutil.copyfile(first, args.recovery_dir / f"{dmg.name}.first.dmg")
    # The app as it is now: a helper-finished app has a new seal, and the
    # archive in the source artifact is the app from before that.
    archive = args.recovery_dir / original["app_archive_path"]
    subprocess.run(
        ["tar", "-C", str(args.app.parent), "-czf", str(archive), args.app.name],
        check=True,
    )
    print(f"Staged outer submission {submission_id} ({'stapled app' if stapled_app else 'outer DMG'})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
