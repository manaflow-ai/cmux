#!/usr/bin/env python3
"""Run the real Sparkle update harness against the bundle failure matrix.

Each case gets its own HOME and output directory. This keeps Sparkle's staged
installation cache, shared preferences, updater log, and acpmux state from
crossing case boundaries while the cases run in parallel.

Example
    python3 -I scripts/cmux-next/update-harness/matrix.py \
        --app '/tmp/cmux DEV build.app' --out /tmp/update-matrix
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import plistlib
from pathlib import Path
import re
import subprocess
import sys
import time
from dataclasses import dataclass


HERE = Path(__file__).resolve().parent
RUNNER = HERE / "run.py"
IDLE_RUNNER = HERE / "idle_e2e.py"
IDLE_VERDICTS = ("installed_v2", "automatic", "waited_idle_time", "hosts_counts_equal",
                 "host_pids_unchanged", "agents_survived", "no_turn_cut")


@dataclass(frozen=True)
class MatrixCase:
    name: str
    flags: tuple[str, ...]
    expected_failure_card: str | None = None
    expected_failure_content: str | None = None
    runner: str = "standard"
    artifact: str = "timeline.json"


CASES = (
    MatrixCase("shared-pref-on-download-on", ("--sparkle-auto",)),
    MatrixCase("shared-pref-on-download-off", ("--sparkle-auto", "--downloads-off")),
    # These rows deliberately exercise the harness's failure path. run.py records the expected
    # card in timeline.json before it exits non-zero because no update can be staged.
    MatrixCase("feed-fault", ("--scenario", "attempt-feed-error", "--stage-timeout", "10"),
               expected_failure_card="check_failed"),
    MatrixCase("transfer-fault", ("--scenario", "attempt-download-error", "--stage-timeout", "10"),
               expected_failure_card="check_failed", expected_failure_content="downloadManually"),
    MatrixCase("staged-corruption", ("--break-staged",)),
    MatrixCase("read-only-install", ("--readonly-install",)),
    MatrixCase("required-update", ("--required-update",)),
    MatrixCase("session-handoff", ("--handoff", "--sessions")),
    MatrixCase("idle-install", ("--expect", "install", "--idle-minutes", "1"),
               runner="idle", artifact="result.json"),
)


def _slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def command(app: Path, out: Path, tag: str, case: MatrixCase) -> list[str]:
    runner = IDLE_RUNNER if case.runner == "idle" else RUNNER
    return [
        sys.executable,
        "-I",
        str(runner),
        "--app",
        str(app),
        "--tag",
        tag,
        "--out",
        str(out),
        *case.flags,
    ]


def case_passed(case: MatrixCase, returncode: int | None, details: dict, error: str | None = None) -> bool:
    if error or returncode is None:
        return False
    if case.expected_failure_card is None:
        if returncode != 0:
            return False
        if case.runner == "idle":
            verdicts = details.get("verdicts", {})
            return details.get("passed") is True and all(verdicts.get(key) is True for key in IDLE_VERDICTS)
        return True
    scenario = details.get("scenario", {})
    status_card = scenario.get("status", {}).get("card")
    status_card_kind = status_card.get("kind") if isinstance(status_card, dict) else status_card
    return (
        returncode != 0
        and status_card_kind == case.expected_failure_card
        and (case.expected_failure_content is None
             or case.expected_failure_content in scenario.get("failure_content", ""))
    )


def run_case(app: Path, root: Path, tag_prefix: str, case: MatrixCase) -> dict:
    case_dir = root / case.name
    case_dir.mkdir(parents=True, exist_ok=True)
    home = case_dir / "home"
    home.mkdir()
    tmpdir = case_dir / "tmp"
    tmpdir.mkdir()
    tag = app_tag(app) if case.runner == "idle" else f"{tag_prefix}-{case.name}"
    argv = command(app, case_dir, tag, case)
    started = time.monotonic()
    try:
        completed = subprocess.run(
            argv,
            cwd=app.parent,
            env={**os.environ, "HOME": str(home), "TMPDIR": str(tmpdir)},
            capture_output=True,
            text=True,
            check=False,
        )
        error = None
    except OSError as exc:
        completed = None
        error = f"could not start harness: {exc}"
    elapsed = round(time.monotonic() - started, 3)
    (case_dir / "stdout.log").write_text(completed.stdout if completed else "", encoding="utf-8")
    (case_dir / "stderr.log").write_text(
        (completed.stderr if completed else "") + (f"\n{error}\n" if error else ""), encoding="utf-8")
    artifact = case_dir / case.artifact
    details = {}
    if artifact.exists():
        try:
            details = json.loads(artifact.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            error = error or f"invalid {case.artifact}: {exc}"
    passed = case_passed(case, completed.returncode if completed else None, details, error)
    return {
        "name": case.name,
        "flags": list(case.flags),
        "tag": tag,
        "command": argv,
        "returncode": completed.returncode if completed else None,
        "passed": passed,
        "error": error,
        "elapsed_seconds": elapsed,
        "timeline": str(artifact) if case.artifact == "timeline.json" and artifact.exists() else None,
        "result": str(artifact) if case.artifact == "result.json" and artifact.exists() else None,
        "stdout": str(case_dir / "stdout.log"),
        "stderr": str(case_dir / "stderr.log"),
    }


def app_tag(app: Path) -> str:
    """Return the tag encoded in the DEV bundle identity required by idle_e2e.py."""
    info_path = app / "Contents" / "Info.plist"
    with info_path.open("rb") as stream:
        bundle_id = plistlib.load(stream).get("CFBundleIdentifier", "")
    prefix = "com.cmuxterm.app.debug."
    if not bundle_id.startswith(prefix) or not bundle_id[len(prefix):]:
        raise ValueError(f"idle matrix row needs a {prefix}<tag> bundle, got {bundle_id!r}")
    return bundle_id[len(prefix):]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="a tagged DEV app bundle")
    parser.add_argument("--out", required=True, type=Path, help="fresh folder for case artifacts")
    parser.add_argument("--parallel", type=int, default=2, help="maximum simultaneous Sparkle runs")
    parser.add_argument("--tag-prefix", default="update-matrix", help="prefix for per-case harness tags")
    parser.add_argument("--only", action="append", choices=[case.name for case in CASES],
                        help="run one or more named rows instead of the full matrix")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    app = args.app.resolve()
    root = args.out.resolve()
    if not app.is_dir() or app.suffix != ".app":
        raise SystemExit(f"--app is not an app bundle: {app}")
    if args.parallel < 1:
        raise SystemExit("--parallel must be at least 1")
    if root.exists() and any(root.iterdir()):
        raise SystemExit(f"--out must be empty: {root}")
    root.mkdir(parents=True, exist_ok=True)
    selected = tuple(case for case in CASES if not args.only or case.name in args.only)
    if not selected:
        raise SystemExit("no matrix rows selected")

    results: list[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.parallel) as pool:
        futures = [pool.submit(run_case, app, root, _slug(args.tag_prefix), case) for case in selected]
        for future in futures:
            results.append(future.result())
    results.sort(key=lambda row: row["name"])

    matrix = {"app": str(app), "parallel": args.parallel, "cases": results,
              "passed": all(row["passed"] for row in results)}
    (root / "matrix.json").write_text(json.dumps(matrix, indent=2) + "\n", encoding="utf-8")
    lines = ["# Sparkle update matrix", "", f"App `{app}`", "", "| Case | Result | Elapsed |", "| --- | --- | ---: |"]
    for row in results:
        lines.append(f"| `{row['name']}` | {'PASS' if row['passed'] else 'FAIL'} | {row['elapsed_seconds']:.3f}s |")
    (root / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps(matrix, indent=2))
    return 0 if matrix["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
