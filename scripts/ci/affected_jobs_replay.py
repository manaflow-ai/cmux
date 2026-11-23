#!/usr/bin/env python3
"""Replays recent merged pull requests through the base's crate-graph job router and this tree's.

    affected_jobs_replay.py [--base-ref HEAD^1] [--limit 30] [--minutes FILE] [--json OUT]

Each of the last LIMIT first-parent commits of BASE_REF on feat-cmux-next is one merged pull request (a squash
merge): its change is COMMIT^1..COMMIT, and both routers read the crate graph from that commit's tree, as the
pull request's own run did. The old router is BASE_REF's scripts/ci/affected_jobs.py with its map; a base without
one counts every job as run (the path filters that came before ran them on nearly every cmux-tui change). The new
router is this tree's.

It also replays the gates that ran before the router (gates_before_router): each workflow's `paths:` trigger at
BASE_REF, then the spec jobs' own scope steps (cargo_test_verdict.touches and the protocol IR and carrier greps), so
"before" is what feat-cmux-next really ran, not every job. A job the router skips where those gates ran it is listed
by commit: each is a skip to audit, the only place a false skip the old gates did not have can hide.

It prints, per job, how many of the pull requests each router runs it on, which ones changed, and, with --minutes
(a JSON object of job id -> minutes per run), the job-minutes each spends over the window. It fails when the new
router raises on a commit, or skips a job on a pull request that changes a file inside one of the job's own crates
(a routing that drops the crate a job tests is broken whatever the graph says); for a binaries_only job a crate's
tests/, benches/ and examples/ are not part of it (own_crate_changes).

cmux-tui-spec.yml's router-replay job runs it when a pull request changes the router (affected_jobs.py SELF).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
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
        # @dataclass resolves its module through sys.modules while the class body runs.
        sys.modules[name] = module
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


SPEC = ".github/workflows/cmux-tui-spec.yml"
# The scope steps cmux-tui-spec.yml's jobs ran before the router (feat-cmux-next e178066170d8).
PROTOCOL_IR = re.compile(r"^(cmux-tui/(crates/acpmux/|Cargo\.(toml|lock)$|rust-toolchain(\.toml)?$|\.cargo/)"
                         r"|\.github/workflows/cmux-tui-spec\.yml$|\.github/actions/setup-cmux-tui-rust/"
                         r"|\.github/actions/runner-cargo-home/)")
CARRIER = re.compile(r"^(cmux-tui/crates/(cmux-link|cmux-relay|cmux-tui/src/carrier)/|\.github/workflows/cmux-tui-spec\.yml$)")


def gates_before_router(router, tree, changed: list[str], ref: str, jobs) -> dict[str, bool]:
    """Whether each job ran its tests under the gates before the router, at REF's workflows: its workflow's `paths:`
    trigger (cmux-tui-spec.yml: the push paths its changes job reads), then the spec jobs' scope steps."""
    verdict = router.cargo_test_verdict

    def touches(crate: str) -> bool:
        dirs, files = verdict.crate_inputs(ROOT, crate, tree)
        always = verdict.ALWAYS + verdict.READ_AT_TEST_TIME.get(crate, ())
        prefixes = tuple(f"{d}/" for d in dirs) + tuple(p for p in always if p.endswith("/"))
        exact = set(files) | {p for p in always if not p.endswith("/")}
        return any(path in exact or path.startswith(prefixes) for path in changed)

    started: dict[str, bool] = {}
    for workflow in {job.workflow for job in jobs}:
        try:
            text = git("show", f"{ref}:{workflow}")
        except subprocess.CalledProcessError:
            started[workflow] = True
            continue
        globs = router.workflow_paths(text, "push" if workflow == SPEC else "pull_request")
        started[workflow] = globs is None or any(router.glob_matches(g, p) for g in globs for p in changed)
    ran = {}
    for job in jobs:
        on = started[job.workflow]
        if on and job.id in ("acpmux-tests", "acpmux-sim"):
            on = touches("cmux-tui/crates/acpmux")
        elif on and job.id == "acpmux-protocol-ir":
            on = any(PROTOCOL_IR.match(p) for p in changed)
        elif on and job.id == "carrier-sim":
            on = touches("cmux-tui/crates/cmux-remote") or any(CARRIER.match(p) for p in changed)
        ran[job.id] = on
    return ran


def own_crate_changes(router, job, changed: list[str]) -> list[str]:
    """The changed paths inside one of JOB's own crates, as the job uses them: a binaries_only job (cmux-next.yml's
    daemon-test runs the published binaries) builds no test, bench or example of its crates, so a change under a
    crate's tests/, benches/ or examples/ is not its own (cmux#50031: a cmux-tui stage test). Every other path under
    the crate, src/ and the manifest included, still is."""
    unbuilt = router.cargo_test_verdict.UNBUILT_TARGET_DIRS if job.binaries_only else ()
    own = []
    for path in changed:
        for crate in job.crates:
            if router.under(path, crate):
                rest = path[len(crate.rstrip("/")) + 1:]
                if "/" in rest and rest.split("/", 1)[0] in unbuilt:
                    continue
                own.append(path)
                break
    return own


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
    totals = {job_id: {"old": 0, "new": 0, "added": 0, "dropped": 0, "gates": 0, "gates_dropped": 0}
              for job_id in ids}
    dropped_from_gates: list[str] = []
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
                try:
                    run_gates = gates_before_router(new, tree, changed, args.base_ref, jobs)
                except new.git_tree.Unreadable:
                    run_gates = {job_id: True for job_id in ids}  # the old scope steps ran the tests then too
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
                totals[job.id]["gates"] += run_gates[job.id]
                if run_gates[job.id] and not now:
                    totals[job.id]["gates_dropped"] += 1
                    dropped_from_gates.append(f"{sha[:12]} {job.id}: {after.why[job.workflow, job.id]}")
                totals[job.id]["old"] += was
                totals[job.id]["new"] += now
                totals[job.id]["added"] += now and not was
                totals[job.id]["dropped"] += was and not now
                own = own_crate_changes(new, job, changed)
                if own and not now:
                    failures.append(f"{sha[:12]}: {job.id} skipped although {own[0]} is in its own crate")
            rows.append({"sha": sha, "files": len(changed), "old": run_old, "new": run_new, "gates": run_gates,
                         "everything": after.everything})
            print(f"{sha[:12]} {len(changed):4} files  old {''.join('x' if run_old.get(i, True) else '.' for i in ids)}"
                  f"  new {''.join('x' if run_new[i] else '.' for i in ids)}  {after.everything[:70]}", flush=True)

    n = len(rows)
    print(f"\n{n} merged pull requests ({args.base_ref}, newest first); jobs: {', '.join(ids)}")
    print("| job | gates before the router | old router runs it | new router runs it | added | dropped "
          "| dropped vs gates | gates min | new min |")
    print("|---|---|---|---|---|---|---|---|---|")
    for job_id, t in totals.items():
        per = minutes.get(job_id)
        cost = (f"| {t['gates'] * per:.0f} | {t['new'] * per:.0f} |" if per else "| - | - |")
        print(f"| {job_id} | {t['gates']}/{n} | {t['old']}/{n} | {t['new']}/{n} | {t['added']} | {t['dropped']} "
              f"| {t['gates_dropped']} {cost}")
    if dropped_from_gates:
        print("\nSkipped by the router where the gates before it ran the job (audit each):")
        print("".join(f"- {line}\n" for line in dropped_from_gates), end="")
    if args.json:
        args.json.write_text(json.dumps({"rows": rows, "totals": totals}, indent=1))
    for failure in failures:
        print(f"::error::{failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
