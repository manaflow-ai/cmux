"""Local session-summary gate: the smallest installed on-device model on 30 labeled sessions (hq finding 11-20)."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from benchlib.bench import Bench, BenchError


class LocalSummary(Bench):
    name = "local-summary"
    summary = "one-line session summary by a local model: warm/cold p95, length, recall, unsupported claims"
    units = "ms, chars, ratio, count"
    owner = "acpmux titles"
    hosts = ("anywhere",)
    harness = "scripts/measure/local_summary_gate.py"
    version = "1"

    def run(self, ctx):
        root = Path(__file__).resolve().parents[3]
        command = [sys.executable, str(root / self.harness), "--runtime", ctx.arg("runtime") or "auto",
                   "--out", str(ctx.workdir)]
        if ctx.arg("model"):
            command += ["--model", ctx.arg("model")]
        result = subprocess.run(command, capture_output=True, text=True, timeout=3600)
        if result.returncode:
            raise BenchError(result.stderr or "local summary gate failed")
        self.ingest(ctx, ctx.workdir / "report.json")

    def ingest(self, ctx, path):
        rep = json.loads(Path(path).read_text(encoding="utf-8"))
        for row in rep["rows"]:
            s = row["summary"]
            labels = {"runtime": row["runtime"], "model": row["model"]}
            for key, unit in (("warm_p95_ms", "ms"), ("cold_p95_ms", "ms"), ("first_token_p95_ms", "ms"),
                              ("max_chars", "chars"), ("key_fact_recall", "ratio"), ("unsupported", "count")):
                if s.get(key) is not None:
                    ctx.row(key, s[key], unit, labels=labels)


BENCH = LocalSummary()
