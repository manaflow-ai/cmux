"""Synthetic excluded-tree traversal cost, with identical discovered source coverage."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from benchlib.bench import Bench, BenchError


class LocalizationDiscovery(Bench):
    name = "localization-discovery"
    summary = "Swift discovery directory reads and time with excluded dependency trees"
    units = "count, ms"
    owner = "localization tooling"
    hosts = ("anywhere",)
    harness = "scripts/measure/localization-discovery.py"
    version = "1"

    def run(self, ctx):
        if ctx.build.get("channel") != "local":
            raise BenchError("localization-discovery runs checkout source; use --build local")
        root = Path(__file__).resolve().parents[3]
        command = [sys.executable, str(root / self.harness), "--excluded", ctx.arg("excluded") or "2000",
                   "--algorithm", ctx.arg("algorithm") or "current"]
        result = subprocess.run(command, capture_output=True, text=True, timeout=180)
        if result.returncode:
            raise BenchError(result.stderr or "localization discovery failed")
        path = ctx.workdir / "localization-discovery.json"
        path.write_text(result.stdout, encoding="utf-8")
        self.ingest(ctx, path)

    def ingest(self, ctx, path):
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        if data["files"] != ["Sources/A.swift"]:
            raise BenchError("localization-discovery changed source coverage")
        # Algorithm deliberately does not label rows: compare matches baseline and current.
        labels = {"excluded": str(data["excluded"])}
        ctx.row("directory_reads", data["directory_reads"], "count", labels=labels)
        ctx.row("discovery", data["seconds"] * 1000, "ms", labels=labels)


BENCH = LocalizationDiscovery()
