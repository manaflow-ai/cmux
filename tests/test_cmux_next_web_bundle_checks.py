#!/usr/bin/env python3
"""Pull requests into feat-cmux-next run every web bundle and page strings check.

#17241 merged into feat-cmux-next with stale Settings strings and broke the base
for everyone: cmux-next-web-bundles.yml ran only on pushes, and checked neither
the page strings nor the pages bundle that safe-push.sh checks. One script,
scripts/cmux-next/check-web-bundles.sh, now runs the same five checks, and the
workflow runs it on pull requests too.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts/cmux-next/check-web-bundles.sh"
WORKFLOW = ROOT / ".github/workflows/cmux-next-web-bundles.yml"
CHECKS = (
    "scripts/cmux-next/generate-coordination-index.py",
    "webviews/scripts/pages/gen-strings.mjs",
    "scripts/cmux-next/build-pages-web.sh",
    "scripts/build-webviews-app.sh",
    "scripts/cmux-next/build-agent-pane-web.sh",
    "scripts/cmux-next/build-agent-activity-web.sh",
)


def fixture(stale: str | None) -> tuple[Path, Path]:
    """A repository whose five checks log their call; `stale` exits 1 like a stale bundle."""
    repo = Path(tempfile.mkdtemp(prefix="web-bundle-checks-"))
    log = repo / "calls.log"
    (repo / "scripts/cmux-next").mkdir(parents=True)
    shutil.copy(WRAPPER, repo / "scripts/cmux-next/check-web-bundles.sh")
    for check in CHECKS:
        path = repo / check
        path.parent.mkdir(parents=True, exist_ok=True)
        status = 1 if check == stale else 0
        if check.endswith(".py"):
            path.write_text(f"import sys, os\nopen({str(log)!r}, 'a').write('{check} ' + ' '.join(sys.argv[1:]) + ' cwd=' + os.getcwd() + '\\n')\nsys.exit({status})\n")
        elif check.endswith(".mjs"):
            path.write_text(f"import fs from 'node:fs';\nfs.appendFileSync({str(log)!r}, `{check} ${{process.argv.slice(2).join(' ')}} cwd=${{process.cwd()}}\\n`);\nprocess.exit({status});\n")
        else:
            path.write_text(f"#!/bin/sh\necho \"{check} $* cwd=$(pwd)\" >> {log}\nexit {status}\n")
            path.chmod(0o755)
    return repo, log


def run(repo: Path) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "scripts/cmux-next/check-web-bundles.sh"], cwd=repo, capture_output=True,
                          text=True, timeout=60)


def main() -> int:
    failures = []
    if not WRAPPER.exists():
        failures.append(f"{WRAPPER.relative_to(ROOT)} is missing")
    else:
        repo, log = fixture(None)
        try:
            r = run(repo)
            calls = log.read_text()
            if r.returncode != 0:
                failures.append(f"all checks pass but the wrapper failed: {r.stdout}{r.stderr}")
            for check in CHECKS:
                if f"{check} --check" not in calls:
                    failures.append(f"{check} --check did not run: {calls!r}")
            if f"cwd={repo / 'webviews'}" not in calls and f"cwd={(repo / 'webviews').resolve()}" not in calls:
                failures.append(f"gen-strings.mjs must run in webviews/: {calls!r}")
        finally:
            shutil.rmtree(repo, ignore_errors=True)
        # A stale page strings file (the #17241 case) fails, and every other check still runs.
        repo, log = fixture("webviews/scripts/pages/gen-strings.mjs")
        try:
            r = run(repo)
            if r.returncode == 0:
                failures.append("stale page strings passed")
            if "gen-strings.mjs" not in r.stdout + r.stderr:
                failures.append(f"the failure does not name the stale check: {r.stdout}{r.stderr}")
            if "scripts/cmux-next/build-agent-activity-web.sh --check" not in log.read_text():
                failures.append("a failed check stopped the later checks")
        finally:
            shutil.rmtree(repo, ignore_errors=True)

    workflow = yaml.safe_load(WORKFLOW.read_text())
    events = workflow.get("on", workflow.get(True)) or {}
    pr = events.get("pull_request") or {}
    if "feat-cmux-next" not in (pr.get("branches") or []):
        failures.append("cmux-next-web-bundles.yml does not run on pull requests into feat-cmux-next")
    for event in ("push", "pull_request"):
        paths = set((events.get(event) or {}).get("paths") or [])
        for needed in ("schemas/settings/**", "webviews/**", "scripts/cmux-next/build-pages-web.sh",
                       "plans/cmux-next/coordination/**", "scripts/cmux-next/generate-coordination-index.py",
                       "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/**",
                       "scripts/cmux-next/check-web-bundles.sh"):
            if needed not in paths:
                failures.append(f"{event} paths lack {needed}")
    runs = [step.get("run", "") for step in workflow["jobs"]["bundles"]["steps"]]
    if not any("scripts/cmux-next/check-web-bundles.sh" in r for r in runs):
        failures.append("the bundles job does not run scripts/cmux-next/check-web-bundles.sh")

    for failure in failures:
        print("FAIL:", failure)
    if failures:
        return 1
    print("cmux-next web bundle checks: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
