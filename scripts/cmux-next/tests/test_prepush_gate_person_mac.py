#!/usr/bin/env python3
"""prepush-gate.py on a person's Mac: background priority, one gate at a time, one scanner at a time, a fixed limit.

2026-11-19 on cosmic-gray (a person's interactive Mac, in the fleet registry's reconcilers.never_on): load 58 on 15
cores, swap nearly full, the gate at 87% CPU among ten gits. On such a host the gate re-runs itself under
`taskpolicy -b` (macOS) or `nice -n 19`, so every check it starts runs at background priority, and waits for the
Mac's one gate turn (an flock) before it starts any check.

  python3 scripts/cmux-next/tests/test_prepush_gate_person_mac.py
"""
from __future__ import annotations

import fcntl
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

GATE = Path(__file__).resolve().parents[1] / "prepush-gate.py"
REPO = Path(__file__).resolve().parents[3]  # the checkout: the gate loads push_range.py from it
REAL_GIT = shutil.which("git")


def load_gate():
    spec = importlib.util.spec_from_file_location("prepush_gate_person_mac", GATE)
    gate = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = gate  # dataclasses look their module up by name
    spec.loader.exec_module(gate)
    return gate


REGISTRY = {
    "reconcilers": {"never_on": ["cosmic-gray"]},
    "machines": {
        "cosmic-gray": {"hostname": "cosmic-gray.local", "roles": ["agents"]},
        "air-blue": {"roles": ["leo-mac"]},
        "mini-7": {"hostname": "mini-7", "roles": ["mac-build"]},
    },
    "origins": {"mini-7": {"hostnames": ["mini-7.tailnet"]}},
}


class PersonMacTest(unittest.TestCase):
    def setUp(self):
        self.gate = load_gate()
        self.addCleanup(sys.modules.pop, "prepush_gate_person_mac", None)

    def test_the_registry_names_a_persons_mac(self):
        judge = self.gate.registry_person
        self.assertTrue(judge(REGISTRY, "cosmic-gray"))  # reconcilers.never_on
        self.assertTrue(judge(REGISTRY, "cosmic-gray.local"))  # by its hostname
        self.assertTrue(judge(REGISTRY, "air-blue"))  # a person role
        self.assertFalse(judge(REGISTRY, "mini-7.tailnet"))  # a fleet Mac
        self.assertIsNone(judge(REGISTRY, "someone-elses-laptop"))  # not listed

    def test_person_mac_reads_the_named_registry_and_the_override_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fleet-registry.json"
            path.write_text(json.dumps(REGISTRY))
            env = {"HOME": tmp, "CMUX_FLEET_REGISTRY": str(path)}
            self.assertTrue(self.gate.person_mac(env, hostname="cosmic-gray"))
            self.assertFalse(self.gate.person_mac(env, hostname="mini-7"))
            self.assertFalse(self.gate.person_mac({"HOME": tmp}, hostname="cosmic-gray"))  # no registry: as before
            self.assertFalse(self.gate.person_mac({**env, "CMUX_PREPUSH_PERSON_MAC": "0"}, hostname="cosmic-gray"))
            self.assertTrue(self.gate.person_mac({"HOME": tmp, "CMUX_PREPUSH_PERSON_MAC": "1"}, hostname="mini-7"))

    def test_a_persons_mac_runs_one_scanner_with_a_fixed_limit(self):
        self.assertGreater(self.gate.side_workers({}, cpus=15), 1)
        self.gate.PERSON_MAC = True
        self.assertEqual(self.gate.side_workers({}, cpus=15), 1)
        real = os.getloadavg
        os.getloadavg = lambda: (58.0 * (os.cpu_count() or 1), 0.0, 0.0)  # load 58 per core: never scaled up
        old = os.environ.pop("CMUX_NEXT_GATE_LIMIT_SECONDS", None)
        try:
            self.assertEqual(self.gate.gate_limit(), self.gate.PERSON_GATE_LIMIT_SECONDS)
        finally:
            os.getloadavg = real
            if old is not None:
                os.environ["CMUX_NEXT_GATE_LIMIT_SECONDS"] = old

    def test_a_second_turn_waits_while_the_first_is_held(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = self.gate.take_host_turn(tmp, 1)
            self.assertIsNotNone(first)
            try:
                t0 = time.monotonic()
                self.assertIsNone(self.gate.take_host_turn(tmp, 0.3, poll=0.05))
                self.assertGreaterEqual(time.monotonic() - t0, 0.3)
            finally:
                os.close(first)
            second = self.gate.take_host_turn(tmp, 1)
            self.assertIsNotNone(second)
            os.close(second)


class PersonMacGateRunTest(unittest.TestCase):
    """The gate as the hook runs it, with a fake `taskpolicy` first on PATH (found on macOS and Linux alike) that
    marks what it runs, and a `git` that logs whether it runs under that mark and when."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        self.log = self.tmp / "git.log"
        (bin_dir / "taskpolicy").write_text('#!/bin/sh\n[ "$1" = -b ] && shift\nexport FAKE_BACKGROUND=1\nexec "$@"\n')
        (bin_dir / "git").write_text(f'#!/bin/sh\necho "${{FAKE_BACKGROUND:-0}} $(date +%s)" >> "{self.log}"\n'
                                     f'exec "{REAL_GIT}" "$@"\n')
        for tool in ("taskpolicy", "git"):
            (bin_dir / tool).chmod(0o755)
        self.queue = self.tmp / "queue"
        self.queue.mkdir()
        self.env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_ACTIONS", "CMUX_PREPUSH_GATE_BACKGROUND")}
        self.env.update(PATH=f"{bin_dir}:{os.environ.get('PATH', '')}", CMUX_PREPUSH_QUEUE_DIR=str(self.queue))

    def gate(self, **env):
        return subprocess.run([sys.executable, "-I", str(GATE), "--repo", str(REPO), "--base", "HEAD", "--head", "HEAD",
                               "--only", "reserved", "--no-guardrails"],
                              env={**self.env, **env}, capture_output=True, text=True, timeout=120)

    def git_runs(self) -> list[tuple[str, int]]:
        if not self.log.exists():
            return []
        return [(mark, int(stamp)) for mark, stamp in (line.split() for line in self.log.read_text().splitlines())]

    def test_every_check_on_a_persons_mac_runs_at_background_priority(self):
        done = self.gate(CMUX_PREPUSH_PERSON_MAC="1")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("a person's Mac: one gate at a time, background priority", done.stderr)
        runs = self.git_runs()
        self.assertTrue(runs, "the gate ran no git")
        self.assertEqual({mark for mark, _ in runs}, {"1"}, "a git ran outside the background prefix")

    def test_elsewhere_the_gate_runs_as_before(self):
        done = self.gate(CMUX_PREPUSH_PERSON_MAC="0")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertNotIn("a person's Mac", done.stderr)
        self.assertEqual({mark for mark, _ in self.git_runs()}, {"0"})

    def hold_turn(self):
        fd = os.open(self.queue / f"cmux-prepush-gate.{os.getuid()}.lock", os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fd

    def test_a_second_gate_starts_no_check_until_the_first_ends(self):
        held = self.hold_turn()
        child = subprocess.Popen([sys.executable, "-I", str(GATE), "--repo", str(REPO), "--base", "HEAD", "--head",
                                  "HEAD", "--only", "reserved", "--no-guardrails"],
                                 env={**self.env, "CMUX_PREPUSH_PERSON_MAC": "1"}, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        try:
            time.sleep(3)
            self.assertIsNone(child.poll(), "the second gate did not wait for the turn")
            self.assertEqual(self.git_runs(), [], "the second gate ran a check while the first held the turn")
            released = int(time.time())
        finally:
            os.close(held)
        out, err = child.communicate(timeout=120)
        self.assertEqual(child.returncode, 0, out + err)
        self.assertIn("waiting for its turn", err)
        runs = self.git_runs()
        self.assertTrue(runs)
        self.assertGreaterEqual(min(stamp for _, stamp in runs), released)

    def test_a_turn_held_past_the_wait_refuses_and_checks_nothing(self):
        held = self.hold_turn()
        try:
            done = self.gate(CMUX_PREPUSH_PERSON_MAC="1", CMUX_PREPUSH_GATE_TURN_WAIT_SECONDS="1")
        finally:
            os.close(held)
        self.assertEqual(done.returncode, 1)
        self.assertIn("held this Mac's turn for 1s; push refused, nothing was checked", done.stdout)
        self.assertEqual(self.git_runs(), [])


if __name__ == "__main__":
    unittest.main()
