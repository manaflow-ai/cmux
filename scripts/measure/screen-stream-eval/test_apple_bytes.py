"""Apple window-view counts Screen Sharing.app's received bytes; no Mac: macOS tools are stubs."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("screen_eval", HERE / "eval.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

NONCE = "00112233445566778899aabbccddeeff"
PID, WINDOW = str(os.getpid()), "77"  # a live pid: the target samples its CPU


def stub(folder: Path, name: str, body: str) -> None:
    path = folder / name
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class AppleBytesTests(unittest.TestCase):
    def view(self, nettop: str | None, seconds: int = 3) -> dict:
        """Runs apple.sh window-view for SECONDS against stubs; NETTOP is the stub's body (None: no nettop)."""
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            bin_, tools, state = root / "bin", root / "tools", root / "state"
            for folder in (bin_, tools, state):
                folder.mkdir()
            stub(tools, "open", "exit 0\n")
            stub(tools, "osascript", "cat >/dev/null; exit 0\n")
            # Each capture differs from the last, so every sample is a change.
            stub(tools, "screencapture", 'for a; do out=$a; done; date +%s%N >"$out"\n')
            if nettop is not None:
                stub(tools, "nettop", nettop)
            stub(bin_, "screen-eval-window-id", 'echo "$3"\n')
            receipt = {"schema": "cmux.presented-marker-series/2", "complete": True, "host_identity_verified": True,
                       "nonce_observed": True, "expected_nonce": NONCE, "pid": int(PID), "window": int(WINDOW),
                       "first_changed_marker_ms": 5}
            stub(bin_, "cmux-rd", f"echo '{json.dumps(receipt)}'\n")
            env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "EVAL_ROOT": str(HERE.parents[2]),
                   "EVAL_BIN": str(bin_), "EVAL_STATE": str(state), "EVAL_PEER": "100.64.0.2",
                   "EVAL_APPLE_MODE": "high", "EVAL_SCREEN_SHARING_APP": str(root / "Screen Sharing.app"), "EVAL_SCENE_NONCE": NONCE,
                   "EVAL_PRESENTED_OBSERVER_BIN": str(bin_ / "cmux-rd"), "EVAL_PRESENTED_OBSERVER_PID": PID,
                   "EVAL_PRESENTED_OBSERVER_WINDOW": WINDOW, "EVAL_PRESENTED_MARKER_ORIGIN": "10,10",
                   "EVAL_PRESENTED_CELL_SIZE": "8"}
            raw = root / "window.raw"
            run = subprocess.run(["bash", str(HERE / "targets/apple.sh"), "window-view", str(seconds),
                                  str(root / "frame.png"), str(root / "go"), str(raw)],
                                 env=env, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertTrue((root / "go").exists())
            return json.loads(raw.read_text())

    def test_received_bytes_become_each_buckets_bytes(self):
        # nettop's cumulative count grows 125000 bytes a read: 1000 kbit per read.
        result = self.view('n=$(cat "$0.n" 2>/dev/null || echo 0); echo $((n + 1)) >"$0.n"\n'
                           'echo "time,,bytes_in,"\n'
                           f'echo "01:00:00.000000,Screen Sharing.{PID},$((n * 125000)),"\n')
        series, extra = result["series"], result["extra"]
        self.assertGreaterEqual(len(series), 2)
        self.assertTrue(all(row["bytes"] == 125000 for row in series), series)
        self.assertFalse(extra["bytes_unavailable"])
        self.assertIn("nettop bytes_in", extra["bytes_method"])
        # eval.py turns those rows into kbps (no longer null) for a phase that spans them.
        phases = {"idle": {"start_unix_ms": series[0]["unix_ms"] - series[0]["duration_ms"] - report.PHASE_GUARD_MS,
                           "end_unix_ms": series[-1]["unix_ms"]}}
        kbps = report.phase_numbers(series, phases)[0]
        self.assertIsNotNone(kbps["idle"])
        self.assertGreater(kbps["idle"], 0)

    def test_no_received_bytes_is_unavailable_not_zero(self):
        # The stream in another process: the viewer's count never moves.
        result = self.view(f'echo "time,,bytes_in,"; echo "01:00:00.000000,Screen Sharing.{PID},900,"\n')
        self.assertTrue(result["extra"]["bytes_unavailable"])
        self.assertTrue(all(row["bytes"] is None for row in result["series"]))

    def test_unreadable_nettop_is_unavailable(self):
        result = self.view("exit 1\n")
        self.assertTrue(result["extra"]["bytes_unavailable"])
        self.assertTrue(all(row["bytes"] is None for row in result["series"]))
        self.assertTrue(all(row["sampled_changes"] > 0 for row in result["series"][1:]))

    def test_summary_puts_targets_side_by_side(self):
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            rd = {"latency": {"key": {"p50_ms": 21.0}, "pointer": {"p50_ms": 24.5}},
                  "kbps": {"idle": 40.0, "typing": 900.0, "scroll": 6000.0},
                  "fps": {"idle": 1.0, "typing": 12.0, "scroll": 60.0}, "sampled_fps": dict.fromkeys(report.WINDOW_PHASES)}
            apple = {"latency": {}, "kbps": {"idle": 30.0, "typing": 1500.0, "scroll": 9000.0},
                     "fps": dict.fromkeys(report.WINDOW_PHASES), "sampled_fps": {"idle": 0.0, "typing": 5.0, "scroll": 9.0}}
            results = folder / "results.json"
            results.write_text(json.dumps({"targets": {"rd": rd, "apple-high": apple}}))
            report.summary(results, folder / "summary.md", None)
            text = (folder / "summary.md").read_text()
            self.assertIn("## Side by side", text)
            self.assertIn("| rd | 21.0 ms / 24.5 ms | 40 / 900 / 6000 | 1.0 / 12.0 / 60.0 |", text)
            self.assertIn("| apple-high | – / – | 30 / 1500 / 9000 | 0.0* / 5.0* / 9.0* |", text)
            self.assertIn("not decoded FPS", text)
            # One target alone has nothing to sit beside.
            results.write_text(json.dumps({"targets": {"rd": rd}}))
            report.summary(results, folder / "summary.md", None)
            self.assertNotIn("## Side by side", (folder / "summary.md").read_text())


if __name__ == "__main__":
    unittest.main()
