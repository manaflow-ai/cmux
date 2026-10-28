#!/usr/bin/env python3
"""Tests for runnerd.py: request joining, receipt reuse, the quota scope, eviction and recovery.

Run: python3 -I scripts/cmux-next/oracle/runnerd_test.py (stdlib unittest, Linux only). The
systemd test runs when `systemd-run --user --scope` works here (the VM) and is skipped elsewhere.
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUNNERD = HERE / "runnerd.py"
sys.path.insert(0, str(HERE))

import runnerd  # noqa: E402

SHA_A = "a" * 40
SHA_B = "b" * 40


def systemd_scope_works() -> bool:
    user = [] if os.geteuid() == 0 else ["--user"]
    try:
        return subprocess.run(["systemd-run", *user, "--scope", "--quiet", "--collect", "true"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30).returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


class RunnerdCase(unittest.TestCase):
    scope = "none"

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="runnerd-test-")
        self.root = Path(self.tmp.name) / "root"
        self.counter = Path(self.tmp.name) / "count"

    def tearDown(self) -> None:
        info = runnerd.read_json(self.root / "dispatcher.json")
        if info and runnerd.process_start_time(int(info["pid"])):
            os.kill(int(info["pid"]), signal.SIGKILL)
        self.tmp.cleanup()

    def env(self, **extra: str) -> dict:
        env = {k: v for k, v in os.environ.items() if k != "RUNNERD_JOB"}
        env.update({"ORACLE_RUNNERD_SCOPE": self.scope, "ORACLE_RUNNERD_SLOTS": "2"})
        env.update(extra)
        return env

    def submit(self, sha: str, script: str, *options: str, **env: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(RUNNERD), "--root", str(self.root), "submit", "--sha", sha,
                               "--suite", "build", *options, "--", "sh", "-c", script],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env(**env),
                              timeout=120)

    def counting(self, label: str, seconds: float = 0.5, code: int = 0) -> str:
        return f"echo {label} >> {self.counter}; sleep {seconds}; echo out-{label}; exit {code}"

    def runs(self) -> list:
        return self.counter.read_text().split() if self.counter.exists() else []

    def receipt(self, sha: str, suite: str = "build", arm: str = "-", profile: str = "oracle") -> dict:
        digest = runnerd.Key(sha, suite, arm, profile).digest
        return json.loads((self.root / "jobs" / digest / "receipt.json").read_text())

    def settle(self) -> None:
        """Waits for the dispatcher to exit: it does once no job runs and its upkeep chores are done."""
        deadline = time.time() + 30
        while (self.root / "dispatcher.json").exists():
            self.assertLess(time.time(), deadline, "the dispatcher did not exit")
            time.sleep(0.05)


class JoiningTests(RunnerdCase):
    def test_twenty_submits_of_one_pair_run_two_jobs(self) -> None:
        with concurrent.futures.ThreadPoolExecutor(20) as pool:
            futures = [pool.submit(self.submit, sha, self.counting(sha[0], 1.0))
                       for sha in [SHA_A, SHA_B] * 10]
            results = [f.result() for f in futures]
        self.assertEqual(sorted(self.runs()), ["a", "b"])
        for index, result in enumerate(results):
            label = "a" if index % 2 == 0 else "b"
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, f"out-{label}\n")
        for sha in (SHA_A, SHA_B):
            receipt = self.receipt(sha)
            self.assertEqual(receipt["state"], "done")
            self.assertEqual(receipt["submits"], 10)
            self.assertEqual(receipt["joins"] + receipt["reuses"], 9)

    def test_finished_receipt_is_reused_without_running(self) -> None:
        first = self.submit(SHA_A, self.counting("a"))
        second = self.submit(SHA_A, self.counting("a"))
        self.assertEqual((first.returncode, second.returncode), (0, 0))
        self.assertEqual(second.stdout, "out-a\n")
        self.assertIn("reused job", second.stderr)
        self.assertEqual(self.runs(), ["a"])
        self.assertEqual(self.receipt(SHA_A)["reuses"], 1)

    def test_key_fields_and_extra_strings_make_separate_jobs(self) -> None:
        self.submit(SHA_A, self.counting("x"))
        self.submit(SHA_A, self.counting("x"), "--arm", "f6=new")
        self.submit(SHA_A, self.counting("x"), "--profile", "dev")
        self.submit(SHA_A, self.counting("x"), "--extra", "features=")
        self.assertEqual(self.runs(), ["x"] * 4)

    def test_key_path_content_is_part_of_the_key(self) -> None:
        recipe = Path(self.tmp.name) / "recipe.txt"
        recipe.write_text("one")
        self.submit(SHA_A, self.counting("x"), "--key-path", str(recipe))
        self.submit(SHA_A, self.counting("x"), "--key-path", str(recipe))
        recipe.write_text("two")
        self.submit(SHA_A, self.counting("x"), "--key-path", str(recipe))
        self.assertEqual(self.runs(), ["x", "x"])

    def test_failed_job_reaches_every_waiter_then_reruns_on_a_new_submit(self) -> None:
        with concurrent.futures.ThreadPoolExecutor(5) as pool:
            results = list(pool.map(lambda _: self.submit(SHA_A, self.counting("f", 1.0, 3)), range(5)))
        self.assertEqual([r.returncode for r in results], [3] * 5)
        self.assertTrue(all("out-f" in r.stdout for r in results))
        self.assertEqual(self.runs(), ["f"])
        again = self.submit(SHA_A, self.counting("f", 0.1, 0))
        self.assertEqual(again.returncode, 0)
        self.assertEqual(self.runs(), ["f", "f"])

    def test_failure_log_tail_is_printed(self) -> None:
        result = self.submit(SHA_A, "echo boom-on-stderr >&2; exit 4")
        self.assertEqual(result.returncode, 4)
        self.assertIn("| boom-on-stderr", result.stderr)

    def test_timeout_kills_the_job_group(self) -> None:
        result = self.submit(SHA_A, f"sleep 30 & echo started >> {self.counter}; wait", "--timeout", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out", result.stderr)
        self.assertTrue(self.receipt(SHA_A)["timedOut"])

    def test_slots_bound_concurrent_jobs(self) -> None:
        marker = Path(self.tmp.name) / "active"
        marker.mkdir()
        script = (f"touch {marker}/$$; ls {marker} | wc -l >> {self.counter}; sleep 0.5; rm {marker}/$$")
        shas = [c * 40 for c in "abcdef"]
        with concurrent.futures.ThreadPoolExecutor(6) as pool:
            list(pool.map(lambda sha: self.submit(sha, script), shas))
        self.assertEqual(len(self.runs()), 6)
        self.assertLessEqual(max(int(n) for n in self.runs()), 2)

    def test_submit_inside_a_job_is_refused(self) -> None:
        result = self.submit(SHA_A, self.counting("x"), RUNNERD_JOB="outer")
        self.assertEqual(result.returncode, 2)
        self.assertIn("inside a runnerd job", result.stderr)
        self.assertEqual(self.runs(), [])

    def test_abbreviated_sha_is_refused(self) -> None:
        result = self.submit("abc123", self.counting("x"))
        self.assertEqual(result.returncode, 2)

    def test_target_cache_dir_is_per_sha_and_profile(self) -> None:
        script = 'echo "$RUNNERD_TARGET_DIR"; echo data > "$RUNNERD_TARGET_DIR/f"'
        one = self.submit(SHA_A, script, "--target-cache").stdout.strip()
        two = self.submit(SHA_A, script + "; true", "--target-cache", "--extra", "features=x").stdout.strip()
        three = self.submit(SHA_B, script, "--target-cache").stdout.strip()
        self.assertEqual(one, two)
        self.assertEqual(Path(one).name, f"{SHA_A}-oracle")
        self.assertNotEqual(one, three)
        self.settle()
        index = json.loads((self.root / "index.json").read_text())
        self.assertIn(f"targets/{SHA_A}-oracle", index["entries"])

    def test_target_tag_selects_its_own_target_dir(self) -> None:
        script = 'echo "$RUNNERD_TARGET_DIR"'
        plain = self.submit(SHA_A, script, "--target-cache", "--extra", "features=").stdout.strip()
        tagged = self.submit(SHA_A, script, "--target-cache", "--target-tag", "feat-oracle").stdout.strip()
        self.assertEqual(Path(plain).name, f"{SHA_A}-oracle")
        self.assertEqual(Path(tagged).name, f"{SHA_A}-oracle-feat-oracle")
        refused = self.submit(SHA_A, script, "--target-tag", "feat-oracle")
        self.assertEqual(refused.returncode, 2)

    def test_two_jobs_never_share_a_target_dir_at_once(self) -> None:
        marker = Path(self.tmp.name) / "active"
        marker.mkdir()
        script = 'touch {m}/$$; ls {m} | wc -l >> {c}; sleep 0.5; rm {m}/$$'.format(m=marker, c=self.counter)
        with concurrent.futures.ThreadPoolExecutor(3) as pool:
            results = list(pool.map(lambda leaf: self.submit(SHA_A, script, "--target-cache", "--extra", leaf),
                                    ["leaf=0", "leaf=1", "leaf=2"]))
        self.assertEqual([r.returncode for r in results], [0, 0, 0])
        self.assertEqual(self.runs(), ["1", "1", "1"])

    def test_fresh_reruns_a_done_key(self) -> None:
        self.submit(SHA_A, self.counting("a", 0.1))
        self.submit(SHA_A, self.counting("a", 0.1))
        fresh = self.submit(SHA_A, self.counting("a", 0.1), "--fresh")
        self.assertEqual(fresh.returncode, 0)
        self.assertIn("queued job", fresh.stderr)
        self.assertEqual(self.runs(), ["a", "a"])

    def test_a_rerun_keeps_the_last_attempts_output(self) -> None:
        script = 'echo "$RUNNERD_OUT"; echo result > "$RUNNERD_OUT/r"; exit 5'
        first = Path(self.submit(SHA_A, script).stdout.strip())
        second = Path(self.submit(SHA_A, script).stdout.strip())
        self.assertNotEqual(first, second)
        self.assertEqual((first / "r").read_text(), "result\n")
        third = Path(self.submit(SHA_A, script).stdout.strip())
        self.settle()
        self.assertFalse(first.exists())
        self.assertTrue((second / "r").is_file())
        self.assertTrue((third / "r").is_file())

    def test_scratch_is_removed_however_the_job_ends(self) -> None:
        script = 'echo "$RUNNERD_SCRATCH"; mkdir "$RUNNERD_SCRATCH/wt"; echo x > "$RUNNERD_SCRATCH/wt/f"; sleep 30'
        result = self.submit(SHA_A, script, "--timeout", "1")
        self.assertIn("timed out", result.stderr)
        scratch = Path(result.stdout.strip())
        self.assertEqual(scratch.parent, self.root / "jobs" / self.receipt(SHA_A)["digest"])
        self.assertFalse(scratch.exists())
        self.settle()
        self.assertEqual(list((self.root / "trash").iterdir()), [])

    def test_a_reused_receipt_leaves_the_trash_to_the_dispatcher(self) -> None:
        self.submit(SHA_A, self.counting("a", 0.1))
        self.settle()
        leftover = self.root / "trash" / "big-evicted-target"
        leftover.mkdir()
        reused = self.submit(SHA_A, self.counting("a", 0.1))
        self.assertIn("reused job", reused.stderr)
        self.assertTrue(leftover.exists())

    def test_dispatcher_death_requeues_the_running_job(self) -> None:
        proc = subprocess.Popen([sys.executable, "-I", str(RUNNERD), "--root", str(self.root), "submit", "--sha", SHA_A,
                                 "--suite", "build", "--", "sh", "-c", self.counting("d", 2.0)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env())
        deadline = time.time() + 20
        while len(self.runs()) < 1 and time.time() < deadline:
            time.sleep(0.05)
        info = json.loads((self.root / "dispatcher.json").read_text())
        os.kill(int(info["pid"]), signal.SIGKILL)
        out, err = proc.communicate(timeout=60)
        self.assertEqual(proc.returncode, 0, err)
        self.assertEqual(out, "out-d\n")
        self.assertIn("starting another", err)
        self.assertEqual(self.runs(), ["d", "d"])
        self.assertEqual(self.receipt(SHA_A)["recovered"], 1)


@unittest.skipUnless(systemd_scope_works(), "systemd-run --scope is not available here")
class QuotaTests(RunnerdCase):
    scope = "systemd"

    def test_timeout_kills_setsid_processes_through_the_job_cgroup(self) -> None:
        pidfile = Path(self.tmp.name) / "escaped"
        script = f"setsid sh -c 'echo $$ > {pidfile}; exec sleep 300' & sleep 300"
        result = self.submit(SHA_A, script, "--timeout", "2")
        self.assertIn("timed out", result.stderr)
        escaped = int(pidfile.read_text())
        deadline = time.time() + 10
        while runnerd.process_start_time(escaped) is not None and time.time() < deadline:
            time.sleep(0.05)
        self.assertIsNone(runnerd.process_start_time(escaped), "a setsid process outlived its job")
        self.settle()
        self.assertFalse(Path(self.receipt(SHA_A)["cgroup"]).exists())

    def test_jobs_run_niced_inside_one_quota_scope(self) -> None:
        script = ('cg=$(cut -d: -f3 /proc/self/cgroup); echo "$cg"; cat "/sys/fs/cgroup$cg/../cpu.max" '
                  '"/sys/fs/cgroup$cg/../memory.max"; nice')
        result = self.submit(SHA_A, script)
        self.assertEqual(result.returncode, 0, result.stderr)
        cgroup, cpu, memory, niceness = result.stdout.split("\n")[:4]
        scope, job = cgroup.rsplit("/", 1)
        self.assertIn("cmux-oracle-runnerd-", scope)
        self.assertEqual(job, f"job-{runnerd.Key(SHA_A, 'build', '-', 'oracle').digest}-1")
        self.assertEqual(cpu, "24000000 100000")
        self.assertEqual(int(memory), 600 * 2**30)
        self.assertEqual(int(niceness), min(19, os.nice(0) + runnerd.NICE))


class EvictionTests(unittest.TestCase):
    def test_nothing_goes_below_the_high_watermark(self) -> None:
        entries = {"jobs/a": {"bytes": 94, "used": 1}, "targets/x": {"bytes": 1, "used": 2}}
        self.assertEqual(runnerd.plan_eviction(entries, 100, []), [])

    def test_least_recently_used_go_first_down_to_the_low_watermark(self) -> None:
        entries = {
            "targets/old": {"bytes": 40, "used": 1},
            "targets/mid": {"bytes": 40, "used": 2},
            "jobs/new": {"bytes": 40, "used": 3},
        }
        # budget 100: high 95, low 90; 120 -> drop old (80 <= 90) and stop.
        self.assertEqual(runnerd.plan_eviction(entries, 100, []), ["targets/old"])

    def test_busy_entries_are_kept(self) -> None:
        entries = {"targets/old": {"bytes": 60, "used": 1}, "targets/mid": {"bytes": 60, "used": 2}}
        self.assertEqual(runnerd.plan_eviction(entries, 100, ["targets/old"]), ["targets/mid"])

    def test_evict_moves_dirs_and_keeps_held_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            layout = runnerd.Layout(Path(tmp))
            layout.ensure()
            for name in ("targets/t1", "jobs/build", "jobs/run"):
                (layout.root / name).mkdir()
            request = runnerd.Request(runnerd.Key(SHA_A, "all", "-", "oracle"), ("true",), "/", {}, False, 10.0,
                                      (layout.root / "jobs/build/out/cmux-tui",))
            receipt = runnerd.new_receipt(layout, request, 1)
            (layout.root / "jobs/run/receipt.json").write_text(json.dumps({**receipt, "digest": "run"}))
            index = {"seq": 1, "entries": {"targets/t1": {"bytes": 60, "used": 1},
                                           "jobs/build": {"bytes": 60, "used": 2},
                                           "jobs/run": {"bytes": 1, "used": 3}}}
            victims = runnerd.evict(layout, index, 100, runnerd.busy_entries(layout))
            self.assertEqual(victims, ["targets/t1"])
            self.assertFalse((layout.root / "targets/t1").exists())
            self.assertTrue((layout.root / "jobs/build").exists())
            runnerd.empty_trash(layout)
            self.assertEqual(list(layout.trash.iterdir()), [])

    def test_refuses_to_run_off_linux(self) -> None:
        with unittest.mock.patch.object(runnerd.sys, "platform", "darwin"):
            self.assertEqual(runnerd.main(["status"]), 2)

    def test_hold_outside_the_root_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            layout = runnerd.Layout(Path(tmp) / "root")
            with self.assertRaises(runnerd.RunnerError):
                runnerd.hold_entry(layout, Path(tmp) / "elsewhere")


if __name__ == "__main__":
    unittest.main()
