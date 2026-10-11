#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Regenerate every notice file that a GhosttyNextKit pin change needs, in one run.

  ghosttykit_repin.py [--ios-job ID] [--source-archive-run ID] [--cache DIR]

Run it on a Mac (Xcode: nm, llvm-dwarfdump) from a cmux checkout whose HEAD
commit changes the pin in Packages/Shared/CmuxGhosttyKit/Package.swift and the
ghostty-next gitlink to the same revision, after that commit is pushed to a
side branch named ghosttykit-pin/<name> (`SAFE_PUSH_NEW_BRANCH_BASE=feat-cmux-next
safe-push.sh ghosttykit-pin/<name>`). The push starts cmux-next-source-archive.yml,
which uploads the ghostty-next license tree even when its notice checks fail.

Steps (each stops with a message that says what to do):
  1. the pin and the gitlink name the same Ghostty revision; HEAD is on origin
  2. download the pinned GhosttyNextKit zip and check its sha256
  3. the ghostty-next license tree: the cmux-next-source-archive.yml run for
     HEAD (or --source-archive-run), its tree revision = the pin's revision
  4. ios/link-set.json and ghosttykit-macos-link-set.json from the xcframework
  5. a cmux-ci iOS build of HEAD (submitted, or --ios-job to reuse one of a
     commit with the same pin) and
     app_link from its device archive app (ghostty-next source at the pin)
  6. ios/cmux/Settings.bundle/Acknowledgements.plist (generate)
  7. ios_notices.py check-repo
Then commit the four files. A new libintl state also needs lgpl-exceptions.json
(check-repo names it).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ios_notices as ios  # noqa: E402

ROOT = ios.ROOT
REPO = "manaflow-ai/cmux"
WORKFLOW = "cmux-next-source-archive.yml"
ARTIFACT = "cmux-next-source-archive-dry-run"
TREE = "ghostty-next-licenses"
CMUX_CI = Path.home() / ".local/bin/cmux-ci"


class RepinError(Exception):
    pass


def run(*args: str, cwd: Path = ROOT) -> str:
    result = subprocess.run(list(args), cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RepinError(f"`{' '.join(args)}` failed: {(result.stderr or result.stdout).strip()[-600:]}")
    return result.stdout


def check_pin_matches_gitlink(pin: dict, gitlink: str) -> None:
    if gitlink != pin["ghostty_revision"]:
        raise RepinError(
            f"the ghostty-next gitlink is {gitlink[:11]} but GhosttyNextKit pins Ghostty {pin['ghostty_revision'][:11]}: "
            "move both in the same commit (the license tree is built from the gitlink)"
        )


def tree_revision_error(manifest: dict, pin: dict, run_id: str) -> str | None:
    if manifest.get("ghostty_revision") != pin["ghostty_revision"]:
        return (
            f"source-archive run {run_id} has a license tree for Ghostty {str(manifest.get('ghostty_revision'))[:11]}, "
            f"the pin is {pin['ghostty_revision'][:11]}"
        )
    return None


def step(number: int, text: str) -> None:
    print(f"[{number}/7] {text}", flush=True)


def head_state() -> tuple[str, dict]:
    if run("git", "status", "--porcelain", "--untracked-files=no").strip():
        raise RepinError("tracked files have changes: commit the pin change first, then run this")
    head = run("git", "rev-parse", "HEAD").strip()
    pin = ios.ghostty_kit_pin()
    check_pin_matches_gitlink(pin, run("git", "rev-parse", "HEAD:ghostty-next").strip())
    if not run("git", "branch", "-r", "--contains", head).strip():
        raise RepinError(
            f"HEAD {head[:11]} is not on origin: push it as ghosttykit-pin/<name> with "
            "`SAFE_PUSH_NEW_BRANCH_BASE=feat-cmux-next safe-push.sh ghosttykit-pin/<name>`"
        )
    return head, pin


def xcframework(pin: dict, cache: Path) -> Path:
    target = cache / pin["sha256"]
    framework = target / "GhosttyNextKit.xcframework"
    if framework.is_dir():
        return framework
    target.mkdir(parents=True, exist_ok=True)
    zip_path = target / "kit.zip"
    with urllib.request.urlopen(pin["url"]) as response:
        zip_path.write_bytes(response.read())
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    if digest != pin["sha256"]:
        raise RepinError(f"{pin['url']} has sha256 {digest}, Package.swift pins {pin['sha256']}")
    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(target)
    if not framework.is_dir():
        raise RepinError(f"{pin['url']} has no GhosttyNextKit.xcframework at its root")
    return framework


def license_tree(head: str, pin: dict, run_id: str | None, cache: Path) -> Path:
    if run_id is None:
        runs = json.loads(run("gh", "api", f"repos/{REPO}/actions/workflows/{WORKFLOW}/runs?head_sha={head}&per_page=10"))
        finished = [item for item in runs["workflow_runs"] if item["status"] == "completed"]
        if not finished:
            state = runs["workflow_runs"][0]["status"] if runs["workflow_runs"] else "none"
            raise RepinError(
                f"no finished {WORKFLOW} run for {head[:11]} (latest: {state}); it runs on a push to "
                "ghosttykit-pin/<name> or feat-cmux-next: wait for it, or pass --source-archive-run ID"
            )
        run_id = str(finished[0]["id"])
    tree = cache / f"tree-{run_id}" / TREE
    if not (tree / "SOURCE-MANIFEST.json").is_file():
        artifacts = json.loads(run("gh", "api", f"repos/{REPO}/actions/runs/{run_id}/artifacts"))["artifacts"]
        artifact = next((item for item in artifacts if item["name"] == ARTIFACT and not item["expired"]), None)
        if artifact is None:
            raise RepinError(f"run {run_id} has no {ARTIFACT} artifact (expired, or the archive build failed: read the run)")
        zip_path = cache / f"tree-{run_id}.zip"
        with zip_path.open("wb") as out:
            subprocess.run(["gh", "api", f"repos/{REPO}/actions/artifacts/{artifact['id']}/zip"], check=True, stdout=out)
        with zipfile.ZipFile(zip_path) as archive:
            archive.extractall(tree.parent, [name for name in archive.namelist() if name.startswith(TREE + "/")])
        zip_path.unlink()
    error = tree_revision_error(json.loads((tree / "SOURCE-MANIFEST.json").read_text()), pin, run_id)
    if error:
        raise RepinError(error)
    return tree


def ios_build(head: str, job: str | None, cache: Path) -> tuple[str, str, Path]:
    """(job, the commit it built, its artifact). A reused job may be of another commit:
    app-link then checks that this commit pins the same GhosttyNextKit."""
    if job is None:
        receipt = cache / f"ios-{head[:12]}-submit.json"
        output = run(
            str(CMUX_CI), "build", "ios", "--ref", head, "--tag", f"repin-{head[:6]}-v1",
            "--workspace", f"https://github.com/{REPO}/commit/{head}#repin", "--receipt", str(receipt),
        )
        job = json.loads(output.strip().splitlines()[-1])["id"]
        print(f"  submitted cmux-ci iOS job {job} (reuse it with --ios-job {job})", flush=True)
    status = subprocess.run([str(CMUX_CI), "wait", job])
    if status.returncode != 0:
        raise RepinError(f"cmux-ci job {job} did not finish (exit {status.returncode}): `cmux-ci wait {job}` again, never resubmit")
    state = json.loads(run(str(CMUX_CI), "status", job))
    if state.get("state") != "done" or state.get("kind") != "ios":
        raise RepinError(f"cmux-ci job {job} is a {state.get('kind')} job in state {state.get('state')}, not a finished iOS build")
    artifact = cache / f"ios-{job}.zip"
    if not artifact.is_file():
        run(str(CMUX_CI), "artifact", job, str(artifact))
    return job, state["ref"], artifact


def ghostty_source(pin: dict, cache: Path) -> Path:
    source = cache / f"ghostty-next-{pin['ghostty_revision'][:12]}"
    if not (source / ".git").is_dir():
        source.mkdir(parents=True, exist_ok=True)
        run("git", "init", "-q", ".", cwd=source)
        run("git", "fetch", "-q", "--depth", "1", "https://github.com/manaflow-ai/ghostty-next.git", pin["ghostty_revision"], cwd=source)
        run("git", "checkout", "-q", "FETCH_HEAD", cwd=source)
    return source


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ios-job", help="reuse this cmux-ci iOS job of HEAD instead of submitting one")
    parser.add_argument("--source-archive-run", help="the cmux-next-source-archive.yml run whose license tree to use")
    parser.add_argument("--cache", type=Path, default=Path.home() / ".cache/cmux-ghosttykit-repin")
    args = parser.parse_args(argv)
    args.cache.mkdir(parents=True, exist_ok=True)
    try:
        step(1, "pin, gitlink and origin")
        head, pin = head_state()
        step(2, f"GhosttyNextKit {pin['sha256'][:12]} (Ghostty {pin['ghostty_revision'][:11]})")
        framework = xcframework(pin, args.cache)
        step(3, "ghostty-next license tree from cmux-next-source-archive.yml")
        tree = license_tree(head, pin, args.source_archive_run, args.cache)
        manifest = tree / "SOURCE-MANIFEST.json"
        step(4, "link sets (iOS ios-arm64, macOS universal)")
        if ios.main(["link-set", "--xcframework", str(framework), "--manifest", str(manifest)]) or ios.main(
            ["macos-link-set", "--xcframework", str(framework), "--manifest", str(manifest)]
        ):
            raise RepinError("link set generation failed (see above)")
        step(5, "app_link from a cmux-ci iOS build of HEAD")
        job, built, artifact = ios_build(head, args.ios_job, args.cache)
        if ios.main(
            ["app-link", "--xcframework", str(framework), "--artifact", str(artifact), "--job", job, "--source-commit", built,
             "--ghostty-source", str(ghostty_source(pin, args.cache)), "--manifest", str(manifest)]
        ):
            raise RepinError("app-link failed (see above)")
        step(6, "Acknowledgements pane")
        if ios.main(["generate", "--ghostty-tree", str(tree)]):
            raise RepinError("generate failed (see above)")
        step(7, "check-repo")
        if ios.main(["check-repo"]):
            raise RepinError("check-repo failed (see above)")
    except (RepinError, ios.NoticeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("done: commit scripts/cmux-next/notices/ios/link-set.json, scripts/cmux-next/notices/ghosttykit-macos-link-set.json "
          "and ios/cmux/Settings.bundle/Acknowledgements.plist")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
