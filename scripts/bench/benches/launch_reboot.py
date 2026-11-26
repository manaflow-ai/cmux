"""Import launch-reboot.sh logs, preserving uncapped reads and production preread arms.

Run the before/after phases on the same exclusive measurement Mac as documented in
scripts/measure/launch-reboot.sh. Then import the after log:
  cmux-bench launch-reboot --build SHA --import after.log --arg host=HOST
The preread arm measures the bundled helper at default caps, not login-item scheduling.
"""
from __future__ import annotations

import shlex
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context


class LaunchReboot(Bench):
    name = "launch-reboot"
    summary = "First launch after reboot and the bounded Warm at Login reader's cost"
    units = "ms, bytes, count"
    owner = "launch (RFD 0131)"
    hosts = ("fleet",)
    harness = "scripts/measure/launch-reboot.sh"
    version = "1"

    def run(self, ctx: Context) -> None:
        raise BenchError("launch-reboot: run before/after on the same exclusive Mac, then --import AFTER.log; "
                         "see scripts/measure/launch-reboot.sh")

    def ingest(self, ctx: Context, path: Path) -> None:
        text = path.read_text(encoding="utf-8")
        if any(line.startswith("LB-FAIL ") for line in text.splitlines()):
            raise BenchError("launch-reboot: failed phase; no measurement imported")
        found = False
        for line in text.splitlines():
            # Only benchmark rows are shell's space-delimited key/value format.  Ignore
            # helper output first so an unrelated quoted line cannot make shlex fail.
            if not line.startswith(("LB-READ ", "LB-PREREAD ", "LB-LAUNCH ")):
                continue
            fields = shlex.split(line)
            if not fields:
                continue
            values = dict(item.split("=", 1) for item in fields[1:] if "=" in item)
            label_keys = ("arm", "reboot", "file") if fields[0] == "LB-READ" else ("arm", "reboot")
            labels = {key: values[key] for key in label_keys if key in values}
            if fields[0] == "LB-PREREAD":
                metrics = {"wall_ms": "ms", "cpu_ms": "ms", "maxrss": "bytes"}
                prefix = "preread_"
            elif fields[0] == "LB-READ":
                metrics = {"wall_ms": "ms", "cpu_ms": "ms", "maxrss": "bytes"}
                prefix = "read_"
            else:
                found = True
                metrics = {"request_to_start": "ms", "main_start": "ms", "first_frame": "ms",
                           "window_on_screen": "ms", "settle": "ms", "pageins": "count"}
                prefix = ""
            for key, unit in metrics.items():
                if values.get(key) not in (None, "null"):
                    ctx.row(prefix + key, float(values[key]), unit, labels=labels)
        if not found:
            raise BenchError("launch-reboot: no completed LB-LAUNCH row; import the after phase")


BENCH = LaunchReboot()
