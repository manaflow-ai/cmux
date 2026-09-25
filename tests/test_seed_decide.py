#!/usr/bin/env python3
"""A main push skips the seed build only when a seed with its inputs exists."""
from pathlib import Path
import sys
import unittest
import unittest.mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import seed_decide  # noqa: E402

REPO = "manaflow-ai/cmux"


def run(run_id, sha, status="completed", conclusion="success"):
    return {"id": run_id, "head_sha": sha, "status": status, "conclusion": conclusion}


def seed_job(conclusion="success", status="completed", saved=True, pool="blacksmith-12vcpu-macos-26"):
    # The seed job is a matrix over pools, so GitHub names it "seed (<pool>)".
    steps = [{"name": "Save seed", "conclusion": "success" if saved else "skipped"}]
    return {"name": f"seed ({pool})", "status": status, "conclusion": conclusion, "steps": steps}


class Api:
    def __init__(self, runs, jobs):
        self.runs, self.jobs, self.calls = runs, jobs, []

    def __call__(self, path):
        self.calls.append(path)
        if "/workflows/" in path:
            return {"workflow_runs": self.runs}
        run_id = int(path.split("/runs/")[1].split("/")[0])
        return {"jobs": self.jobs.get(run_id, [])}


LARGE, SMALL, OLD = "blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26", "blacksmith-6vcpu-macos-15"
POOLS = [(LARGE, "Xcode.app"), (SMALL, "Xcode.app"), (OLD, "Xcode-15.app")]


def decide(api, ancestors, prints, event="push", pools=((LARGE, "Xcode.app"),)):
    """Pools to build; `prints` maps a revision, or (revision, xcode), to its fingerprint."""
    return seed_decide.decide(
        event, REPO, list(pools), api=api,
        ancestors=lambda: ancestors,
        fingerprint_of=lambda revision, xcode: prints.get((revision, xcode), prints.get(revision)),
    )


class Decide(unittest.TestCase):
    def test_a_replaced_parent_with_other_inputs_does_not_let_a_docs_push_skip(self):
        # p1 changed the app but its pending run was replaced; p2 is seeded.
        api = Api([run(3, "p1", conclusion="cancelled"), run(2, "p2")], {2: [seed_job()]})
        build, reasons = decide(api, ["p1", "p2"], {"HEAD": "app-v2", "p1": "app-v2", "p2": "app-v1"})
        self.assertEqual(build, [LARGE], reasons)
        self.assertIn("p2", reasons[0])

    def test_each_pool_decides_alone(self):
        # The macOS 15 seed keeps failing; the macOS 26 pools saved theirs, so
        # only macOS 15 builds again, not all three.
        jobs = {2: [seed_job(), seed_job(pool=SMALL), seed_job(conclusion="failure", pool=OLD)]}
        api = Api([run(2, "p1", conclusion="failure")], jobs)
        build, reasons = decide(api, ["p1"], {"HEAD": "v1", "p1": "v1"}, pools=POOLS)
        self.assertEqual(build, [OLD], reasons)
        # One pool saved at p1, another only further back: each compares with its own.
        jobs = {3: [seed_job()], 2: [seed_job(pool=SMALL)]}
        api = Api([run(3, "p1"), run(2, "p2")], jobs)
        build, _ = decide(api, ["p1", "p2"], {"HEAD": "v2", "p1": "v2", "p2": "v1"}, pools=POOLS[:2])
        self.assertEqual(build, [SMALL])

    def test_each_pool_compares_under_its_own_xcode(self):
        jobs = {2: [seed_job(), seed_job(pool=OLD)]}
        api = Api([run(2, "p1")], jobs)
        prints = {("HEAD", "Xcode.app"): "a", ("p1", "Xcode.app"): "a",
                  ("HEAD", "Xcode-15.app"): "b2", ("p1", "Xcode-15.app"): "b1"}
        build, _ = decide(api, ["p1"], prints, pools=[POOLS[0], POOLS[2]])
        self.assertEqual(build, [OLD])

    def test_order_is_kept_and_duplicates_dropped(self):
        # A fork runs every entry on macos-26; another MACOS_RUNNER_PR repeats one.
        build, _ = decide(Api([], {}), [], {}, pools=[("macos-26", "x"), ("macos-26", "x"), ("macos-26", "x")])
        self.assertEqual(build, ["macos-26"])
        build, _ = decide(Api([], {}), [], {}, pools=POOLS)
        self.assertEqual(build, [LARGE, SMALL, OLD])

    def test_inputs_equal_to_the_nearest_seed_skip(self):
        api = Api([run(2, "p1")], {2: [seed_job()]})
        build, reasons = decide(api, ["p1"], {"HEAD": "app-v1", "p1": "app-v1"})
        self.assertEqual(build, [], reasons)

    def test_a_chain_of_skipped_pushes_is_compared_with_the_seed_behind_it(self):
        api = Api([run(3, "p1"), run(2, "p2")], {3: [seed_job("skipped")], 2: [seed_job()]})
        self.assertEqual(decide(api, ["p1", "p2"], {"HEAD": "v1", "p2": "v1"})[0], [])
        self.assertEqual(decide(api, ["p1", "p2"], {"HEAD": "v2", "p2": "v1"})[0], [LARGE])
        # A run whose matrix left this pool out has no job for it: walk on.
        api = Api([run(3, "p1"), run(2, "p2")], {3: [seed_job(pool=SMALL)], 2: [seed_job()]})
        self.assertEqual(decide(api, ["p1", "p2"], {"HEAD": "v1", "p1": "v0", "p2": "v1"})[0], [])

    def test_a_pending_job_does_not_count(self):
        pending = Api([run(2, "p1", status="in_progress", conclusion=None), run(1, "p2")],
                      {2: [seed_job(status="in_progress", conclusion=None)], 1: [seed_job()]})
        build, reasons = decide(pending, ["p1", "p2"], {"HEAD": "v1", "p1": "v1", "p2": "v0"})
        self.assertEqual(build, [LARGE], reasons)

    def test_a_failed_seed_job_does_not_count(self):
        api = Api([run(2, "p1", conclusion="failure")], {2: [seed_job(conclusion="failure")]})
        self.assertEqual(decide(api, ["p1"], {"HEAD": "v1", "p1": "v1"})[0], [LARGE])

    def test_a_seed_that_was_not_saved_does_not_count(self):
        api = Api([run(2, "p1")], {2: [seed_job(saved=False)]})
        build, reasons = decide(api, ["p1"], {"HEAD": "v1", "p1": "v1"})
        self.assertEqual(build, [LARGE], reasons)

    def test_no_seeded_ancestor_or_an_api_error_builds(self):
        self.assertEqual(decide(Api([], {}), ["p1"], {"HEAD": "v1", "p1": "v1"})[0], [LARGE])

        def broken(_path):
            raise OSError("network")
        self.assertEqual(decide(broken, ["p1"], {"HEAD": "v1"}, pools=POOLS)[0], [LARGE, SMALL, OLD])

    def test_a_dispatch_always_builds(self):
        api = Api([run(2, "p1")], {2: [seed_job()]})
        self.assertEqual(decide(api, ["p1"], {"HEAD": "v1", "p1": "v1"}, event="workflow_dispatch")[0], [LARGE])

    def test_jobs_are_listed_once_per_run(self):
        api = Api([run(2, "p1"), run(1, "p2")], {2: [seed_job(pool=SMALL)], 1: [seed_job(), seed_job(pool=SMALL)]})
        decide(api, ["p1", "p2"], {"HEAD": "v1", "p1": "v1", "p2": "v1"}, pools=POOLS[:2])
        listings = [call for call in api.calls if "/jobs" in call]
        self.assertEqual(len(listings), len(set(listings)))

    def test_main_writes_the_matrix(self):
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as tmp, \
                unittest.mock.patch.object(seed_decide, "decide", return_value=([LARGE, OLD], ["r"])), \
                unittest.mock.patch("sys.stdout"):
            out = Path(tmp, "out")
            seed_decide.main(["--repository", REPO, "--pool", f"{LARGE}=x", "--pool", f"{OLD}=y",
                              "--github-output", str(out)])
            values = dict(line.split("=", 1) for line in out.read_text().splitlines())
        self.assertEqual((values["build"], json.loads(values["pools"])), ("true", [LARGE, OLD]))
        self.assertEqual(json.loads(values["matrix"]), {"include": [{"pool": LARGE}, {"pool": OLD}]})

    def test_a_root_lane_is_its_own_matrix_entry_and_job(self):
        # An owned Mac's second compile slot builds in /private/tmp/cmux-ci-2,
        # part of the seed key, so the trusted pool seeds there as its own job.
        import json
        import tempfile
        trusted = "glaeda-trusted-std-xcode-26.6"
        self.assertEqual(seed_decide.lane(f"{trusted}@2"), {"pool": trusted, "root": "2"})
        self.assertEqual(seed_decide.seed_job_name(f"{trusted}@2"), f"seed ({trusted}, 2)")
        self.assertEqual(seed_decide.seed_job_name(trusted), f"seed ({trusted})")
        for bad in ("@1", "@0", "@02", "@x", "@"):
            with self.assertRaises(ValueError):
                seed_decide.lane(trusted + bad)
        # Each lane finds its own nearest seed: root 1's does not count for root 2.
        api = Api([run(1, "p1")], {1: [seed_job(pool=trusted)]})
        build, _ = decide(api, ["p1"], {"HEAD": "v1", "p1": "v1"},
                          pools=((trusted, "x"), (f"{trusted}@2", "x")))
        self.assertEqual(build, [f"{trusted}@2"])
        with tempfile.TemporaryDirectory() as tmp, \
                unittest.mock.patch.object(seed_decide, "decide", return_value=([trusted, f"{trusted}@2"], ["r"])), \
                unittest.mock.patch("sys.stdout"):
            out = Path(tmp, "out")
            seed_decide.main(["--repository", REPO, "--pool", f"{trusted}=x", "--pool", f"{trusted}@2=x",
                              "--github-output", str(out)])
            values = dict(line.split("=", 1) for line in out.read_text().splitlines())
        self.assertEqual(json.loads(values["matrix"]),
                         {"include": [{"pool": trusted}, {"pool": trusted, "root": "2"}]})


class Wiring(unittest.TestCase):
    def test_decide_uses_the_nearest_seed_with_enough_history(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/seed-derived-data.yml").read_text())
        decide_job = workflow["jobs"]["decide"]
        checkout = decide_job["steps"][0]
        self.assertGreater(checkout["with"]["fetch-depth"], seed_decide.ANCESTOR_LIMIT)
        run_text = "\n".join(step.get("run", "") for step in decide_job["steps"])
        self.assertIn("scripts/ci/seed_decide.py", run_text)
        self.assertNotIn("HEAD^1", run_text)
        self.assertEqual(decide_job["permissions"]["actions"], "read")
        # The matrix is decide's list, and the product publisher is named, not
        # the first matrix entry, which moves when a pool skips.
        seed = workflow["jobs"][seed_decide.SEED_JOB]
        self.assertEqual(seed["strategy"]["matrix"], "${{ fromJSON(needs.decide.outputs.matrix) }}")
        self.assertEqual(decide_job["outputs"]["matrix"], "${{ steps.inputs.outputs.matrix }}")
        stage = next(step for step in seed["steps"] if step.get("id") == "stage-products")
        self.assertIn("matrix.pool == needs.decide.outputs.publisher", stage["if"])
        self.assertNotIn("job-index", yaml.safe_dump(workflow))
        # A rename would silently turn every skip into a build.
        seed_steps = [step.get("name") for step in workflow["jobs"][seed_decide.SEED_JOB]["steps"]]
        self.assertIn(seed_decide.SAVE_STEP, seed_steps)


if __name__ == "__main__":
    unittest.main()
