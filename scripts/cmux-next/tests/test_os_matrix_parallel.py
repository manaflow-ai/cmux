#!/usr/bin/env python3
"""os-matrix.sh --parallel (p10-stability-200) with a stub cmux-ci, and the images.json host inventory.

--parallel submits one vm step per major at once (each with only its own tart-<digest> label), so each major
takes a VM on any host that caches its image. No fleet, no VM: the stub records when each step ran.

    python3 -I -m unittest scripts/cmux-next/tests/test_os_matrix_parallel.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / "scripts/cmux-next/os-matrix.sh"
IMAGES = REPO / "scripts/fuzz/macos-matrix/images.json"
BUILD = "0123456789abcdef01234567"
STEP_SECONDS = 1.5

# The stub cmux-ci: `run` logs its start and end, waits STEP_SECONDS and prints the step id and the verdict
# that STUB_VERDICTS gives its major (NONE: no verdict line); `artifact` writes a results tarball.
STUB = r'''#!/usr/bin/env python3
import io, json, os, sys, tarfile, time
args = sys.argv[1:]
log = os.environ["STUB_LOG"]
if args[0] == "run":
    major = args[args.index("--arg=--majors") + 1][len("--arg="):]
    labels = [a for a in args if a.startswith("--label=")]
    start = time.time()
    time.sleep(float(os.environ["STUB_SECONDS"]))
    first = major.split(",")[0]
    verdict = dict(v.split("=") for v in os.environ["STUB_VERDICTS"].split(","))[first]
    with open(log, "a") as f:
        f.write(json.dumps({"major": major, "labels": labels, "key": args[args.index("--key") + 1],
                            "start": start, "end": time.time()}) + "\n")
    print("cmux-ci: step %024x" % int(first))
    if verdict != "NONE":
        print("MATRIX VERDICT " + verdict)
elif args[0] == "artifact":
    major = str(int(args[1], 16))
    with tarfile.open(args[2], "w:gz") as tar:
        data = json.dumps({"ok": True}).encode()
        info = tarfile.TarInfo(major + "/result.json")
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
else:
    sys.exit("stub: unexpected " + " ".join(args))
'''


class ParallelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="os-matrix-parallel-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        repo = self.tmp / "repo"
        (repo / "scripts/fuzz/macos-matrix").mkdir(parents=True)
        shutil.copy(IMAGES, repo / "scripts/fuzz/macos-matrix/images.json")
        git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run([*git, "add", "."], check=True)
        subprocess.run([*git, "commit", "-qm", "images"], check=True)
        self.ref = subprocess.run([*git, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
        self.repo = repo
        self.stub = self.tmp / "cmux-ci"
        self.stub.write_text(STUB)
        self.stub.chmod(0o755)
        self.log = self.tmp / "runs.ndjson"

    def run_matrix(self, majors: str, verdicts: str, *extra: str) -> tuple[subprocess.CompletedProcess, Path, list]:
        out = self.tmp / "out"
        env = dict(os.environ, CMUX_CI=str(self.stub), STUB_LOG=str(self.log), STUB_VERDICTS=verdicts,
                   STUB_SECONDS=str(STEP_SECONDS))
        proc = subprocess.run(["bash", str(SCRIPT), "--build", BUILD, "--os", majors, "--ref", self.ref,
                               "--out", str(out), *extra], cwd=self.repo, env=env, capture_output=True, text=True,
                              timeout=60)
        runs = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return proc, out, runs

    def digest_label(self, major: str) -> str:
        pins = {i["major"]: i["digest"] for i in json.loads(IMAGES.read_text())["images"]}
        return "--label=tart-" + pins[major][len("sha256:"):][:32]

    def test_four_majors_run_at_once_one_label_each(self) -> None:
        started = time.monotonic()
        proc, out, runs = self.run_matrix("14,15,26,27", "14=PASS,15=PASS,26=PASS,27=PASS", "--parallel")
        elapsed = time.monotonic() - started
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("MATRIX VERDICT PASS", proc.stdout)
        self.assertEqual(sorted(r["major"] for r in runs), ["14", "15", "26", "27"])
        for run in runs:
            self.assertEqual(run["labels"], [self.digest_label(run["major"])])
            self.assertIn(f"-{run['major']}-smoke-a1", run["key"])
        # Every step was running while every other one was: the latest start is before the earliest end.
        self.assertLess(max(r["start"] for r in runs), min(r["end"] for r in runs))
        self.assertLess(elapsed, 4 * STEP_SECONDS)
        report = json.loads((out / "parallel.json").read_text())
        self.assertEqual(report["verdict"], "PASS")
        self.assertEqual({r["major"]: r["step"] for r in report["majors"]}["26"], "%024x" % 26)
        self.assertTrue((out / "step-27/27/result.json").exists())

    def test_child_key_is_the_single_major_key(self) -> None:
        self.run_matrix("14,26", "14=PASS,26=PASS", "--parallel")
        self.run_matrix("26", "26=PASS")
        keys = [json.loads(line)["key"] for line in self.log.read_text().splitlines()]
        self.assertEqual(len(keys), 3)
        self.assertIn(keys[2], keys[:2], "a re-run of one major re-attaches to its parallel step")

    def test_fail_beats_no_verdict(self) -> None:
        proc, out, _ = self.run_matrix("14,15,26", "14=PASS,15=FAIL,26=NONE", "--parallel")
        self.assertEqual(proc.returncode, 1, proc.stderr)
        verdicts = {r["major"]: r["verdict"] for r in json.loads((out / "parallel.json").read_text())["majors"]}
        self.assertEqual(verdicts, {"14": "PASS", "15": "FAIL", "26": "NO-VERDICT"})

    def test_no_verdict_exits_75(self) -> None:
        proc, _, _ = self.run_matrix("14,15", "14=PASS,15=NONE", "--parallel")
        self.assertEqual(proc.returncode, 75, proc.stderr)
        self.assertIn("MATRIX VERDICT NO-VERDICT", proc.stdout)

    def test_without_parallel_one_step_holds_every_label(self) -> None:
        proc, _, runs = self.run_matrix("14,15", "14=PASS,15=PASS")
        self.assertEqual(len(runs), 1, proc.stderr)
        self.assertEqual(runs[0]["labels"], [self.digest_label("14"), self.digest_label("15")])


class HostInventoryTest(unittest.TestCase):
    """images.json "hosts" lists the majors each Tart host caches; vm.sh and the controller trust it."""

    def test_hosts_are_consistent_with_the_pins(self) -> None:
        data = json.loads(IMAGES.read_text())
        pins = {i["major"]: i for i in data["images"]}
        names = [h["name"] for h in data["hosts"]]
        self.assertEqual(len(names), len(set(names)), "a host is listed twice")
        for host in data["hosts"]:
            self.assertIn(host["vm_slots"], (1, 2), f"{host['name']}: Apple allows at most 2 macOS guests")
            self.assertIsInstance(host["stability_lab"], bool)
            self.assertTrue(host["majors"], f"{host['name']} caches no image")
            for major in host["majors"]:
                self.assertIn(major, pins, f"{host['name']} lists {major}, which has no pinned image")
                floor = int(pins[major].get("host_os_min", "0"))
                self.assertGreaterEqual(int(host["host_os"]), floor,
                                        f"{host['name']} (macOS {host['host_os']}) cannot boot a {major} guest")


if __name__ == "__main__":
    unittest.main()
