"""The real daemon's chat-size sweep, registered for imports and comparisons.

Run at a pushed PR head: cmux-bench chat-size --build SHA --arg sizes=1M,100M,1G,4G.
The Rust harness owns measurement, validity checks, ratios and the Markdown table.
This adapter only maps its output to the shared ledger schema.
"""
from __future__ import annotations

import json
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

TIMINGS = ("attachUs", "newestPageUs", "scrollRecentUs", "scrollMidUs", "scrollDeepUs",
           "promptIndexUs", "forwardPageUs", "sendFirstTokenUs")
SCALARS = {"coldAttachMs": "ms", "restartAttachMs": "ms", "firstSendFirstTokenMs": "ms",
           "restartSendFirstTokenUs": "us", "rssIdle": "bytes", "peakRss": "bytes",
           "restartPeakRss": "bytes"}


class ChatSize(Bench):
    name = "chat-size"
    summary = "Real daemon open, paging, first token and RSS at 1 MB, 100 MB, 1 GB and 4 GB"
    units = "ms, us, bytes, x"
    owner = "infinite chats"
    hosts = ("fleet",)
    harness = "scripts/measure/chat-size-sweep.sh"
    version = "1"

    def run(self, ctx: Context) -> None:
        sha = ctx.build.get("sha")
        if not sha:
            raise BenchError("chat-size: --build SHA must name the pushed PR head")
        out = ctx.workdir / "artifact"
        sizes = ctx.arg("sizes", "1M,100M,1G,4G")
        command = (f"set -o pipefail; {{ exec 2>&1; FAST_CHECKS_OUT_NO_TEE=1 bash {shlex.quote(self.harness)} {shlex.quote(sizes)}; }}"
                   ' | tee "$FAST_CHECKS_OUT/out.txt" "$FAST_CHECKS_OUT/chat-size-sweep.log"')
        cmd = ["cmux-ci", "test", "--route", "fleet", "--at", sha,
               "--timeout", "7200", "--artifact", str(out), "--", "bash", "-c", command]
        if ctx.dry_run:
            print(cmd)
            return
        log = ctx.workdir / "dispatch.log"
        with log.open("w", encoding="utf-8") as stream:
            result = subprocess.run(cmd, cwd=REPO_ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                    timeout=7800, check=False)
        if result.returncode:
            raise BenchError(f"chat-size failed ({result.returncode}); see {log} and {out}")
        self.ingest(ctx, out / "chat-size-sweep.log")

    def ingest(self, ctx: Context, path: Path) -> None:
        text = path.read_text(encoding="utf-8")
        if "CHAT-SIZE-TABLE-END" not in text or "infinite_chat_size_ratio_max null" in text:
            raise BenchError(f"{path}: incomplete size sweep; no comparable run")
        sizes, ratios = [], []
        head, host = None, None
        for line in text.splitlines():
            if line.startswith("CHAT-SIZE-HEAD "):
                head = line.split()[1]
            elif line.startswith("CHAT-SIZE-HOST "):
                host = line.split(maxsplit=3)
            elif line.startswith("CHAT-SIZE "):
                sizes.append(json.loads(line.removeprefix("CHAT-SIZE ")))
            elif line.startswith("CHAT-SIZE-RATIO "):
                ratios.append(json.loads(line.removeprefix("CHAT-SIZE-RATIO ")))
        if len(sizes) < 2 or sizes[0].get("bytes") != 1048576:
            raise BenchError(f"{path}: need a 1 MB baseline and at least one larger chat")
        if not head or len(head) != 40 or not host or len(host) != 4:
            raise BenchError(f"{path}: missing source SHA or runner identity")
        if ctx.build.get("sha") and ctx.build["sha"] != head:
            raise BenchError(f"{path}: source SHA differs from requested build")
        if {r["size"] for r in ratios} != {r["size"] for r in sizes[1:]}:
            raise BenchError(f"{path}: incomplete ratios")
        # Validate every row before appending any ledger entry.
        for row in sizes:
            if row.get("skipped") or any(v is not None for k, v in row.items() if k.endswith("Error")):
                raise BenchError(f"{path}: failed size {row.get('size')}")
            for key in TIMINGS:
                if not isinstance(row.get(key), dict) or any(row[key].get(q) is None for q in ("p50", "p95")):
                    raise BenchError(f"{path}: missing {key} for {row.get('size')}")
            if any(row.get(key) is None for key in SCALARS):
                raise BenchError(f"{path}: missing scalar for {row.get('size')}")
        ctx.build.update({"channel": "sha", "sha": head})
        ctx.host.update({"name": host[1], "os": host[2], "chip": host[3]})
        for row in sizes:
            labels = {"size": row["size"], "source": row["source"]}
            for key in TIMINGS:
                stat = row[key]
                ctx.row(key, stat["p50"], "us", p50=stat["p50"], p95=stat["p95"],
                        n=stat.get("n"), labels=labels)
            for key, unit in SCALARS.items():
                ctx.row(key, row[key], unit, labels=labels)
        for row in ratios:
            for metric, value in row["ratios"].items():
                ctx.row("size_ratio", value, "x", labels={"size": row["size"], "metric": metric})


BENCH = ChatSize()
