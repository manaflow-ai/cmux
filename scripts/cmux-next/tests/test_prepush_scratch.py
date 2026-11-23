#!/usr/bin/env python3
"""prepush-gate.py removes its own scratch however it ends, and sweeps what an ended run left.

2026-11-23: 25 `cmux-prepush-*` dirs of base and head trees, 5.1 GB, sat in one Linux host's /tmp, the oldest four
days old. The gate made them in a `with TemporaryDirectory`, so a run the watchdog ended (os._exit), the hook's
limit stopped (SIGTERM, then SIGKILL) or a closed terminal ended (SIGHUP) left its copy, and nothing removed it.

  python3 scripts/cmux-next/tests/test_prepush_scratch.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

GATE = Path(__file__).resolve().parents[1] / "prepush-gate.py"
HAS_PROC = Path("/proc/self/cwd").exists()


def load_gate():
    spec = importlib.util.spec_from_file_location("prepush_gate_scratch_under_test", GATE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses look their module up by name
    spec.loader.exec_module(module)
    return module


gate = load_gate()
LATER = 3 * gate.SCRATCH_SWEEP_AGE_NO_PROC_SECONDS  # past every age bound


def dead_pid() -> int:
    child = subprocess.Popen([sys.executable, "-c", ""])
    child.wait()
    return child.pid


class ScratchDirTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="scratch-test-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(self.root, ignore_errors=True))
        real = tempfile.tempdir
        tempfile.tempdir = str(self.root)
        self.addCleanup(setattr, tempfile, "tempdir", real)

    def test_a_finished_run_removes_its_scratch(self):
        with gate.scratch_dir() as tmp:
            Path(tmp, "head").mkdir()
            Path(tmp, "head", "f").write_text("x")
            owner = json.loads(Path(tmp, gate.SCRATCH_OWNER).read_text())
            self.assertEqual(owner["pid"], os.getpid())
            self.assertIn(tmp, gate._LIVE_SCRATCH)
        self.assertFalse(os.path.lexists(tmp))
        self.assertNotIn(tmp, gate._LIVE_SCRATCH)

    def test_a_failed_run_removes_its_scratch(self):
        with self.assertRaises(RuntimeError):
            with gate.scratch_dir() as tmp:
                Path(tmp, "base").mkdir()
                raise RuntimeError("a check crashed")
        self.assertFalse(os.path.lexists(tmp))

    def test_a_run_stopped_by_sigterm_removes_its_scratch_and_still_dies_of_it(self):
        code = (
            "import importlib.util, sys, time\n"
            f"spec = importlib.util.spec_from_file_location('g', {str(GATE)!r})\n"
            "g = importlib.util.module_from_spec(spec); sys.modules['g'] = g; spec.loader.exec_module(g)\n"
            "g.remove_scratch_on_signals()\n"
            "with g.scratch_dir() as tmp:\n"
            "    print(tmp, flush=True)\n"
            "    time.sleep(60)\n"
        )
        env = dict(os.environ, TMPDIR=str(self.root))
        child = subprocess.Popen([sys.executable, "-I", "-c", code], stdout=subprocess.PIPE, text=True, env=env)
        try:
            tmp = child.stdout.readline().strip()
            self.assertTrue(os.path.isdir(tmp))
            child.send_signal(signal.SIGTERM)
            child.wait(timeout=20)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
        self.assertEqual(child.returncode, -signal.SIGTERM)
        self.assertFalse(os.path.lexists(tmp))


class SweepTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="sweep-test-")).resolve()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.root, ignore_errors=True))

    def scratch(self, name: str, owner: dict | None = None) -> Path:
        path = self.root / name
        (path / "head").mkdir(parents=True)
        (path / "head" / "file").write_text("tree")
        if owner is not None:
            (path / gate.SCRATCH_OWNER).write_text(json.dumps(owner))
        return path

    def sweep(self, now: float | None = None) -> list[str]:
        return gate.sweep_scratch(str(self.root), now=time.time() + LATER if now is None else now)

    def test_an_old_unheld_dir_with_no_owner_file_is_removed(self):
        old = self.scratch("cmux-prepush-1bfsj8fj")
        highlights = self.scratch("cmux-prepush-highlights-ab_cd123")
        self.assertEqual(sorted(self.sweep()), sorted([str(old), str(highlights)]))
        self.assertFalse(old.exists())
        self.assertFalse(highlights.exists())

    def test_a_young_dir_with_no_owner_file_is_kept(self):
        young = self.scratch("cmux-prepush-qc_fbun6")
        self.assertEqual(self.sweep(now=time.time()), [])
        self.assertTrue(young.exists())

    def test_a_dead_owners_dir_is_removed_at_once(self):
        dead = self.scratch("cmux-prepush-nai4l6vm", {"pid": dead_pid(), "start": "0"})
        self.assertEqual(self.sweep(now=time.time()), [str(dead)])
        self.assertFalse(dead.exists())

    def test_a_live_owners_dir_is_kept_however_old(self):
        live = self.scratch("cmux-prepush-mbuv53s2", {"pid": os.getpid(), "start": gate._process_start(os.getpid())})
        self.assertEqual(self.sweep(), [])
        self.assertTrue(live.exists())

    def test_a_reused_pid_does_not_keep_a_dead_runs_dir(self):
        if not HAS_PROC:
            self.skipTest("start times come from /proc")
        reused = self.scratch("cmux-prepush-dkofotek", {"pid": os.getpid(), "start": "1"})
        self.assertEqual(self.sweep(), [str(reused)])

    @unittest.skipUnless(HAS_PROC, "holders come from /proc")
    def test_a_dir_a_process_holds_is_kept(self):
        cwd = self.scratch("cmux-prepush-i3yg2s6x")
        open_file = self.scratch("cmux-prepush-8g76yf94")
        named = self.scratch("cmux-prepush-j24fzybm")
        free = self.scratch("cmux-prepush-nlj1l82r")
        holders = [
            subprocess.Popen(["sleep", "60"], cwd=cwd / "head"),
            subprocess.Popen([sys.executable, "-c", "import sys, time; f = open(sys.argv[1]); time.sleep(60)",
                              str(open_file / "head" / "file")]),
            subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", str(named / "head")]),
        ]
        try:
            time.sleep(0.5)  # the opener has its file open
            self.assertEqual(self.sweep(), [str(free)])
        finally:
            for holder in holders:
                holder.kill()
                holder.wait()
        for path in (cwd, open_file, named):
            self.assertTrue((path / "head" / "file").exists(), path)

    def test_without_proc_the_longer_age_is_the_only_evidence(self):
        mid = self.scratch("cmux-prepush-rfkevzag")
        between = time.time() + (gate.SCRATCH_SWEEP_AGE_SECONDS + gate.SCRATCH_SWEEP_AGE_NO_PROC_SECONDS) / 2
        no_proc = str(self.root / "no-proc")
        self.assertEqual(gate.sweep_scratch(str(self.root), now=between, proc=no_proc), [])
        self.assertEqual(gate.sweep_scratch(str(self.root), now=time.time() + LATER, proc=no_proc), [str(mid)])

    def test_a_symlink_is_never_followed(self):
        outside = Path(tempfile.mkdtemp(prefix="sweep-outside-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(outside, ignore_errors=True))
        (outside / "keep").write_text("not ours")
        link = self.root / "cmux-prepush-nnme_udy"
        link.symlink_to(outside, target_is_directory=True)
        inner = self.scratch("cmux-prepush-iwlnygl_")
        (inner / "head" / "out").symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.sweep(), [str(inner)])
        self.assertTrue(link.is_symlink())
        self.assertEqual((outside / "keep").read_text(), "not ours")

    def test_other_names_are_never_touched(self):
        for name in ("cmux-prepush-gate-ivrynaj9", "cmux-prepush-", "cmux-prepush-toolongname", "other-1bfsj8fj"):
            self.scratch(name)
        self.assertEqual(self.sweep(), [])

    def test_a_failed_sweep_logs_one_line_and_never_raises(self):
        real = gate.sweep_scratch
        gate.sweep_scratch = lambda *a, **k: (_ for _ in ()).throw(PermissionError("denied"))
        try:
            import contextlib
            import io
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                gate.sweep_scratch_safely()
        finally:
            gate.sweep_scratch = real
        self.assertEqual(err.getvalue().count("\n"), 1)
        self.assertIn("scratch sweep failed", err.getvalue())

    def test_the_off_switch_skips_the_sweep(self):
        called = []
        real = gate.sweep_scratch
        gate.sweep_scratch = lambda *a, **k: called.append(1) or []
        os.environ[gate.SCRATCH_SWEEP_OFF] = "0"
        try:
            gate.sweep_scratch_safely()
        finally:
            gate.sweep_scratch = real
            os.environ.pop(gate.SCRATCH_SWEEP_OFF, None)
        self.assertEqual(called, [])


if __name__ == "__main__":
    unittest.main()
