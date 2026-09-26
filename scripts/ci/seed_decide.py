#!/usr/bin/env python3
"""Decide which pools this main push must build a DerivedData seed on.

    seed_decide.py --repository OWNER/REPO --pool POOL=XCODE_APP [--pool ...]
                   [--event-name NAME] [--github-output PATH]

A pool may skip the Mac only when a seed with this push's exact build inputs
already exists for it, because pull requests then adopt that seed by prefix.
Comparing with the parent commit alone assumed the parent had a seed. It often
had none: seed-derived-data.yml never cancels a running seed, so a newer push
replaces the pending run, and the replaced commit is never built. The next push
that changed nothing but docs then skipped too, and main's newest seed stayed
on an older build for as long as such pushes kept arriving. On 2026-09-24, 8 of
22 skips left main 2 to 6 commits past its newest seed with different inputs,
including 80 minutes after #14241 merged.

So for each pool, walk main's first-parent history to the nearest commit whose
seeder run saved that pool's seed, and skip that pool only if that commit's
build inputs, under the pool's own Xcode, equal this one's. Each pool decides
alone: a macOS 15 seed that keeps failing must not make every push rebuild the
macOS 26 seeds too. Anything unknown (API errors, no seeded ancestor within
the window, a commit outside the shallow checkout) builds that pool.

A pool may be a lane `LABEL@K`: the same runners, building in the second (or
Kth) canonical root, /private/tmp/cmux-ci-K. That root is part of the seed
key, so an owned Mac's second compile slot only adopts a seed built there.

Far lanes. A pending seed that a newer push replaces is never built, which is
fine when the newer push is near it, and costly after a change that recompiles
the `cmux` module: on 2026-09-25 main took 271 pushes, 62 to 77% of each pool's
seed jobs were replaced, and admission started p50 6 to 11 commits (14 to 28
app Swift files) behind main. warm_distance.py measured what such a start costs:
within NEAR_APP_SWIFT_FILES app Swift files, with no package interface change
and no hot file, p50 140 s; otherwise p50 401 s. So each pool that builds also
gets a tier, from the nearest ancestor its seed covers (a saved seed, or a seed
job running now, which is never cancelled) to this push, and `far` lists the
pools whose tier is not near. seed-derived-data.yml queues a far seed in a
second concurrency group per pool, so a newer near push never replaces it, and
it starts beside a running near seed instead of behind it. A newer far push
still replaces a pending far one (it holds the same change and more), so each
pool runs at most two seeds and keeps at most two pending. No covering seed
within the window is far; an error computing the tier is near, which is the
single lane of before.

Outputs `pools`, the JSON list of pools to build, in the order given, `matrix`,
the seed job's matrix over them (`pool`, plus `root` for a lane), `build`,
whether that list is empty, and `far`, the JSON list of those pools to seed in
the far lane.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Callable, Iterable, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import warm_distance  # noqa: E402

WORKFLOW = "seed-derived-data.yml"
SEED_JOB = "seed"
SAVE_STEP = "Save seed"
# The decide job checks out this many commits of history, plus HEAD.
ANCESTOR_LIMIT = 30
FINGERPRINT = Path(__file__).resolve().parent / "build_input_fingerprint.py"

Api = Callable[[str], dict]


def gh_api(path: str) -> dict:
    return json.loads(subprocess.check_output(["gh", "api", path], text=True, timeout=20))


def lineage(limit: int = ANCESTOR_LIMIT) -> list[str]:
    """HEAD's first-parent ancestors, nearest first, excluding HEAD."""
    out = subprocess.check_output(
        ["git", "rev-list", "--first-parent", f"--max-count={limit + 1}", "HEAD"], text=True
    )
    return out.split()[1:]


def fingerprint(revision: str, xcode: str) -> str:
    return subprocess.check_output(
        [sys.executable, str(FINGERPRINT), "--revision", revision, "--extra", f"xcode={xcode}"], text=True
    ).strip()


def lane(pool: str) -> dict[str, str]:
    """The seed job's matrix entry for a pool: `LABEL@K` builds in root K."""
    label, separator, root = pool.partition("@")
    if not separator:
        return {"pool": pool}
    if not (root.isdigit() and 2 <= int(root) <= 99 and not root.startswith("0")):
        raise ValueError(f"expected LABEL@<root 2 to 99>, got {pool!r}")
    return {"pool": label, "root": root}


def seed_job_name(pool: str) -> str:
    """GitHub names a matrix job by its entry's values: "seed (<pool>)", or
    "seed (<pool>, <root>)" for a lane."""
    return f"{SEED_JOB} ({', '.join(lane(pool).values())})"


def saved(jobs: Sequence[dict], pool: str) -> bool:
    """Whether one seeder run's job for `pool` finished and saved its seed.

    A pool the run did not build has no job, a pending job may still be
    replaced, and a failed or unsaved one wrote nothing: none of them count,
    so the walk moves past that commit, which can only make a pool build,
    never skip wrongly.
    """
    for job in jobs:
        if job.get("name") != seed_job_name(pool):
            continue
        if job.get("status") != "completed" or job.get("conclusion") != "success":
            return False
        save = next((step for step in job.get("steps", []) if step.get("name") == SAVE_STEP), None)
        return save is not None and save.get("conclusion") == "success"
    return False


def running(jobs: Sequence[dict], pool: str) -> bool:
    """Whether one seeder run's job for `pool` is running: it is never cancelled, so it will save or fail."""
    return any(job.get("name") == seed_job_name(pool) and job.get("status") == "in_progress" for job in jobs)


def warm_tier(ancestor: str) -> str:
    """warm_distance.py's tier of HEAD's tree against ANCESTOR's: near, far or rebuild.

    Unknown package interface changes count as interface changes, as in
    warm_distance.tier; a git failure raises, and the caller keeps the near lane.
    """
    names = subprocess.check_output(
        ["git", "diff", "--name-only", "--no-renames", ancestor, "HEAD"], text=True, timeout=20)
    paths = [path for path in names.splitlines() if warm_distance.app_swift(path)]
    packages = [path for path in paths if warm_distance.package_swift(path)]
    interface = warm_distance.diff_interface(Path.cwd(), ancestor, "HEAD", packages)
    model = warm_distance.load_model()
    hot = model.get("hot_files") or warm_distance.DEFAULT_HOT_FILES
    return warm_distance.tier(warm_distance.features(paths, interface, hot), model)


class Seeds:
    """main's seeder runs, with each run's jobs listed at most once."""

    def __init__(self, api: Api, repository: str) -> None:
        self.api, self.repository = api, repository
        runs = api(f"repos/{repository}/actions/workflows/{WORKFLOW}/runs?branch=main&per_page=100").get(
            "workflow_runs", []
        )
        self.by_sha: dict[str, list[dict]] = {}
        for run in runs:
            self.by_sha.setdefault(run.get("head_sha", ""), []).append(run)
        self.jobs: dict[int, list[dict]] = {}

    def run_jobs(self, run: dict) -> list[dict]:
        if run["id"] not in self.jobs:
            self.jobs[run["id"]] = self.api(
                f"repos/{self.repository}/actions/runs/{run['id']}/jobs?per_page=100").get("jobs", [])
        return self.jobs[run["id"]]

    def nearest(self, pool: str, ancestors: Iterable[str]) -> str | None:
        """The nearest ancestor with a saved seed for `pool`, or None."""
        for sha in ancestors:
            if any(saved(self.run_jobs(run), pool) for run in self.by_sha.get(sha, [])):
                return sha
        return None

    def covering(self, pool: str, ancestors: Iterable[str]) -> str | None:
        """The nearest ancestor whose seed for `pool` is saved or being built now, or None."""
        for sha in ancestors:
            if any(saved(jobs, pool) or running(jobs, pool)
                   for jobs in (self.run_jobs(run) for run in self.by_sha.get(sha, []))):
                return sha
        return None


def decide(
    event_name: str,
    repository: str,
    pools: Sequence[tuple[str, str]],
    api: Api = gh_api,
    ancestors: Callable[[], list[str]] = lineage,
    fingerprint_of: Callable[[str, str], str] = fingerprint,
    tier_of: Callable[[str], str] = warm_tier,
    far: list[str] | None = None,
) -> tuple[list[str], list[str]]:
    """(pools to build, in order, one reason per pool) for (pool, Xcode) pairs.

    FAR, when given, receives the pools to build whose tier from their
    covering seed is not near (the far lane).
    """
    unique: list[tuple[str, str]] = []
    for pool, xcode in pools:
        if pool and pool not in [seen for seen, _ in unique]:
            unique.append((pool, xcode))
    if event_name == "workflow_dispatch":
        return [pool for pool, _ in unique], [f"{pool}: dispatched; building." for pool, _ in unique]
    try:
        seeds = Seeds(api, repository)
        history = ancestors()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError,
            json.JSONDecodeError, KeyError, TypeError, AttributeError) as error:
        return [pool for pool, _ in unique], [f"Could not list seeds ({error}); building every pool."]
    build, reasons = [], []
    for pool, xcode in unique:
        try:
            seed = seeds.nearest(pool, history)
            if seed is None:
                reason, needed = f"no seeded ancestor within {ANCESTOR_LIMIT} commits; building.", True
            elif fingerprint_of("HEAD", xcode) == fingerprint_of(seed, xcode):
                reason, needed = f"build inputs equal those of {seed}, which has its seed; skipping.", False
            else:
                reason, needed = f"build inputs differ from {seed}, its nearest seed; building.", True
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError,
                json.JSONDecodeError, KeyError, TypeError, AttributeError) as error:
            reason, needed = f"could not find its nearest seed ({error}); building.", True
        if needed:
            build.append(pool)
            reason += " " + lane_reason(seeds, pool, history, tier_of, far)
        reasons.append(f"{pool}: {reason}")
    return build, reasons


def lane_reason(seeds: Seeds, pool: str, history: list[str], tier_of: Callable[[str], str],
                far: list[str] | None) -> str:
    """Put POOL in FAR when its tier from its covering seed is not near; say why."""
    try:
        cover = seeds.covering(pool, history)
        tier = "far" if cover is None else tier_of(cover)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError,
            json.JSONDecodeError, KeyError, TypeError, AttributeError) as error:
        return f"Near lane: could not measure the distance ({error})."
    if tier != "near" and far is not None:
        far.append(pool)
    where = f"no seed covers the last {ANCESTOR_LIMIT} commits" if cover is None else f"{tier} from {cover}"
    return f"{'Far' if tier != 'near' else 'Near'} lane: {where}."


def parse_pool(value: str) -> tuple[str, str]:
    pool, separator, xcode = value.partition("=")
    if not separator:
        raise argparse.ArgumentTypeError(f"expected POOL=XCODE_APP, got {value!r}")
    return pool.strip(), xcode.strip()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", required=True)
    parser.add_argument("--pool", type=parse_pool, action="append", required=True)
    parser.add_argument("--event-name", default="push")
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)
    for pool, _ in args.pool:
        if pool:
            lane(pool)
    far: list[str] = []
    build, reasons = decide(args.event_name, args.repository, args.pool, far=far)
    print("\n".join(reasons))
    if args.github_output:
        matrix = {"include": [lane(pool) for pool in build]}
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(f"build={'true' if build else 'false'}\npools={json.dumps(build)}\n"
                         f"matrix={json.dumps(matrix)}\nfar={json.dumps(far)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
