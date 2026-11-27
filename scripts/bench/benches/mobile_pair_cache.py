"""Two successful pair runs, immutable binary-cache miss/hit with preexisting Cargo outputs."""
from __future__ import annotations

import json
import math
import os
import re
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = "scripts/measure/mobile-pair-skew-cache.sh"
PREFIX = "MOBILE-PAIR-CACHE "
ARMS = ("binary-miss", "binary-hit")


def parse(text: str) -> list[dict]:
    rows = []
    try:
        for line in text.splitlines():
            if line.startswith(PREFIX):
                rows.append(json.loads(line[len(PREFIX):]))
        if len(rows) != 2 or [row["arm"] for row in rows] != list(ARMS):
            raise ValueError("need one ordered miss and hit receipt")
        pair = None
        for row in rows:
            if row["schema"] != "mobile-pair-cache/v1" or row["valid"] is not True or row["exit_code"] != 0:
                raise ValueError("failed pair run")
            source = (row["host_sha"], row["dial_sha"])
            if not all(isinstance(sha, str) and re.fullmatch("[0-9a-f]{40}", sha) for sha in source):
                raise ValueError("missing exact source SHA")
            if pair is not None and pair != source:
                raise ValueError("source pair changed between arms")
            pair = source
            if row["cargo_cache"] != "preexisting":
                raise ValueError("unknown Cargo cache state")
            expected = (0, 2) if row["arm"] == "binary-miss" else (2, 0)
            if (row["hits"], row["misses"]) != expected:
                raise ValueError("wrong binary cache state")
            for key in ("wall_s", "user_s", "system_s"):
                value = row[key]
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                    raise ValueError("invalid timing")
        return rows
    except (KeyError, TypeError, ValueError) as exc:
        raise BenchError(f"mobile-pair-cache: invalid receipt: {exc}") from exc


class MobilePairCache(Bench):
    name = "mobile-pair-cache"
    summary = "Headless phone/Mac pair wall and CPU seconds, binary cache miss versus hit"
    units = "s"
    owner = "phone compatibility (cmux#62287)"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"

    def run(self, ctx: Context) -> None:
        old, head = ctx.arg("old"), ctx.arg("head")
        if not old or not head:
            raise BenchError("mobile-pair-cache needs --arg old=CHECKOUT --arg head=CHECKOUT")
        command = ["bash", str(REPO_ROOT / HARNESS), old, head]
        if ctx.dry_run:
            print("dry run:", shlex.join(command))
            raise BenchError("dry run")
        env = dict(os.environ)
        if ctx.arg("cargo_target"):
            env["CARGO_TARGET_DIR"] = ctx.arg("cargo_target")
        result = subprocess.run(command, cwd=REPO_ROOT, env=env, text=True, capture_output=True, timeout=3600)
        path = ctx.workdir / "mobile-pair-cache.log"
        path.write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode:
            raise BenchError(f"mobile-pair-cache: harness exit {result.returncode}; log {path}")
        self.ingest(ctx, path)

    def ingest(self, ctx: Context, path: Path) -> None:
        rows = parse(Path(path).read_text(encoding="utf-8"))
        for row in rows:
            labels = {key: row[key] for key in ("arm", "host_sha", "dial_sha", "cargo_cache")}
            for metric, value in (("wall", row["wall_s"]), ("user_cpu", row["user_s"]),
                                  ("system_cpu", row["system_s"]), ("cpu", row["user_s"] + row["system_s"])):
                ctx.row(metric, value, "s", labels=labels)


BENCH = MobilePairCache()
