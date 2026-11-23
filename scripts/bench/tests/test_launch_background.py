"""launch-background: background-ready.sh's BR-RUN and BR-IDLE lines become rows per arm (and state)."""
from __future__ import annotations

import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.registry import load_all  # noqa: E402
from benchlib.bench import Context  # noqa: E402

NIGHTLY = {"channel": "nightly", "version": "4377899541301", "sha": None}


def ingest(path: Path) -> Context:
    bench = load_all()["launch-background"]
    ctx = Context(bench=bench, build=dict(NIGHTLY), host_role="fleet", args={})
    bench.ingest(ctx, path)
    return ctx


def run(arm: str, label: str, window: float | None, **extra) -> dict:
    return {"label": label, "window_on_screen": window, "active": None if window is None else window - 5,
            "frame_committed": None, "usable": None, "exited": arm == "cold", **extra}


IDLE = {"arm": "hide", "state": "hidden", "pid": 4242, "seconds": 600,
        "window": {"mw": 1.5, "cpu_pct": 0.2, "wakeups_per_s": 3.0, "kinds": {}},
        "memory": {"footprint_mb": 410.2, "rss_mb": 520.0, "processes": 9, "kinds": {}},
        "files": {"total": 812, "sockets": 40, "kinds": {}, "pids": []}, "sleep": {"lines": [], "can_sleep": True}}


class LaunchBackgroundIngest(unittest.TestCase):
    def test_log(self) -> None:
        lines = ['BR host cmux14 chip="Apple M4 Pro" macOS 27.0.1 session Aqua']
        for arm, base in (("cold", 1000.0), ("hide", 60.0)):
            lines.append(f"BR-RUN {arm} " + json.dumps(run(arm, "prime", 1200.0)))
            for i, delta in enumerate((0.0, 10.0, 20.0)):
                extra = {"reopen_since_request": {"reopen.window_shown": base + delta - 2}} if arm == "hide" else {}
                lines.append(f"BR-RUN {arm} " + json.dumps(run(arm, f"run{i + 1}", base + delta, **extra)))
        lines.append("BR-RUN hide " + json.dumps(run("hide", "run4", None, error="no window in 30 s")))
        lines.append("BR-IDLE hide " + json.dumps(IDLE))
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "step.log"
            log.write_text("\n".join(lines) + "\n")
            ctx = ingest(log)
        rows = {(r["metric"], r["labels"]["arm"], r["labels"].get("state")): r for r in ctx.rows}
        self.assertEqual(rows[("window_on_screen", "cold", None)]["value"], 1010.0)
        self.assertEqual(rows[("window_on_screen", "hide", None)]["value"], 70.0)
        self.assertEqual(rows[("window_on_screen", "hide", None)]["n"], 3)  # the priming launch and the failure left out
        self.assertEqual(rows[("failed_shows", "hide", None)]["value"], 1)
        self.assertEqual(rows[("failed_shows", "cold", None)]["value"], 0)
        self.assertEqual(rows[("exited_shows", "cold", None)]["value"], 3)
        self.assertEqual(rows[("reopen_window_shown", "hide", None)]["value"], 68.0)
        self.assertEqual(rows[("idle_mw", "hide", "hidden")]["value"], 1.5)
        self.assertEqual(rows[("idle_footprint_mb", "hide", "hidden")]["unit"], "MB")
        self.assertEqual(rows[("idle_sockets", "hide", "hidden")]["value"], 40)
        self.assertEqual(ctx.host["name"], "cmux14")
        self.assertTrue(all(r["harness"]["name"] == "scripts/measure/background-ready.sh" for r in ctx.rows))

    def test_report_tgz(self) -> None:
        runs = [dict(run("close", f"run{i}", 80.0 + i), arm="close", harness="background-ready") for i in (1, 2, 3)]
        files = {"./runs.jsonl": "".join(json.dumps(r) + "\n" for r in runs),
                 "./idle.jsonl": json.dumps(dict(IDLE, arm="close", state="closed")) + "\n"}
        with tempfile.TemporaryDirectory() as tmp:
            tgz = Path(tmp) / "report.tgz"
            with tarfile.open(tgz, "w:gz") as tar:
                for name, text in files.items():
                    data = text.encode()
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
            rows = {(r["metric"], r["labels"].get("state")): r for r in ingest(tgz).rows}
        self.assertEqual(rows[("window_on_screen", None)]["value"], 82.0)
        self.assertEqual(rows[("idle_cpu_pct", "closed")]["value"], 0.2)

    def test_registered(self) -> None:
        bench = load_all()["launch-background"]
        self.assertEqual(bench.harness, "scripts/measure/background-ready.sh")
        self.assertFalse(bench.nightly)


if __name__ == "__main__":
    unittest.main()
