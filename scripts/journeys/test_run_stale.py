#!/usr/bin/env python3
"""run.py never reports a result that this run did not write (STATUS 1362, cmux-ad 12:10Z): no fleet, no ssh.

    python3 scripts/journeys/test_run_stale.py

On 2026-10-31 an R3 round whose relaunch failed reported the 11:22Z result.json that an older round had left in the
reused folder. These cases use a stand-in capture-host and a stand-in for the ssh calls:
- a folder with an earlier round's result.json (a pass and a fail) and a launch that fails: "not run", never the old
  result; the same through main() with a reused --out folder;
- the mini's out folder holds a result.json of another run (no run id, or another run id): "not run: stale or foreign
  result";
- the driver's own result (this run's id and start time) still counts, and every result.json and results.jsonl row
  names the run id;
- harness pinning (coordinator 2026-10-31): run.py packs the harness from disk at each lease, so a round run from a
  checkout with uncommitted harness files, or one that moved to another commit during the run, is "not run" with
  "harness: unpinned"; each result.json records the harness commit and its uncommitted files.
"""
import io
import json
import os
import shutil
import sys
import tarfile
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "cmux-next"))
import run  # noqa: E402

JOURNEY = "smoke-dogfood"

FAKE_CH = r"""#!/bin/sh
echo "$*" >> "$CH_LOG"
case "$1" in
  acquire) echo "slot-cmux99-abc" ;;
  slot-info) echo "host=cmux99 slot=1 root=/tmp/fake-root" ;;
  launch) if [ -n "$CH_LAUNCH_FAILS" ]; then echo "ch-r3: relaunch failed: the app did not quit" >&2; exit 2; fi
          echo "pid=1 socket=/tmp/fake.sock bundle_id=x app=/tmp/fake.app" ;;
  release) echo released ;;
esac
"""


def old_result(status, started_at="2026-10-31T11:22:00Z", **extra):
    return dict({"id": JOURNEY, "status": status, "reason": "" if status == "pass" else "step 1 (smoke_ready): old",
                 "started_at": started_at, "seconds": 30, "nonce": "234567", "steps": [], "evidence": []}, **extra)


def tar_of(files):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for name, body in files.items():
            data = json.dumps(body).encode()
            info = tarfile.TarInfo("./" + name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class Done:
    def __init__(self, stdout=b"", returncode=0):
        self.stdout, self.stderr, self.returncode = stdout, b"", returncode


class Stale(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        ch = self.tmp / "capture-host"
        ch.write_text(FAKE_CH)
        ch.chmod(0o755)
        self.saved_env = dict(os.environ)
        os.environ.update(CAPTURE_HOST=str(ch), CH_LOG=str(self.tmp / "ch.log"))
        os.environ.pop("CH_LAUNCH_FAILS", None)
        self.saved = (run.remote, run.job_status, getattr(run, "harness_state", None))
        self.saved_pattern = run.RESULT_FILE
        # The checkout's state at the run's start and at each lease; a clean checkout at one commit unless a test says.
        self.harness = [{"commit": "c" * 40, "dirty": [], "detached": True}]
        run.harness_state = lambda: self.harness[0] if len(self.harness) == 1 else self.harness.pop(0)
        # Where a run.py with the open-P0 ledger (the gate branch) appends its rows: never the real ledger.
        self.saved_ledger = getattr(run, "P0_LEDGER", None)
        if self.saved_ledger is not None:
            run.P0_LEDGER = self.tmp / "ledger"
        # What the stand-in mini's out folder holds after the driver: {name: json}; a callable gets the driver command.
        self.mini_files = lambda driver_cmd: {}
        self.driver_cmds = []
        self.cut_tar = False

        def remote(host, script, input=None, timeout=600, check=True):
            if "driver.py" in script:
                self.driver_cmds.append(script)
                return Done(b"journey smoke-dogfood: done\n")
            if "tar c" in script:
                cmd = self.driver_cmds[-1] if self.driver_cmds else ""
                if self.cut_tar:
                    return Done(tar_of(self.mini_files(cmd))[:700])
                return Done(tar_of(self.mini_files(cmd)))
            if "cmux-ci artifact" in script:
                return Done(b"/tmp/x/build/cmux DEV t.app")
            return Done()
        run.remote = remote
        run.job_status = lambda job: {"id": job, "state": "done", "ref": "a" * 40, "tag": "t"}

    def tearDown(self):
        run.remote, run.job_status, harness_state = self.saved
        if harness_state is not None:
            run.harness_state = harness_state
        if self.saved_ledger is not None:
            run.P0_LEDGER = self.saved_ledger
        os.environ.clear()
        os.environ.update(self.saved_env)

    def spec(self):
        return {"id": JOURNEY, "budget_seconds": 60, "steps": []}

    def lease(self, out):
        return run.run_lease([self.spec()], {"id": "JOB1", "commit": "a" * 40, "tag": "t"}, out, 1.0)[JOURNEY]

    def test_failed_relaunch_in_a_used_folder_is_not_run(self):
        for status in ("pass", "fail"):
            with self.subTest(old=status):
                out = self.tmp / f"s1-{status}"
                (out / JOURNEY).mkdir(parents=True)
                (out / JOURNEY / "result.json").write_text(json.dumps(old_result(status)))
                os.environ["CH_LAUNCH_FAILS"] = "1"
                got = self.lease(out)
                self.assertEqual(got["status"], "not run", got)
                self.assertIn("relaunch failed", got["reason"])
                self.assertFalse(self.driver_cmds, "the driver must not start after a failed launch")

    def test_main_with_a_used_out_folder_reports_not_run(self):
        out = self.tmp / "s1"
        (out / JOURNEY).mkdir(parents=True)
        (out / JOURNEY / "result.json").write_text(json.dumps(old_result("pass")))
        (out / "results.jsonl").write_text(json.dumps({"id": JOURNEY, "status": "pass", "build_job": "JOB1"}) + "\n")
        os.environ["CH_LAUNCH_FAILS"] = "1"
        code = run.main(["--build", "JOB1", "--journey", JOURNEY, "--out", str(out)])
        rows = [json.loads(l) for l in (out / "results.jsonl").read_text().splitlines()]
        self.assertEqual([r["status"] for r in rows], ["not run"], rows)
        self.assertNotEqual(code, 0)

    def test_a_foreign_result_on_the_mini_is_not_run(self):
        for name, stamp in (("no run id", {}), ("another run id", {"run_id": "20261031T112200Z-0badc0de",
                                                                     "run_started_at": "2026-10-31T11:22:00Z"})):
            with self.subTest(name):
                self.mini_files = lambda cmd, stamp=stamp: {f"{JOURNEY}/result.json": old_result("pass", **stamp)}
                out = self.tmp / ("fresh-" + name.replace(" ", "-"))
                self.assertIn(run.main(["--build", "JOB1", "--journey", JOURNEY, "--out", str(out)]), (1, 75))
                row = json.loads((out / "results.jsonl").read_text().splitlines()[0])
                self.assertEqual(row["status"], "not run", row)
                self.assertIn("stale or foreign result", row["reason"])

    def test_this_runs_own_result_counts(self):
        def own(cmd):
            words = cmd.split()
            run_id = words[words.index("--run-id") + 1].strip("'")
            started = words[words.index("--run-started-at") + 1].strip("'")
            return {f"{JOURNEY}/result.json": old_result("pass", started_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                                         run_id=run_id, run_started_at=started)}
        self.mini_files = own
        out = self.tmp / "fresh"
        self.assertEqual(run.main(["--build", "JOB1", "--journey", JOURNEY, "--out", str(out)]), 0)
        row = json.loads((out / "results.jsonl").read_text().splitlines()[0])
        self.assertEqual(row["status"], "pass", row)
        stamp = json.loads((out / "run.json").read_text())
        self.assertEqual(row["run_id"], stamp["run_id"])
        self.assertIn(stamp["run_id"], self.driver_cmds[-1])

    def own_result(self, cmd):
        words = cmd.split()
        return {f"{JOURNEY}/result.json": old_result("pass", started_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                                     run_id=words[words.index("--run-id") + 1].strip("'"),
                                                     run_started_at=words[words.index("--run-started-at") + 1].strip("'"))}

    def play(self, name):
        self.mini_files = self.own_result
        out = self.tmp / name
        code = run.main(["--build", "JOB1", "--journey", JOURNEY, "--out", str(out)])
        row = json.loads((out / "results.jsonl").read_text().splitlines()[0])
        return code, row, json.loads((out / JOURNEY / "result.json").read_text())

    def test_uncommitted_harness_files_make_a_pass_not_run(self):
        for when in ("at the start", "at the lease"):
            with self.subTest(when):
                dirty = {"commit": "c" * 40, "dirty": [" M scripts/journeys/ext_fuzz.py"], "detached": False}
                clean = {"commit": "c" * 40, "dirty": [], "detached": False}
                self.harness = [dirty, clean] if when == "at the start" else [clean, dirty]
                code, row, result = self.play("dirty-" + when.replace(" ", "-"))
                self.assertEqual(row["status"], "not run", row)
                self.assertTrue(row["reason"].startswith("harness: unpinned"), row["reason"])
                self.assertIn("ext_fuzz.py", row["reason"])
                self.assertEqual(code, 75)
                self.assertEqual(result["harness"]["commit"], "c" * 40)
                self.assertTrue(result["harness"]["dirty"])
                self.assertEqual(result["harness"]["status"], "pass")

    def test_a_checkout_that_moved_during_the_run_makes_a_pass_not_run(self):
        self.harness = [{"commit": "c" * 40, "dirty": [], "detached": False},
                        {"commit": "d" * 40, "dirty": [], "detached": False}]
        _, row, result = self.play("moved")
        self.assertEqual(row["status"], "not run", row)
        self.assertIn("harness: unpinned", row["reason"])
        self.assertEqual(result["harness"]["commit"], "d" * 40)

    def test_a_clean_pinned_harness_counts_and_is_recorded(self):
        code, row, result = self.play("pinned")
        self.assertEqual((code, row["status"]), (0, "pass"), row)
        self.assertEqual(result["harness"], {"commit": "c" * 40, "dirty": [], "detached": True, "pinned": True})
        self.assertEqual(row["harness"]["commit"], "c" * 40)

    def test_a_used_folder_keeps_no_old_file_at_the_usual_paths(self):
        out = self.tmp / "used"
        (out / JOURNEY).mkdir(parents=True)
        (out / JOURNEY / "result.json").write_text(json.dumps(old_result("pass")))
        (out / JOURNEY / "fuzz.json").write_text("{}")
        (out / "run.json").write_text(json.dumps({"run_id": "old"}))
        run.main(["--build", "JOB1", "--journey", JOURNEY, "--out", str(out)])
        self.assertFalse((out / JOURNEY).exists(), "the old journey folder is still at <id>/")
        self.assertNotEqual(json.loads((out / "run.json").read_text())["run_id"], "old")
        self.assertTrue(list(out.glob("run.json.earlier-*")) and list(out.glob(f"{JOURNEY}.old-*")))

    def test_a_refused_result_folder_is_moved_aside(self):
        self.mini_files = lambda cmd: {f"{JOURNEY}/result.json": old_result("pass")}
        out = self.tmp / "foreign"
        run.main(["--build", "JOB1", "--journey", JOURNEY, "--out", str(out)])
        row = json.loads((out / "results.jsonl").read_text().splitlines()[0])
        self.assertEqual((row["status"], row["clip"], row["checks"]), ("not run", None, []), row)
        self.assertFalse((out / JOURNEY).exists())
        self.assertTrue(list(out.glob(f"{JOURNEY}.foreign-*")))

    def test_an_unpinned_result_json_says_not_run_on_disk(self):
        self.harness = [{"commit": "c" * 40, "dirty": [" M scripts/journeys/driver.py"], "detached": False}]
        def own_with_fuzz(cmd):
            files = self.own_result(cmd)
            files[f"{JOURNEY}/fuzz.json"] = {"failure": {"oracle": "x"}}
            return files
        self.mini_files = own_with_fuzz
        out = self.tmp / "unpinned-disk"
        run.RESULT_FILE = __import__("re").compile(run.RESULT_FILE.pattern.replace("restore-trace", "fuzz\\.json|restore-trace"))
        try:
            run.main(["--build", "JOB1", "--journey", JOURNEY, "--out", str(out)])
        finally:
            run.RESULT_FILE = self.saved_pattern
        on_disk = json.loads((out / JOURNEY / "result.json").read_text())
        self.assertEqual(on_disk["status"], "not run")
        self.assertIn("harness: unpinned", on_disk["reason"])
        self.assertFalse((out / JOURNEY / "fuzz.json").exists())

    def test_a_cut_short_tar_is_not_run_not_a_crash(self):
        self.mini_files = self.own_result
        self.cut_tar = True
        out = self.tmp / "cut"
        self.assertEqual(run.main(["--build", "JOB1", "--journey", JOURNEY, "--out", str(out)]), 75)
        row = json.loads((out / "results.jsonl").read_text().splitlines()[0])
        self.assertEqual(row["status"], "not run", row)

    def test_a_harness_edit_while_packing_is_unpinned(self):
        clean = {"commit": "c" * 40, "dirty": [], "detached": True}
        edited = {"commit": "c" * 40, "dirty": [" M scripts/journeys/ext_smoke.py"], "detached": True}
        self.harness = [clean, clean, edited, edited]
        _, row, _ = self.play("packing")
        self.assertEqual(row["status"], "not run", row)
        self.assertIn("harness: unpinned", row["reason"])

    def test_default_folder_names_the_run_id(self):
        os.environ["CH_LAUNCH_FAILS"] = "1"
        root = run.ROOT / "artifacts" / "journeys"
        before = set(root.iterdir()) if root.is_dir() else set()
        run.main(["--build", "JOB1abcdefghijk", "--journey", JOURNEY])
        folders = [p for p in root.iterdir() if p not in before and p.name.startswith("JOB1abcdefgh-")]
        try:
            self.assertEqual(len(folders), 1, folders)
            stamp = json.loads((folders[0] / "run.json").read_text())
            self.assertIn(stamp["run_id"], folders[0].name)
        finally:
            for folder in folders:
                shutil.rmtree(folder)

if __name__ == "__main__":
    unittest.main()
