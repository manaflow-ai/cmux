#!/usr/bin/env python3
"""peer_idle.py (perf-idle-ab.sh peer=): one idle read of a peer app becomes bench_memory.py's sample shape, each
process summed into its kind and RFD 0062 group, so perf-idle-ab's summary and NOW's idle-footprint reconciler
read Claude desktop and ChatGPT desktop as they read cmux NEXT.
Run: python3 -I scripts/perf-bench/tests/test_peer_idle.py"""
import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import peer_idle  # noqa: E402  (imports procs lazily through rivals, so this runs on Linux)

ELECTRON = {"mb": 612.4, "processes": 6, "pids": [
    {"pid": 10, "kind": "main", "command": "/x/Claude.app/Contents/MacOS/Claude", "footprint_mb": 180.2},
    {"pid": 11, "kind": "renderer", "command": "Claude Helper (Renderer) --type=renderer", "footprint_mb": 250.1},
    {"pid": 12, "kind": "renderer", "command": "Claude Helper (Renderer) --type=renderer", "footprint_mb": 60.0},
    {"pid": 13, "kind": "gpu", "command": "Claude Helper (GPU) --type=gpu-process", "footprint_mb": 70.0},
    {"pid": 14, "kind": "utility:NetworkService", "command": "--type=utility", "footprint_mb": 30.1},
    {"pid": 15, "kind": "chrome_crashpad_handler", "command": "crashpad", "footprint_mb": 22.0},
]}
NATIVE = {"mb": 301.0, "processes": 3, "pids": [
    {"pid": 20, "kind": "main", "command": "/x/ChatGPT.app/Contents/MacOS/ChatGPT", "footprint_mb": 240.0},
    {"pid": 21, "kind": "webkit-webcontent", "command": "com.apple.WebKit.WebContent", "footprint_mb": 50.0},
    {"pid": 22, "kind": "webkit-gpu", "command": "com.apple.WebKit.GPU", "footprint_mb": 11.0},
]}


class SampleShape(unittest.TestCase):
    def test_kinds_sum_processes_of_one_kind(self):
        s = peer_idle.sample(ELECTRON, 60)
        self.assertEqual(s["kinds"]["renderer"], {"footprint_mb": 310.1, "n": 2})
        self.assertEqual(s["kinds"]["main"]["footprint_mb"], 180.2)
        self.assertEqual(list(s["kinds"])[0], "renderer")  # largest first

    def test_groups_follow_rivals(self):
        s = peer_idle.sample(ELECTRON, 60)
        self.assertEqual(s["groups"]["renderer"], 310.1)
        self.assertEqual(s["groups"]["gpu"], 70.0)
        self.assertEqual(s["groups"]["app"], 210.3)  # main + utility
        self.assertEqual(s["groups"]["other"], 22.0)
        self.assertEqual({r["pid"]: r["group"] for r in s["pids"]}[15], "other")

    def test_webkit_processes_of_a_native_app(self):
        s = peer_idle.sample(NATIVE, 60)
        self.assertEqual(s["groups"]["renderer"], 50.0)
        self.assertEqual(s["groups"]["gpu"], 11.0)
        self.assertEqual(s["groups"]["app"], 240.0)

    def test_reads_as_bench_memory_idle_window(self):
        """The reconciler and perf-idle-ab's summary take the last sample labelled idle-*, not idle-launch,
        and read total_footprint_mb and kinds[*].footprint_mb."""
        s = peer_idle.sample(ELECTRON, 60)
        self.assertEqual(s["label"], "idle-1")
        self.assertEqual(s["total_footprint_mb"], 612.4)
        self.assertTrue(all("footprint_mb" in e for e in s["kinds"].values()))
        self.assertEqual(peer_idle.sample(ELECTRON, 0, "idle-launch")["label"], "idle-launch")

    def test_empty_read(self):
        s = peer_idle.sample({"mb": 0.0, "processes": 0, "pids": []}, 60)
        self.assertEqual(s["kinds"], {})
        self.assertEqual(s["total_footprint_mb"], 0.0)


if __name__ == "__main__":
    unittest.main()
