#!/usr/bin/env python3
"""A main push skips the seed build only when a seed with its inputs exists."""
import os
from pathlib import Path
import subprocess
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


def decide(api, ancestors, prints, event="push", pools=((LARGE, "Xcode.app"),), tiers=None, far=None):
    """Pools to build; `prints` maps a revision, or (revision, xcode), to its fingerprint, and
    `tiers` a covering seed's revision to its warm tier against HEAD (near when absent)."""
    return seed_decide.decide(
        event, REPO, list(pools), api=api,
        ancestors=lambda: ancestors,
        fingerprint_of=lambda revision, xcode: prints.get((revision, xcode), prints.get(revision)),
        tier_of=lambda revision: (tiers or {}).get(revision, "near"),
        far=far,
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


class FarLane(unittest.TestCase):
    def test_a_push_far_from_its_covering_seed_takes_the_far_lane(self):
        api = Api([run(2, "p1")], {2: [seed_job()]})
        for tier, lane in (("near", []), ("far", [LARGE]), ("rebuild", [LARGE])):
            far = []
            build, reasons = decide(api, ["p1"], {"HEAD": "v2", "p1": "v1"}, tiers={"p1": tier}, far=far)
            self.assertEqual((build, far), ([LARGE], lane), reasons)
            self.assertIn(f"{'Near' if tier == 'near' else 'Far'} lane: {tier} from p1", reasons[0])

    def test_a_running_seed_covers_its_commit_but_a_pending_one_does_not(self):
        # p1's seed is being built now (never cancelled), p2's is pending (may be replaced).
        api = Api([run(3, "p2", status="queued", conclusion=None), run(2, "p1", status="in_progress", conclusion=None),
                   run(1, "p0")],
                  {3: [seed_job(status="queued", conclusion=None, saved=False)],
                   2: [seed_job(status="in_progress", conclusion=None, saved=False)], 1: [seed_job()]})
        far = []
        build, reasons = decide(api, ["p2", "p1", "p0"], {"HEAD": "v3", "p0": "v0"},
                                tiers={"p1": "near", "p0": "rebuild"}, far=far)
        self.assertEqual((build, far), ([LARGE], []), reasons)
        self.assertIn("near from p1", reasons[0])
        # The skip still compares with a saved seed only (p0).
        self.assertIn("differ from p0", reasons[0])

    def test_no_covering_seed_is_far_and_an_error_is_near(self):
        far = []
        build, reasons = decide(Api([], {}), ["p1"], {"HEAD": "v1"}, far=far)
        self.assertEqual((build, far), ([LARGE], [LARGE]), reasons)
        self.assertIn("no seed covers", reasons[0])

        def broken(_revision):
            raise subprocess.CalledProcessError(128, "git")
        far = []
        build, reasons = seed_decide.decide(
            "push", REPO, [(LARGE, "x")], api=Api([run(2, "p1")], {2: [seed_job()]}), ancestors=lambda: ["p1"],
            fingerprint_of=lambda revision, _xcode: revision, tier_of=broken, far=far)
        self.assertEqual((build, far), ([LARGE], []), reasons)
        self.assertIn("Near lane: could not measure", reasons[0])

    def test_skipped_and_dispatched_pools_never_take_the_far_lane(self):
        api = Api([run(2, "p1")], {2: [seed_job()]})
        far = []
        self.assertEqual(decide(api, ["p1"], {"HEAD": "v1", "p1": "v1"}, tiers={"p1": "far"}, far=far)[0], [])
        self.assertEqual(far, [])
        decide(api, ["p1"], {"HEAD": "v1", "p1": "v1"}, event="workflow_dispatch", far=far)
        self.assertEqual(far, [])

    def test_each_lane_measures_from_its_own_covering_seed(self):
        trusted = "glaeda-trusted-std-xcode-26.6"
        api = Api([run(2, "p1"), run(1, "p2")], {2: [seed_job(pool=trusted)], 1: [seed_job(pool=f"{trusted}, 2")]})
        far = []
        build, _ = decide(api, ["p1", "p2"], {"HEAD": "v3", "p1": "v1", "p2": "v2"},
                          pools=((trusted, "x"), (f"{trusted}@2", "x")), tiers={"p1": "near", "p2": "far"}, far=far)
        self.assertEqual((build, far), ([trusted, f"{trusted}@2"], [f"{trusted}@2"]))

    def test_the_tier_is_warm_distance_s_between_the_two_trees(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            git = ["git", "-C", tmp, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
            subprocess.run([*git, "init", "-q"], check=True)
            Path(tmp, "Sources").mkdir()
            Path(tmp, "Packages/Kit").mkdir(parents=True)
            Path(tmp, "Packages/Kit/K.swift").write_text("struct K {}\n")
            subprocess.run([*git, "add", "-A"], check=True)
            subprocess.run([*git, "commit", "-qm", "base"], check=True)
            base = subprocess.check_output([*git, "rev-parse", "HEAD"], text=True).strip()

            def commit(changes):
                for name, text in changes.items():
                    Path(tmp, name).write_text(text)
                subprocess.run([*git, "add", "-A"], check=True)
                subprocess.run([*git, "commit", "-qm", "c"], check=True)
                cwd = os.getcwd()
                os.chdir(tmp)
                try:
                    return seed_decide.warm_tier(base)
                finally:
                    os.chdir(cwd)

            with unittest.mock.patch.object(seed_decide.warm_distance, "load_model", return_value={}):
                self.assertEqual(commit({f"Sources/A{i}.swift": "a\n" for i in range(3)}), "near")
                self.assertEqual(commit({f"Sources/B{i}.swift": "b\n" for i in range(3)}), "far")
                self.assertEqual(commit({"Packages/Kit/K.swift": "public struct K {}\n"}), "rebuild")


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
