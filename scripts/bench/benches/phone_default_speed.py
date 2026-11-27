"""Import the four Callgrind counts from the production phone-terminal gate."""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

CASES = {f"{op}-{history}" for op in ("primary", "alternate") for history in (100, 10000)}
LINE = re.compile(r"(primary|alternate)-(100|10000)\t([0-9]+) Ir / 10 operations$")


class PhoneDefaultSpeed(Bench):
    name = "phone-default-speed"
    summary = "Default-grid Ghostty core instruction budgets under short and long scrollback; no device timing claim"
    units = "count"
    owner = "phone-connect-rootcause"
    hosts = ("fleet",)
    harness = "scripts/bench/phone-default-speed/src/main.rs"
    version = "1"

    def run(self, ctx: Context) -> None:
        command = ["cmux-ci", "test", "--timeout", "2700", "--", "python3", "ci/run", "run", "--job", "linux", "--only", "phone-default-speed-icount"]
        if ctx.dry_run:
            print("dry run:", " ".join(command))
            raise BenchError("dry run")
        log = ctx.workdir / "phone-default-speed.log"
        with log.open("w", encoding="utf-8") as output:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=False)
        if result.returncode:
            raise BenchError(f"phone-default-speed failed ({result.returncode}): {log}")
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        counts = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            match = LINE.search(line)
            if match:
                operation, history, count = match.groups()
                key = f"{operation}-{history}"
                if key in counts or int(count) <= 0:
                    raise BenchError(f"duplicate or invalid phone-default-speed case: {key}")
                counts[key] = int(count)
        if counts.keys() != CASES:
            raise BenchError("phone-default-speed requires every measured case")
        for case, count in sorted(counts.items()):
            operation, history = case.split("-")
            ctx.row("instructions", count, "count", labels={"operation": operation, "seeded_lines": history, "iterations": "10"})


BENCH = PhoneDefaultSpeed()
