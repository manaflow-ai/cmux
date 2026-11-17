#!/usr/bin/env python3
"""Replays recent merged pull requests through the base's crate-graph job router and this tree's.

    affected_jobs_replay.py [--base-ref HEAD^1] [--limit 30] [--minutes FILE] [--json OUT]

Each of the last LIMIT first-parent commits of BASE_REF on feat-cmux-next is one merged pull request (a squash
merge): its change is COMMIT^1..COMMIT, and both routers read the crate graph from that commit's tree, as the
pull request's own run did. The old router is BASE_REF's scripts/ci/affected_jobs.py with its map; a base without
one counts every job as run (the path filters that came before ran them on nearly every cmux-tui change). The new
router is this tree's.

It prints, per job, how many of the pull requests each router runs it on, which ones changed, and, with --minutes
(a JSON object of job id -> minutes per run), the job-minutes each spends over the window. It fails when the new
router raises on a commit, or skips a job on a pull request that changes a file inside one of the job's own crates
(a routing that drops the crate a job tests is broken whatever the graph says).

cmux-tui-spec.yml's router-replay job runs it when a pull request changes the router (affected_jobs.py SELF).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ROUTER_FILES = ("affected_jobs.py", "cargo_test_verdict.py", "git_tree.py", "test_reds.py")


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout


def load_router(directory: Path, name: str):
    """affected_jobs.py from DIRECTORY with its own cargo_test_verdict and git_tree."""
    saved = {mod: sys.modules.pop(mod) for mod in ("cargo_test_verdict", "git_tree", "test_reds") if mod in sys.modules}
    sys.path.insert(0, str(directory))
    try:
        spec = importlib.util.spec_from_file_location(name, directory / "affected_jobs.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.path.remove(str(directory))
        for mod in ("cargo_test_verdict", "git_tree", "test_reds"):
            sys.modules.pop(mod, None)
        sys.modules.update(saved)
    return module


def base_router(ref: str, scratch: Path):
    """BASE_REF's router and map text, or (None, None) when that commit has no router."""
    try:
        map_text = git("show", f"{ref}:scripts/ci/affected-jobs.json")
        for name in ROUTER_FILES:
            (scratch / name).write_text(git("show", f"{ref}:scripts/ci/{name}"))
    except subprocess.CalledProcessError:
        return None, None
    return load_router(scratch, "affected_jobs_base"), map_text


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base-ref", default="HEAD^1")
    parser.add_argument("--limit", type=int, default=30)
    parser.add_argument("--minutes", type=Path, help="JSON object: job id -> minutes one run of it takes")
    parser.add_argument("--json", type=Path, help="write every commit's routes here")
    args = parser.parse_args(argv)

    new = load_router(HERE, "affected_jobs_new")
    new_map = (ROOT / "scripts/ci/affected-jobs.json").read_text()
    minutes = json.loads(args.minutes.read_text()) if args.minutes else {}
    commits = git("log", "--first-parent", "--format=%H", args.base_ref, "-n", str(args.limit)).split()
    _, jobs = new.load_map(new_map)
    ids = [job.id for job in jobs]
    totals = {job_id: {"old": 0, "new": 0, "added": 0, "dropped": 0} for job_id in ids}
    rows, failures = [], []
    with tempfile.TemporaryDirectory() as tmp:
        old, old_map = base_router(args.base_ref, Path(tmp))
        for sha in commits:
            try:
                changed = [p for p in git("diff", "--no-renames", "--name-only", f"{sha}^1", sha).splitlines() if p]
            except subprocess.CalledProcessError:
                continue  # the window's oldest commit's parent is outside a shallow clone
            with new.git_tree.GitTree(ROOT, sha) as tree, new.git_tree.GitTree(ROOT, f"{sha}^1") as base_tree:
                try:
                    after = new.route(tree, changed, map_text=new_map, base_tree=base_tree)
                except Exception as why:  # noqa: BLE001 - any raise is the finding
                    failures.append(f"{sha[:12]}: the new router raised {type(why).__name__}: {why}")
                    continue
            run_new = {key[1]: value for key, value in after.run.items()}
            if old is None:
                run_old = {job_id: True for job_id in ids}
            else:
                with old.git_tree.GitTree(ROOT, sha) as tree, old.git_tree.GitTree(ROOT, f"{sha}^1") as base_tree:
                    try:
                        before = old.route(tree, changed, map_text=old_map, base_tree=base_tree)
                    except TypeError:  # a base router from before base_tree
                        before = old.route(tree, changed, map_text=old_map)
                run_old = {key[1]: value for key, value in before.run.items()}
            for job in jobs:
                was, now = run_old.get(job.id, True), run_new[job.id]
                totals[job.id]["old"] += was
                totals[job.id]["new"] += now
                totals[job.id]["added"] += now and not was
                totals[job.id]["dropped"] += was and not now
                own = [p for p in changed if any(new.under(p, crate) for crate in job.crates)]
                if own and not now:
                    failures.append(f"{sha[:12]}: {job.id} skipped although {own[0]} is in its own crate")
            rows.append({"sha": sha, "files": len(changed), "old": run_old, "new": run_new,
                         "everything": after.everything})
            print(f"{sha[:12]} {len(changed):4} files  old {''.join('x' if run_old.get(i, True) else '.' for i in ids)}"
                  f"  new {''.join('x' if run_new[i] else '.' for i in ids)}  {after.everything[:70]}", flush=True)

    n = len(rows)
    print(f"\n{n} merged pull requests ({args.base_ref}, newest first); jobs: {', '.join(ids)}")
    print("| job | old router runs it | new router runs it | added | dropped | old min | new min |")
    print("|---|---|---|---|---|---|---|")
    for job_id, t in totals.items():
        per = minutes.get(job_id)
        cost = (f"| {t['old'] * per:.0f} | {t['new'] * per:.0f} |" if per else "| - | - |")
        print(f"| {job_id} | {t['old']}/{n} | {t['new']}/{n} | {t['added']} | {t['dropped']} {cost}")
    if args.json:
        args.json.write_text(json.dumps({"rows": rows, "totals": totals}, indent=1))
    for failure in failures:
        print(f"::error::{failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
