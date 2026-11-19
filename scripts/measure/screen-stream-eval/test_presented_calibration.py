"""Key-to-presented rows need no hand-measured geometry: apple-high/apple-standard and rd-present call
`cmux-rd observe --marker-origin auto` unless all of the geometry is given, and say they need the
viewer's grants. No Mac: macOS tools and cmux-rd are stubs that record their arguments.

    python3 scripts/measure/screen-stream-eval/test_presented_calibration.py
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from test_apple_bytes import apple_fixture, stub  # noqa: E402

RECEIPT = ('{"schema":"cmux.presented-marker/1","complete":true,"n":3,"p50_ms":41.5,"p95_ms":58.25,'
           '"samples_us":[41500,40000,58250],"calibration":{"method":"auto"}}')

# cmux-rd stand-in: `observe` records its arguments and prints a complete receipt; `bench` (rd-present's
# presenting viewer) prints its window line, then its first frame, and waits to be stopped.
CMUX_RD = f"""
case "$1" in
  observe) printf '%s\\n' "$@" >"$EVAL_STATE/observe.args"; echo '{RECEIPT}' ;;
  bench)
    printf '%s\\n' "$@" >"$EVAL_STATE/bench.args"
    echo "{{\\"present_window\\": 91, \\"pid\\": $$}}"
    echo 'passive: first frame' >&2
    exec sleep 30 ;;
esac
"""


def run(script: str, args: list[str], env: dict) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(HERE / "targets" / script), *args], env=env,
                          capture_output=True, text=True, timeout=90)


class AppleAutoCalibration(unittest.TestCase):
    def latency(self, geometry: dict) -> tuple[subprocess.CompletedProcess, list[str], dict]:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            env, _, bin_ = apple_fixture(root)
            for key in ("EVAL_PRESENTED_MARKER_ORIGIN", "EVAL_PRESENTED_CELL_SIZE", "EVAL_PRESENTED_INPUT_POINT"):
                env.pop(key, None)
            env.update(geometry)
            stub(bin_, "cmux-rd", CMUX_RD)
            result = run("apple.sh", ["latency-view", "key", "3", str(root / "raw.json")], env)
            args = (root / "state/observe.args").read_text().split("\n") if (root / "state/observe.args").exists() else []
            raw = json.loads((root / "raw.json").read_text()) if (root / "raw.json").exists() else {}
            return result, args, raw

    def test_no_geometry_asks_observe_to_calibrate(self):
        result, args, raw = self.latency({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--marker-origin", args)
        self.assertEqual(args[args.index("--marker-origin") + 1], "auto")
        self.assertNotIn("--cell-size", args)
        self.assertNotIn("--at", args)
        self.assertEqual(raw["g2g_ms"], {"n": 3, "p50": 41.5, "p95": 58.25})

    def test_given_geometry_is_passed_through(self):
        result, args, _ = self.latency({"EVAL_PRESENTED_MARKER_ORIGIN": "10,12", "EVAL_PRESENTED_CELL_SIZE": "8",
                                        "EVAL_PRESENTED_INPUT_POINT": "200,16"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[args.index("--marker-origin") + 1], "10,12")
        self.assertEqual(args[args.index("--cell-size") + 1], "8")
        self.assertEqual(args[args.index("--at") + 1], "200,16")

    def test_observer_needs_the_viewer_grants(self):
        env = {**os.environ, "EVAL_PRESENTED_OBSERVER_BIN": "/x/cmux-rd"}
        self.assertEqual(run("apple.sh", ["caps"], env).stdout.strip(), "viewer-grants")
        env.pop("EVAL_PRESENTED_OBSERVER_BIN")
        caps = run("apple.sh", ["caps"], env)
        self.assertEqual((caps.returncode, caps.stdout.strip()), (0, ""))


class RdPresent(unittest.TestCase):
    def test_latency_binds_the_bench_window_and_calibrates(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            bin_, state = root / "bin", root / "state"
            bin_.mkdir()
            state.mkdir()
            (state / "token").write_text("ab" * 32)
            stub(bin_, "cmux-rd", CMUX_RD)
            env = {**os.environ, "EVAL_BIN": str(bin_), "EVAL_STATE": str(state), "EVAL_PEER": "172.20.21.249",
                   "EVAL_ROOT": str(HERE.parents[2])}
            raw, out = root / "raw.json", root / "out.json"
            result = run("rd-present.sh", ["latency-view", "key", "3", str(raw)], env)
            self.assertEqual(result.returncode, 0, result.stderr)
            bench = (state / "bench.args").read_text().split("\n")
            self.assertEqual(bench[bench.index("--present") + 1], "window")
            self.assertEqual(bench[bench.index("--addr") + 1], "172.20.21.249:4103")
            observe = (state / "observe.args").read_text().split("\n")
            self.assertEqual(observe[observe.index("--window") + 1], "91")
            self.assertEqual(observe[observe.index("--marker-origin") + 1], "auto")
            # The bench this view started is stopped when it ends.
            self.assertFalse((state / "present.pid").exists())
            report = run("rd-present.sh", ["latency-report", "key", str(raw), str(out)], env)
            self.assertEqual(report.returncode, 0, report.stderr)
            row = json.loads(out.read_text())
            self.assertEqual(row["g2g_ms"], {"n": 3, "p50": 41.5, "p95": 58.25})
            self.assertTrue(row["split"]["method"].startswith("rd-present: CGEventPostToPid"))

    def test_pointer_is_unavailable_not_an_error(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            env = {**os.environ, "EVAL_BIN": str(root), "EVAL_STATE": str(root)}
            raw, out = root / "raw.json", root / "out.json"
            self.assertEqual(run("rd-present.sh", ["latency-view", "pointer", "3", str(raw)], env).returncode, 0)
            run("rd-present.sh", ["latency-report", "pointer", str(raw), str(out)], env)
            self.assertTrue(json.loads(out.read_text())["split"]["method"].startswith("rd-present: pointer"))

    def test_caps_asks_for_viewer_grants(self):
        self.assertEqual(run("rd-present.sh", ["caps"], dict(os.environ)).stdout.strip(), "viewer-grants")


class DriverGeometry(unittest.TestCase):
    def test_partial_geometry_is_refused(self):
        result = subprocess.run(["bash", str(HERE.parent / "screen-stream-eval.sh"), "presented-observer=1",
                                 "presented-cell-size=8"], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 2)
        self.assertIn("or none for auto-calibration", result.stderr)


if __name__ == "__main__":
    unittest.main()
