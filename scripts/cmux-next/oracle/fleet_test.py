#!/usr/bin/env python3
"""Tests for fleet.py and scripts/measure/oracle.sh (p15-oracle-050): shards merge into one receipt, waits never
resubmit, refusals and lost pairs are reported, never maclease; a diff pair on two hosts, OS versions or displays is
refused as host-mismatch (p15-oracle-008).

Run: python3 -I scripts/cmux-next/oracle/fleet_test.py (stdlib unittest; no fleet, no build). A fake `cmux-ci`
(FAKE_CLIENT below) stands in for the controller: `run` prints the step line the real client prints, then runs
scripts/measure/oracle.sh --dry-run in a throwaway git checkout that holds copies of oracle.sh and the oracle
scripts, as a worker runs a step in its checkout; `wait` and `artifact` answer from the fake's state dir.
"""

from __future__ import annotations

import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
import unittest.mock
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(HERE))

import fleet  # noqa: E402

SHA = "0123456789abcdef0123456789abcdef01234567"
SUBMODULES = ("ghostty", "ghostty-next")

FAKE_CLIENT = r'''#!/usr/bin/env python3
"""A fake cmux-ci: run, wait, artifact. State in $FAKE_STATE; every call logged to $FAKE_STATE/calls.jsonl."""
import fcntl, hashlib, json, os, shutil, subprocess, sys
state = os.environ["FAKE_STATE"]
args = sys.argv[1:]
def log(entry):
    with open(os.path.join(state, "calls.jsonl"), "a") as f:
        f.write(json.dumps(entry) + "\n")
def bump(name):
    # Shards submit in parallel: the counter file is read and written under an flock.
    with open(os.path.join(state, name), "a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        n = int(f.read() or 0)
        f.seek(0)
        f.truncate()
        f.write(str(n + 1))
    return n
def opt(name):
    return args[args.index(name) + 1] if name in args else None
op = args[0]
log({"op": op, "args": args[1:]})
if op == "run":
    if os.environ.get("FAKE_REFUSE"):
        print("cmux-ci: HTTP 400: script is not on the ci-step allowlist", file=sys.stderr)
        sys.exit(1)
    key = opt("--key")
    step_id = hashlib.sha1(key.encode()).hexdigest()[:24]
    workers = os.environ.get("FAKE_WORKERS", "mini-a,mini-b,mini-c").split(",")
    target = opt("--target-worker")
    worker = workers[bump("submissions") % len(workers)]
    if target and not os.environ.get("FAKE_IGNORE_TARGET"):
        worker = target
    print(f"cmux-ci: step {step_id} (exclusive, key {key})", file=sys.stderr, flush=True)
    step_args = [a[len("--arg="):] for a in args if a.startswith("--arg=")]
    # Each step runs in its own clone at --ref (FAKE_CHECKOUT_REF: a worker that checked out another commit), as a
    # worker runs it in its checkout; FAKE_STALE_SUBMODULE leaves that submodule at a commit of its own, as a reused
    # checkout keeps an earlier step's submodule.
    checkout = os.path.join(state, "wt-" + step_id)
    git = ["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "advice.detachedHead=false"]
    subprocess.run(git + ["clone", "-q", "--shared", os.environ["FAKE_CHECKOUT"], checkout], check=True)
    ref = os.environ.get("FAKE_CHECKOUT_REF") or opt("--ref")
    subprocess.run(git + ["-C", checkout, "checkout", "-q", "--detach", ref], check=True)
    stale = os.environ.get("FAKE_STALE_SUBMODULE")
    if stale:
        subprocess.run(git + ["-C", os.path.join(checkout, stale), "init", "-q"], check=True)
        subprocess.run(git + ["-C", os.path.join(checkout, stale), "commit", "-q", "--allow-empty", "-m", "stale"],
                       check=True)
    if os.environ.get("FAKE_WORKER_REFUSE"):
        code = 1
        print(f"ci-step refused: scripts/measure/oracle.sh at {opt('--ref')} (blob 0) is not the reviewed version "
              "on main or feat-cmux-next", flush=True)
    else:
        code = subprocess.run(["bash", "scripts/measure/oracle.sh", *step_args], cwd=checkout,
                              env={**os.environ, "CMUX_CI_STEP_KEY": key}).returncode
    job = {"id": step_id, "state": "done" if code == 0 else "failed", "exit_code": code, "worker": worker,
           "step_key": key}
    artifact = os.path.join(checkout, opt("--artifact"))
    if code == 0 and os.path.exists(artifact):
        shutil.copy(artifact, os.path.join(state, step_id + ".tar.gz"))
        job["artifact"] = "sha256:" + "0" * 64
    json.dump(job, open(os.path.join(state, step_id + ".json"), "w"))
    print(f"cmux-ci: step {step_id} {job['state']} on {worker}", file=sys.stderr, flush=True)
    if os.environ.get("FAKE_CLIENT_GONE"):
        print(f"cmux-ci: step {step_id} continues; re-attach with the same --key {key}", file=sys.stderr)
        sys.exit(130)
    sys.exit(code)
if op == "wait":
    step_id = args[1]
    if bump("waits-" + step_id) < int(os.environ.get("FAKE_WAIT_TIMEOUTS", "0")):
        print(f"Timed out observing {step_id}; remote job is unchanged", file=sys.stderr)
        sys.exit(2)
    job = json.load(open(os.path.join(state, step_id + ".json")))
    open(opt("--receipt"), "w").write(json.dumps(job))
    sys.exit(0 if job["state"] == "done" else 1)
if op == "artifact":
    source = os.path.join(state, args[1] + ".tar.gz")
    if not os.path.exists(source):
        print("no artifact", file=sys.stderr)
        sys.exit(1)
    shutil.copy(source, args[2])
    sys.exit(0)
sys.exit(64)
'''


def write_corpus(root: Path, count: int) -> Path:
    for i in range(count):
        suite = ("alpha", "beta", "gamma")[i % 3]
        path = root / suite / f"case-{i:03d}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"id": f"{suite}/case-{i:03d}", "steps": [{"id": "s1", "op": "snapshot"}]}))
    return root


def make_checkout(root: Path) -> Path:
    """A git checkout with oracle.sh and the oracle scripts, where the fake worker runs its steps."""
    checkout = root / "checkout"
    (checkout / "scripts" / "measure").mkdir(parents=True)
    shutil.copy(REPO / "scripts" / "measure" / "oracle.sh", checkout / "scripts" / "measure" / "oracle.sh")
    shutil.copytree(HERE, checkout / "scripts" / "cmux-next" / "oracle",
                    ignore=shutil.ignore_patterns("__pycache__"))
    for rel in ("tests/oracle", "schemas/oracle"):
        if (REPO / rel).is_dir():
            shutil.copytree(REPO / rel, checkout / rel)
    git = ["git", "-C", str(checkout), "-c", "user.email=t@t", "-c", "user.name=t"]
    subprocess.run(git[:3] + ["init", "-q"], check=True)
    # The app's submodules, initialized here (oracle.sh builds against them) and committed as gitlinks.
    for sub in SUBMODULES:
        subprocess.run(["git", "init", "-q", str(checkout / sub)], check=True)
        subprocess.run(["git", "-C", str(checkout / sub), *git[3:], "commit", "-q", "--allow-empty", "-m", sub],
                       check=True)
        subprocess.run(git + ["update-index", "--add", "--cacheinfo", f"160000,{head_of(checkout / sub)},{sub}"],
                       check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-q", "-m", "fixture"], check=True)
    return checkout


def head_of(checkout: Path, rev: str = "HEAD") -> str:
    return subprocess.run(["git", "-C", str(checkout), "rev-parse", rev], check=True, stdout=subprocess.PIPE,
                          text=True).stdout.strip()


class FleetHarness(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="oracle-fleet-test-"))
        self.state = self.tmp / "state"
        self.state.mkdir()
        self.client = self.tmp / "bin" / "cmux-ci"
        self.client.parent.mkdir()
        self.client.write_text(FAKE_CLIENT)
        self.client.chmod(0o755)
        self.corpus = write_corpus(self.tmp / "corpus", 30)
        self.checkout = make_checkout(self.tmp)
        self.gitlinks = {sub: head_of(self.checkout / sub) for sub in SUBMODULES}
        # Two commits, as a base and a head: the head adds a file.
        self.sha = head_of(self.checkout)
        (self.checkout / "head.txt").write_text("head\n")
        git = ["git", "-C", str(self.checkout), "-c", "user.email=t@t", "-c", "user.name=t"]
        subprocess.run(git + ["add", "head.txt"], check=True)
        subprocess.run(git + ["commit", "-q", "-m", "head"], check=True)
        self.other_sha = head_of(self.checkout)
        self.env = {"FAKE_STATE": str(self.state), "FAKE_CHECKOUT": str(self.checkout)}
        self.saved = {k: os.environ.get(k) for k in ("FAKE_STATE", "FAKE_CHECKOUT", "FAKE_REFUSE", "FAKE_WAIT_TIMEOUTS",
                                                     "FAKE_CLIENT_GONE", "FAKE_IGNORE_TARGET", "FAKE_WORKER_REFUSE",
                                                     "FAKE_WORKERS", "FAKE_CHECKOUT_REF", "FAKE_STALE_SUBMODULE")}
        os.environ.update(self.env)
        # fleet.py reads refs, mutants and gitlinks from its checkout: the fixture's here.
        self.saved_repo = fleet.REPO
        fleet.REPO = self.checkout

    def tearDown(self) -> None:
        fleet.REPO = self.saved_repo
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)

    def fleet(self, *argv: str) -> int:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = fleet.main([*argv, "--client", str(self.client), "--dry-run", "--corpus", str(self.corpus)])
        self.output = out.getvalue() + err.getvalue()
        return code

    def calls(self, op: str) -> list:
        path = self.state / "calls.jsonl"
        rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [r for r in rows if r["op"] == op]

    def record(self, out: Path) -> dict:
        return json.loads((out / "fleet.json").read_text())


class RunTests(FleetHarness):
    def test_six_shards_merge_into_one_receipt(self) -> None:
        out = self.tmp / "out"
        code = self.fleet("run", "--ref", self.sha, "--shards", "6", "--out", str(out), "--run-id", "t1")
        self.assertEqual(code, fleet.EXIT_OK, self.output)
        runs = self.calls("run")
        self.assertEqual(len(runs), 6)
        for row in runs:
            args = row["args"]
            self.assertEqual(args[args.index("--class") + 1], "exclusive")
            self.assertEqual(args[args.index("--script") + 1], "scripts/measure/oracle.sh")
            self.assertIn("--no-supersede", args)
            self.assertIn("--arg=--config=bench", args)
        receipt = json.loads((out / "run" / "receipt.json").read_text())
        self.assertEqual(receipt["shards"], [0, 1, 2, 3, 4, 5])
        self.assertEqual(len(receipt["cases"]), 30)
        self.assertEqual(receipt["config"]["build"], "bench")
        self.assertEqual(receipt["config"]["product"], "app")
        record = self.record(out)
        self.assertTrue(record["ok"])
        self.assertEqual(len(record["sides"]["run"]["shards"]), 6)
        self.assertTrue(all(s["state"] == "done" for s in record["sides"]["run"]["shards"]))

    def test_wait_timeouts_wait_again_and_never_resubmit(self) -> None:
        os.environ.update({"FAKE_CLIENT_GONE": "1", "FAKE_WAIT_TIMEOUTS": "2"})
        out = self.tmp / "out"
        code = self.fleet("run", "--ref", self.sha, "--shards", "3", "--out", str(out), "--run-id", "t2")
        self.assertEqual(code, fleet.EXIT_OK, self.output)
        self.assertEqual(len(self.calls("run")), 3)
        self.assertEqual(len(self.calls("wait")), 9)
        self.assertIn("waiting again (never a resubmit)", self.output)

    def test_a_second_fleet_py_reattaches_to_the_same_steps(self) -> None:
        out = self.tmp / "out"
        self.assertEqual(self.fleet("run", "--ref", self.sha, "--shards", "2", "--out", str(out), "--run-id", "t3"), 0)
        self.assertEqual(self.fleet("run", "--ref", self.sha, "--shards", "2", "--out", str(out)), 0, self.output)
        self.assertEqual(len(self.calls("run")), 2)
        self.assertEqual(self.record(out)["runId"], "t3")

    def test_controller_refusal_is_incomplete_and_names_the_hq_ask(self) -> None:
        os.environ["FAKE_REFUSE"] = "1"
        out = self.tmp / "out"
        code = self.fleet("run", "--ref", self.sha, "--shards", "2", "--out", str(out), "--run-id", "t4")
        self.assertEqual(code, fleet.EXIT_INCOMPLETE)
        shards = self.record(out)["sides"]["run"]["shards"]
        self.assertEqual({s["state"] for s in shards}, {"refused"})
        self.assertIn("measureScripts", shards[0]["error"])
        self.assertFalse((out / "run").exists())

    def test_worker_refusal_of_an_unreviewed_blob_is_reported(self) -> None:
        os.environ["FAKE_WORKER_REFUSE"] = "1"
        out = self.tmp / "out"
        code = self.fleet("run", "--ref", self.sha, "--shards", "1", "--out", str(out), "--run-id", "t5")
        self.assertEqual(code, fleet.EXIT_INCOMPLETE)
        shard = self.record(out)["sides"]["run"]["shards"][0]
        self.assertEqual(shard["state"], "refused")
        self.assertIn("not the reviewed version", shard["error"])

    def test_glob_filters_travel_hex_encoded(self) -> None:
        out = self.tmp / "out"
        code = self.fleet("run", "--ref", self.sha, "--shards", "2", "--out", str(out), "--run-id", "t6",
                          "--filter", "alpha/*")
        self.assertEqual(code, fleet.EXIT_OK, self.output)
        args = self.calls("run")[0]["args"]
        self.assertIn("--arg=--filter-hex=" + "alpha/*".encode().hex(), args)
        receipt = json.loads((out / "run" / "receipt.json").read_text())
        self.assertEqual(len(receipt["cases"]), 10)
        self.assertTrue(all(cid.startswith("alpha/") for cid in receipt["cases"]))


class DiffFixture(FleetHarness):
    """A base commit and a head with one p15-oracle commit (an app file and a runner file), a bare remote for the
    overlay commit (overlay.py, p15-oracle-202); FleetHarness points fleet.REPO at that checkout."""

    def setUp(self) -> None:
        super().setUp()
        self.git = ["git", "-C", str(self.checkout), "-c", "user.email=t@t", "-c", "user.name=t"]
        self.base = self.rev("HEAD")
        oracle_swift = self.checkout / "Packages/macOS/CmuxNext/Sources/Fixture/Oracle.swift"
        oracle_swift.parent.mkdir(parents=True)
        oracle_swift.write_text("let oracle = 1\n")
        (self.checkout / "tests" / "oracle" / "fixture-head.json").write_text("{}\n")
        subprocess.run(self.git + ["add", "-A"], check=True)
        subprocess.run(self.git + ["commit", "-q", "-m", "p15-oracle-998: fixture oracle registration"], check=True)
        self.head = self.rev("HEAD")
        self.remote = self.tmp / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", str(self.remote)], check=True)

    def rev(self, ref: str) -> str:
        return subprocess.run(self.git + ["rev-parse", ref], check=True, stdout=subprocess.PIPE, text=True).stdout.strip()

    def diff(self, out: Path, *extra: str) -> int:
        return self.fleet("diff", "--base", self.base, "--head", self.head, "--out", str(out),
                          "--remote", str(self.remote), *extra)


class DiffTests(DiffFixture):
    def test_head_runs_on_the_base_steps_worker(self) -> None:
        out = self.tmp / "out"
        code = self.diff(out, "--shards", "3", "--run-id", "d1")
        record = self.record(out)
        for base, head in zip(record["sides"]["base"]["shards"], record["sides"]["head"]["shards"]):
            self.assertEqual(head["target_worker"], base["worker"])
            self.assertEqual(head["worker"], base["worker"])
        # Both sides merged; oracle.py diff refuses to compare dry runs (nothing ran), exit 3.
        self.assertTrue((out / "base" / "receipt.json").is_file())
        self.assertTrue((out / "head" / "receipt.json").is_file())
        self.assertEqual(record["comparison"]["exit"], code)
        self.assertEqual(code, 3, self.output)

    def test_engine_parity_runs_one_arm_per_engine_of_one_build(self) -> None:
        out = self.tmp / "out"
        code = self.fleet("diff", "--engine", "webkit,chromium", "--ref", self.sha, "--shards", "2", "--out", str(out),
                          "--run-id", "e1")
        self.assertEqual(code, 3, self.output)  # dry runs: both arms merge, nothing to compare
        record = self.record(out)
        self.assertEqual({side: record["sides"][side]["args"] for side in ("webkit", "chromium")},
                         {"webkit": {"engine": "webkit"}, "chromium": {"engine": "chromium"}})
        self.assertEqual({record["sides"][side]["sha"] for side in ("webkit", "chromium")}, {self.sha})
        for side in ("webkit", "chromium"):
            self.assertEqual(json.loads((out / side / "receipt.json").read_text())["config"]["engine"], side)
        with redirect_stderr(io.StringIO()):
            for argv in (["--engine", "webkit,webkit", "--ref", self.sha], ["--engine", "webkit,gecko", "--ref", self.sha],
                         ["--engine", "webkit,chromium"], ["--engine", "webkit,chromium", "--ref", self.sha, "--switch", "x"],
                         ["--engine", "webkit,chromium", "--base", self.sha, "--head", self.other_sha]):
                self.assertEqual(fleet.main(["diff", *argv, "--out", str(self.tmp / "refused")]), fleet.EXIT_USAGE, argv)

    def test_a_cross_host_pair_is_refused(self) -> None:
        os.environ["FAKE_IGNORE_TARGET"] = "1"
        out = self.tmp / "out"
        code = self.diff(out, "--shards", "1", "--run-id", "d2")
        self.assertEqual(code, fleet.EXIT_INCOMPLETE)
        head = self.record(out)["sides"]["head"]["shards"][0]
        self.assertIn("ignored --target-worker", head["error"])
        self.assertNotIn("comparison", self.record(out))

    def test_the_base_side_builds_the_pushed_overlay_commit(self) -> None:
        out = self.tmp / "out"
        self.diff(out, "--shards", "2", "--run-id", "d3")
        record = self.record(out)
        plan = record["overlay"]
        self.assertEqual((plan["mode"], plan["facets"], plan["base"], plan["head"]),
                         ("overlay", "v1", self.base, self.head))
        sha = plan["overlaySha"]
        self.assertEqual({s["sha"] for s in record["sides"]["base"]["shards"]}, {sha})
        self.assertEqual({s["sha"] for s in record["sides"]["head"]["shards"]}, {self.head})
        pushed = subprocess.run(["git", "-C", str(self.remote), "rev-parse", f"refs/heads/oracle-overlay/{sha}"],
                                check=True, stdout=subprocess.PIPE, text=True).stdout.strip()
        self.assertEqual(pushed, sha)
        refs = {row["args"][row["args"].index("--ref") + 1] for row in self.calls("run")}
        self.assertEqual(refs, {sha, self.head})
        self.assertFalse(any("--arg=--facets=v0" in row["args"] for row in self.calls("run")))
        comparison = json.loads((out / "compare" / "comparison.json").read_text())
        self.assertEqual(comparison["overlay"]["overlaySha"], sha)

    def test_v0_runs_both_sides_on_v0_facets(self) -> None:
        out = self.tmp / "out"
        self.diff(out, "--shards", "1", "--run-id", "d4", "--v0", "the overlay does not build")
        record = self.record(out)
        self.assertEqual((record["overlay"]["mode"], record["overlay"]["reason"]), ("v0", "the overlay does not build"))
        runs = self.calls("run")
        self.assertEqual(len(runs), 2)
        self.assertTrue(all("--arg=--facets=v0" in row["args"] for row in runs))
        self.assertEqual(record["sides"]["head"]["args"], {"facets": "v0"})
        step = json.loads((out / "shards" / "base" / "0" / "unpacked" / "fleet-step.json").read_text())
        self.assertIn("--facets=v0", step["argv"])

    def test_v0_needs_base_and_head(self) -> None:
        code = self.fleet("diff", "--switch", "x", "--ref", self.head, "--v0", "why")
        self.assertEqual(code, fleet.EXIT_USAGE)
        self.assertIn("--v0 goes with --base/--head", self.output)

    def test_the_receipts_name_exact_shas_and_gitlinks(self) -> None:
        """Task 112: fleet.json, builds.json and comparison.json name each side's exact SHA and every gitlink."""
        out = self.tmp / "out"
        code = self.fleet("diff", "--base", self.sha, "--head", self.other_sha, "--shards", "2", "--out", str(out),
                          "--run-id", "d3")
        self.assertEqual(code, 3, self.output)  # dry runs: compared nothing, but every receipt is written
        record = self.record(out)
        builds = json.loads((out / "builds.json").read_text())
        comparison = json.loads((out / "compare" / "comparison.json").read_text())
        for label, sha in (("base", self.sha), ("head", self.other_sha)):
            side = record["sides"][label]
            self.assertEqual((side["sha"], side["ref"], side["gitlinks"], side["gitlinksFrom"]),
                             (sha, sha, self.gitlinks, "tree"))
            self.assertEqual((builds[label]["sha"], builds[label]["gitlinks"]), (sha, self.gitlinks))
            self.assertEqual(comparison["builds"][label]["sha"], sha)
            self.assertEqual(comparison["builds"][label]["gitlinks"], self.gitlinks)
            for shard in side["shards"]:
                self.assertEqual(shard["build"]["sha"], sha)
                self.assertEqual(shard["build"]["gitlinks"], self.gitlinks)
                # The step's clone has the gitlinks but no initialized submodule (a dry run builds nothing).
                self.assertEqual(shard["build"]["submodules"], {sub: None for sub in SUBMODULES})
        self.assertEqual(comparison["refused"], "a dry run has no results")

    def test_head_defaults_to_this_checkouts_head(self) -> None:
        out = self.tmp / "out"
        self.assertEqual(self.fleet("diff", "--base", self.base, "--out", str(out), "--run-id", "d4",
                                    "--remote", str(self.remote)), 3, self.output)
        head = self.record(out)["sides"]["head"]
        self.assertEqual((head["ref"], head["sha"]), ("HEAD", self.head))
        self.assertEqual(self.fleet("diff", "--head", self.sha, "--out", str(self.tmp / "o2")), fleet.EXIT_USAGE)
        self.assertIn("--head needs --base", self.output)

    def test_a_step_at_another_commit_is_a_wrong_build(self) -> None:
        os.environ["FAKE_CHECKOUT_REF"] = self.sha
        out = self.tmp / "out"
        code = self.fleet("diff", "--base", self.sha, "--head", self.other_sha, "--out", str(out), "--run-id", "d5")
        self.assertEqual(code, fleet.EXIT_INCOMPLETE, self.output)
        record = self.record(out)
        self.assertEqual(record["sides"]["base"]["shards"][0]["state"], "done")
        head = record["sides"]["head"]["shards"][0]
        self.assertEqual(head["state"], "wrong-build")
        self.assertIn(f"built {self.sha}, not {self.other_sha}", head["error"])
        self.assertNotIn("comparison", record)
        self.assertFalse((out / "builds.json").exists())

    def test_a_submodule_off_its_gitlink_is_a_wrong_build(self) -> None:
        os.environ["FAKE_STALE_SUBMODULE"] = "ghostty-next"
        out = self.tmp / "out"
        code = self.fleet("diff", "--base", self.sha, "--head", self.other_sha, "--out", str(out), "--run-id", "d6")
        self.assertEqual(code, fleet.EXIT_INCOMPLETE, self.output)
        for side in self.record(out)["sides"].values():
            shard = side["shards"][0]
            self.assertEqual(shard["state"], "wrong-build")
            self.assertIn(f"built ghostty-next at {shard['build']['submodules']['ghostty-next']}", shard["error"])
            self.assertIn(f"gitlink is {self.gitlinks['ghostty-next']}", shard["error"])

    def diff_with_head_host(self, change, run_id: str) -> int:
        """A base/head diff of 2 shards whose head receipts, in shard 1 only, get `change` applied to their host."""
        original = fleet.Fleet.fetch

        def fetch(fleet_self, shard, *, failed):
            run = original(fleet_self, shard, failed=failed)
            if run is not None and shard.side == "head" and shard.index == 1:
                receipt = json.loads((run / "receipt.json").read_text())
                receipt["host"] = change(dict(receipt["host"]))
                (run / "receipt.json").write_text(json.dumps(receipt))
            return run

        with unittest.mock.patch.object(fleet.Fleet, "fetch", fetch):
            return self.diff(self.tmp / run_id, "--shards", "2", "--run-id", run_id)

    def test_every_receipt_records_host_os_and_display(self) -> None:
        out = self.tmp / "out"
        self.diff(out, "--shards", "1", "--run-id", "h0")
        for side in ("base", "head"):
            host = json.loads((out / "shards" / side / "0" / "unpacked" / "run" / "receipt.json").read_text())["host"]
            self.assertEqual(set(host), {"name", "os", "osVersion", "arch", "display"})
            self.assertIsNotNone(host["display"])

    def test_forced_cross_host_os_or_display_pairs_are_refused(self) -> None:
        for run_id, change, field in (
                ("h1", lambda host: {**host, "name": "aws-m4pro-6"}, "name"),
                ("h2", lambda host: {**host, "osVersion": "27.0"}, "osVersion"),
                ("h3", lambda host: {**host, "display": "1600 x 1000 @ 120.00Hz (1600 x 1000 px), 2 displays"},
                 "display"),
                ("h4", lambda host: {k: v for k, v in host.items() if k != "display"}, "display (not recorded)")):
            with self.subTest(field=field):
                self.assertEqual(self.diff_with_head_host(change, run_id), fleet.EXIT_INCOMPLETE, self.output)
                record = self.record(self.tmp / run_id)
                self.assertEqual(record["verdict"], "host-mismatch")
                self.assertEqual(list(record["mismatched"]), ["shard 1"])
                self.assertTrue(record["mismatched"]["shard 1"][0].startswith(field), record["mismatched"])
                self.assertNotIn("comparison", record)
                self.assertFalse(record["ok"])
                self.assertFalse((self.tmp / run_id / "compare").exists())
                self.assertIn("host-mismatch", self.output)


FIXTURE_SWIFT = "Packages/macOS/CmuxNext/Sources/Fixture/Index.swift"
FIXTURE_MUTANT = "tests/oracle/mutants/app/fixture-off-by-one.patch"


class MutantFixture(FleetHarness):
    """A checkout with one committed Swift source and an app mutant of it (p15-oracle-026)."""

    def setUp(self) -> None:
        super().setUp()
        git = ["git", "-C", str(self.checkout), "-c", "user.email=t@t", "-c", "user.name=t"]
        source = self.checkout / FIXTURE_SWIFT
        source.parent.mkdir(parents=True)
        source.write_text("func index(_ i: Int) -> Int {\n    i\n}\n")
        subprocess.run(git + ["add", "-A"], check=True)
        subprocess.run(git + ["commit", "-q", "-m", "swift"], check=True)
        source.write_text("func index(_ i: Int) -> Int {\n    i + 1\n}\n")
        body = subprocess.run(git + ["diff"], check=True, stdout=subprocess.PIPE, text=True).stdout
        subprocess.run(git + ["checkout", "-q", "--", FIXTURE_SWIFT], check=True)
        mutant = self.checkout / FIXTURE_MUTANT
        mutant.parent.mkdir(parents=True, exist_ok=True)
        mutant.write_text("Mutant: app/fixture-off-by-one\nSuite: actions\nExercises: index\nFault: off by one.\n\n" + body)
        subprocess.run(git + ["add", "-A"], check=True)
        subprocess.run(git + ["commit", "-q", "-m", "mutant"], check=True)
        self.sha = head_of(self.checkout)


class MutantTests(MutantFixture):
    """App mutants (p15-oracle-026): the head step gets --mutant=PATH, oracle.sh checks it applies in its checkout."""

    def test_the_head_step_alone_gets_the_mutant(self) -> None:
        out = self.tmp / "out"
        code = self.fleet("diff", "--base", self.sha, "--head", self.sha, "--head-mutant", FIXTURE_MUTANT,
                          "--shards", "2", "--out", str(out), "--run-id", "m1")
        self.assertEqual(code, 3, self.output)  # dry runs: both sides merge, nothing to compare
        arg = f"--arg=--mutant={FIXTURE_MUTANT}"
        by_side: dict = {}
        for row in self.calls("run"):
            key = row["args"][row["args"].index("--key") + 1]
            by_side.setdefault(key.split("-")[2], []).append(arg in row["args"])
        self.assertEqual(by_side, {"base": [False, False], "head": [True, True]})
        record = self.record(out)
        self.assertEqual(record["sides"]["head"]["args"], {"mutant": FIXTURE_MUTANT})
        self.assertEqual(record["sides"]["base"]["args"], {})
        step = json.loads((out / "shards" / "head" / "0" / "unpacked" / "fleet-step.json").read_text())
        self.assertEqual(step["mutant"], "app/fixture-off-by-one")
        base = json.loads((out / "shards" / "base" / "0" / "unpacked" / "fleet-step.json").read_text())
        self.assertIsNone(base["mutant"])
        self.assertNotIn("i + 1", (self.checkout / FIXTURE_SWIFT).read_text(), "a dry run applies nothing")

    def test_a_mutant_that_does_not_apply_fails_its_step(self) -> None:
        git = ["git", "-C", str(self.checkout), "-c", "user.email=t@t", "-c", "user.name=t"]
        (self.checkout / FIXTURE_SWIFT).write_text("func index(_ j: Int) -> Int {\n    j\n}\n")
        subprocess.run(git + ["commit", "-q", "-am", "moved on"], check=True)
        sha = subprocess.run(git + ["rev-parse", "HEAD"], check=True, stdout=subprocess.PIPE, text=True).stdout.strip()
        out = self.tmp / "out"
        code = self.fleet("run", "--ref", sha, "--mutant", FIXTURE_MUTANT, "--out", str(out), "--run-id", "m2")
        self.assertEqual(code, fleet.EXIT_INCOMPLETE, self.output)
        log = (out / "shards" / "run" / "0" / "step.log").read_text()
        self.assertIn("does not apply", log)

    def test_mutant_paths_are_checked_before_any_submission(self) -> None:
        for path, message in (("tests/oracle/mutants/daemon/x.patch", "an app mutant is"),
                              ("../escape.patch", "an app mutant is"),
                              ("tests/oracle/mutants/app/missing.patch", "unreadable")):
            with self.subTest(path=path):
                self.assertEqual(self.fleet("run", "--ref", self.sha, "--mutant", path, "--out", str(self.tmp / "o")),
                                 fleet.EXIT_USAGE)
                self.assertIn(message, self.output)
        (self.checkout / FIXTURE_MUTANT).write_text((self.checkout / FIXTURE_MUTANT).read_text() + "\n")
        self.assertEqual(self.fleet("run", "--ref", self.sha, "--mutant", FIXTURE_MUTANT), fleet.EXIT_USAGE)
        self.assertIn("differs from", self.output)
        self.assertEqual(self.fleet("diff", "--ref", self.sha, "--switch", "x", "--head-mutant", FIXTURE_MUTANT),
                         fleet.EXIT_USAGE)
        self.assertIn("goes with --base/--head", self.output)
        self.assertEqual(self.calls("run"), [])


# The build oracle.sh runs, stubbed: it records whether the fault is in the source it compiles, then acts as
# STUB_RELOAD says (ok: prints an app path; fail: a failed build; hang: waits to be signalled; lock: leaves
# .git/index.lock, as a concurrent git command would, so the revert cannot write the index).
STUB_RELOAD = r'''#!/usr/bin/env bash
set -eu
grep -c "i + 1" "Packages/macOS/CmuxNext/Sources/Fixture/Index.swift" >"$STUB_LOG/reload-saw" || true
git -C ghostty-next rev-parse HEAD >"$STUB_LOG/ghostty-next-head"
case "$STUB_RELOAD" in
  ok | lock)
    [[ "$STUB_RELOAD" == ok ]] || : >.git/index.lock
    mkdir -p "$STUB_LOG/cmux DEV oracle.app"
    printf 'App path:\n  %s\n' "$STUB_LOG/cmux DEV oracle.app" ;;
  fail) echo "error: stub build failed"; exit 1 ;;
  hang) : >"$STUB_LOG/reload-started"; sleep 60 ;;
esac
'''
# fleet.py step, stubbed: its argv is the record under test.
STUB_STEP = r'''import json, os, sys
open(os.path.join(os.environ["STUB_LOG"], "step.json"), "w").write(json.dumps(sys.argv[1:]))
'''


class MutantBuildTests(MutantFixture):
    """oracle.sh without --dry-run: the mutant is in the build, the reused checkout is clean after every exit."""

    def setUp(self) -> None:
        super().setUp()
        self.stub_log = self.tmp / "stub"
        self.stub_log.mkdir()
        reload = self.checkout / "scripts" / "reload.sh"
        reload.write_text(STUB_RELOAD)
        reload.chmod(0o755)
        (self.checkout / "scripts" / "cmux-next" / "oracle" / "fleet.py").write_text(STUB_STEP)
        (self.checkout / "GhosttyKit.xcframework").mkdir()
        (self.checkout / "GhosttyKit.xcframework" / "Info.plist").write_text("")

    def start(self, reload: str, *, mutant: bool = True) -> subprocess.Popen:
        argv = ["bash", "scripts/measure/oracle.sh", "--shard=0/1", "--artifact=artifacts/oracle/s.tar.gz"]
        argv += [f"--mutant={FIXTURE_MUTANT}"] if mutant else []
        env = {**os.environ, "STUB_LOG": str(self.stub_log), "STUB_RELOAD": reload, "TMPDIR": str(self.tmp)}
        return subprocess.Popen(argv, cwd=self.checkout, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, start_new_session=True)

    def build(self, reload: str, *, mutant: bool = True) -> subprocess.CompletedProcess:
        proc = self.start(reload, mutant=mutant)
        out, _ = proc.communicate(timeout=60)
        return subprocess.CompletedProcess(proc.args, proc.returncode, out)

    def killed_during_build(self, signal_number: int) -> subprocess.CompletedProcess:
        proc = self.start("hang")
        started = self.stub_log / "reload-started"
        deadline = time.monotonic() + 30
        while not started.exists() and proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(started.exists(), "the stub build never started")
        os.killpg(proc.pid, signal_number)
        out, _ = proc.communicate(timeout=60)
        return subprocess.CompletedProcess(proc.args, proc.returncode, out)

    def saw_fault(self) -> bool:
        return (self.stub_log / "reload-saw").read_text().strip() == "1"

    def journal(self) -> Path:
        return self.checkout / ".git" / "oracle-mutant-files"

    def assert_clean(self) -> None:
        status = subprocess.run(["git", "-C", str(self.checkout), "status", "--porcelain", "--", "Packages"],
                                check=True, stdout=subprocess.PIPE, text=True).stdout
        self.assertEqual(status, "")
        self.assertFalse(self.journal().exists())

    def step_args(self) -> dict:
        argv = json.loads((self.stub_log / "step.json").read_text())
        return {name[2:]: value for name, value in zip(argv, argv[1:]) if name in ("--mutant", "--source-diff")}

    def test_the_build_compiles_the_fault_and_the_checkout_is_clean_after(self) -> None:
        result = self.build("ok")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.saw_fault())
        self.assertIn("reverted mutant app/fixture-off-by-one", result.stdout)
        args = self.step_args()
        self.assertEqual(args["mutant"], "app/fixture-off-by-one")
        self.assertRegex(args["source-diff"], r"^[0-9a-f]{64}$")
        self.assert_clean()
        clean = self.build("ok", mutant=False)
        self.assertEqual(clean.returncode, 0, clean.stdout)
        self.assertFalse(self.saw_fault())
        self.assertEqual(self.step_args(), {"source-diff": "none"})

    def test_a_failed_build_reverts_the_fault(self) -> None:
        result = self.build("fail")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(self.saw_fault())
        self.assert_clean()

    def test_term_during_the_build_reverts_the_fault(self) -> None:
        result = self.killed_during_build(signal.SIGTERM)
        self.assertEqual(result.returncode, 128 + signal.SIGTERM, result.stdout)
        self.assertTrue(self.saw_fault())
        self.assert_clean()

    def test_the_next_build_restores_what_a_killed_step_left(self) -> None:
        self.killed_during_build(signal.SIGKILL)
        self.assertIn("i + 1", (self.checkout / FIXTURE_SWIFT).read_text(), "SIGKILL runs no trap")
        self.assertTrue(self.journal().exists())
        result = self.build("ok", mutant=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("restored the files a killed mutant step left changed", result.stdout)
        self.assertFalse(self.saw_fault(), "the clean build compiled the leftover fault")
        self.assertEqual(self.step_args(), {"source-diff": "none"})
        self.assert_clean()

    def test_a_changed_product_source_is_refused_before_the_build(self) -> None:
        (self.checkout / FIXTURE_SWIFT).write_text("func index(_ i: Int) -> Int {\n    i * 2\n}\n")
        result = self.build("ok", mutant=False)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("tracked product sources differ from HEAD", result.stdout)
        self.assertIn(FIXTURE_SWIFT, result.stdout)
        self.assertFalse((self.stub_log / "reload-saw").exists(), "nothing was built")
        self.assertIn("i * 2", (self.checkout / FIXTURE_SWIFT).read_text(), "the edit is not discarded")

    def test_a_submodule_an_earlier_step_left_is_moved_to_the_gitlink(self) -> None:
        """The reused checkout's ghostty-next is at another commit (an earlier step's): the build gets the gitlink's."""
        sub = self.checkout / "ghostty-next"
        git = ["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "protocol.file.allow=always"]
        (self.checkout / ".gitmodules").write_text("".join(
            f'[submodule "{name}"]\n\tpath = {name}\n\turl = {self.checkout / name}\n' for name in SUBMODULES))
        subprocess.run(git + ["-C", str(self.checkout), "add", ".gitmodules"], check=True)
        subprocess.run(git + ["-C", str(self.checkout), "commit", "-q", "-m", "gitmodules"], check=True)
        subprocess.run(git + ["-C", str(sub), "commit", "-q", "--allow-empty", "-m", "an earlier step's commit"],
                       check=True)
        self.assertNotEqual(head_of(sub), self.gitlinks["ghostty-next"])
        result = self.build("ok", mutant=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.stub_log / "ghostty-next-head").read_text().strip(), self.gitlinks["ghostty-next"])

    def test_a_revert_that_fails_fails_the_step(self) -> None:
        result = self.build("lock")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("could not revert mutant app/fixture-off-by-one", result.stdout)
        self.assertTrue(self.journal().exists(), "the journal stays for the next build")
        (self.checkout / ".git" / "index.lock").unlink()
        again = self.build("ok", mutant=False)
        self.assertEqual(again.returncode, 0, again.stdout)
        self.assertFalse(self.saw_fault())
        self.assert_clean()


class UnitTests(unittest.TestCase):
    def test_maclease_is_never_the_client(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "maclease"
            path.write_text("#!/bin/sh\n")
            path.chmod(0o755)
            with self.assertRaises(fleet.UsageError):
                fleet.find_client(str(path))

    def test_encode_decode_round_trip(self) -> None:
        for name, value in (("suite", "alpha,beta"), ("filter", "alpha/*,beta/case-00?"), ("filter", "a b")):
            self.assertEqual(fleet.decode_args([fleet.encode_arg(name, value)]), [f"--{name}={value}"])
        self.assertEqual(fleet.encode_arg("suite", "alpha"), "--suite=alpha")

    def test_unpack_refuses_names_outside_the_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tarball = Path(tmp) / "bad.tar.gz"
            with tarfile.open(tarball, "w:gz") as archive:
                data = b"x"
                info = tarfile.TarInfo("../escape")
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            with self.assertRaises(fleet.UsageError):
                fleet.unpack(tarball, Path(tmp) / "dest")
            self.assertFalse((Path(tmp) / "escape").exists())

    def test_step_args_fit_the_controller(self) -> None:
        side = fleet.Side("launch-config", SHA, (("arm", "launch-config"),))
        selection = fleet.Selection(suites=("actions", "journeys"), filters=("actions/*",), repeat=2, retry_limit=3,
                                    seed=7, batch_limit=10)
        with tempfile.TemporaryDirectory() as tmp:
            fleet.make_shards(side, run_id="20261026T114552Z-abc123", total=64, selection=selection, out=Path(tmp))
        self.assertEqual(len(side.shards), 64)
        for shard in side.shards:
            self.assertRegex(shard.key, fleet.KEY_PATTERN)
            self.assertLessEqual(len(shard.args), fleet.MAX_STEP_ARGS)
            self.assertTrue(all(fleet.ARG_PATTERN.match(a) for a in shard.args), shard.args)

    def test_vm_only_options_are_refused(self) -> None:
        with redirect_stderr(io.StringIO()):
            self.assertEqual(fleet.main(["run", "--ref", SHA, "--jobs", "200"]), fleet.EXIT_USAGE)

    def test_step_refuses_unknown_forwarded_options(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, redirect_stderr(io.StringIO()):
            code = fleet.main(["step", "--ref", SHA, "--tag", "oracle", "--shard", "0/1", "--work", tmp,
                               "--artifact", "artifacts/oracle/x.tar.gz", "--dry-run", "--binary=/Applications/cmux.app"])
        self.assertEqual(code, fleet.EXIT_USAGE)


if __name__ == "__main__":
    unittest.main()
