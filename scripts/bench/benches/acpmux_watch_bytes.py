"""acpmux-watch-bytes: what one watching connection is sent while chats stream and the list is read over and over.

Wraps the acpmux test `hub::list_guard::stream_tell_tests` (cmux-tui/crates/acpmux/src/hub/stream_tell_tests.rs), run
with cargo on Linux CI through `cmux-ci test` at the caller's open PR head: 20 chats stream (a chunk and a tool update
each between reads) while the list is read 60 times. It prints one line before it asserts, so a build without the bound
still gives its number:

  ACPMUX-WATCH-BYTES {"chats": 20, "reads": 60, "rows_told": .., "watcher_bytes": .., "bytes_per_read": .., ...}

Rows (better = lower): watcher_bytes (KB): the list rows sent to one watcher without tools (the app's and the iPhone
host's connections) for the 60 reads; rows_told (count); bytes_per_read (KB). Leo's Mac, 2026-11-19, idle: acpmux sent
312 MB in 90 s to the app and the iPhone host, each list read telling every streaming chat's row to every watcher.

Run: `cmux-bench acpmux-watch-bytes` (the open PR's head) or `--import LOG` (a `cmux-ci test` log).
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "cmux-tui/crates/acpmux/src/hub/stream_tell_tests.rs"
COMMAND = "cd cmux-tui && cargo test -p acpmux --lib stream_tell_tests -- --nocapture"
LINE = re.compile(r"ACPMUX-WATCH-BYTES (\{.*\})")
KB = 1024


class AcpmuxWatchBytes(Bench):
    name = "acpmux-watch-bytes"
    summary = "Bytes one acpmux watcher is sent while 20 chats stream and the list is read 60 times (Linux CI)"
    units = "KB, count"
    owner = "perf (idle stream, Leo-ask c-7c7c95d5c5)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"

    def run(self, ctx: Context) -> None:
        cmd = ["cmux-ci", "test", "--timeout", "3600", "--", "bash", "-c", COMMAND]
        if ctx.dry_run:
            print("dry run:", " ".join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "acpmux-watch-bytes.log"
        with log.open("w", encoding="utf-8") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        samples = []
        for line in text.splitlines():
            if m := LINE.search(line):
                try:
                    samples.append(json.loads(m.group(1)))
                except json.JSONDecodeError:
                    continue
        if not samples:
            raise BenchError(f"{path}: no ACPMUX-WATCH-BYTES line (not a stream_tell_tests log?)")
        labels = {"chats": str(samples[0].get("chats")), "reads": str(samples[0].get("reads"))}
        ctx.row("watcher_bytes", unit="KB", samples=[s["watcher_bytes"] / KB for s in samples], labels=labels)
        ctx.row("rows_told", unit="count", samples=[s["rows_told"] for s in samples], labels=labels)
        ctx.row("bytes_per_read", unit="KB", samples=[s["bytes_per_read"] / KB for s in samples], labels=labels)


BENCH = AcpmuxWatchBytes()
