"""workspace-factory: a throwaway per-job workspace (an APFS clone of a read-only seed) against today's step
workspaces, for one real cmux step on one fleet Mac (hq docs/rfd/0005-ephemeral-workers.md).

Wraps scripts/measure/workspace-factory.sh: the swift-package-tests prebuild (`swift build --build-tests`) of one
package in four arms, cold (today, no warm slot), slot (today's warm step slot, kept after the job), seed (the
trusted seed build) and factory (wsfactory create, build, destroy, per job). Every line it prints that this reads:

  WSFACTORY {"arm": "cold"|"slot"|"seed"|"factory", "job": N, "start_ms": .., "build_ms": .., "compiled": .., ...}
  WSFACTORY-SUMMARY {"package": .., "jobs": N, "cold_compiled": .., "factory_root_entries_left": .., "host": ..}
  WSFACTORY-END {"run_left_bytes": ..}

Rows (label arm), better = lower unless noted:
  start (ms): from asking for a workspace to its tree being there (the clone, for factory; 0 for cold and slot,
    which today's worker gives before the step's own clock starts);
  build (s): the step's command; compiled (count): `[n/m] Compiling` lines;
  cache_hit (%, higher): 1 - compiled / the cold arm's compiled;
  left (MB): free space the job took and did not give back (slot: the slot itself, which today stays);
  home_left (MB): growth of the SwiftPM, Xcode module and TMPDIR caches outside the tree;
  seed (MB), seed_build (s): what the factory's warm state costs, once per seed;
  run_left (MB): the whole run's free space at the end against its start.

Run: `cmux-bench workspace-factory --build SHA [--arg package=Packages/...] [--arg jobs=3] [--arg worker=NAME]`.
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/workspace-factory.sh"
MB = 1024 * 1024
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")
LINE = re.compile(r"^(WSFACTORY|WSFACTORY-SUMMARY|WSFACTORY-END) (\{.*\})$")


class WorkspaceFactory(Bench):
    name = "workspace-factory"
    summary = "Per-job throwaway workspace from a read-only seed vs today's step workspaces: start, build, cache hit, disk left"
    units = "ms, s, count, %, MB"
    owner = "fleet (hq RFD 0005, lane ephemeral-workers)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    floors = {"start": 50.0, "build": 2.0, "left": 50.0, "home_left": 50.0, "run_left": 50.0}

    def run(self, ctx: Context) -> None:
        args = [ctx.arg("package") or "Packages/iOS/CmuxMobileSSH", ctx.arg("jobs") or "3"]
        ref = ctx.build.get("sha") if ctx.build.get("channel") == "sha" else None
        res = ctx.fleet_step(self.harness, args, None, step_class="exclusive", labels=("measure",), timeout=7200,
                             ref=ref)
        log = res.log_path
        if "WSFACTORY-SUMMARY " not in res.log and res.job_id:
            full = ctx.workdir / f"{res.job_id}.log"
            got = subprocess.run(["cmux-ci", "log", res.job_id, "--tail", "200000"], text=True, capture_output=True)
            if got.returncode == 0:
                full.write_text(got.stdout)
                log = full
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        arms: dict[str, list[dict]] = {}
        summary: dict | None = None
        end: dict | None = None
        for raw in text.splitlines():
            m = LINE.match(STAMP.sub("", raw.strip()))
            if not m:
                continue
            try:
                obj = json.loads(m.group(2))
            except json.JSONDecodeError:
                continue
            if m.group(1) == "WSFACTORY":
                arms.setdefault(str(obj.get("arm")), []).append(obj)
            elif m.group(1) == "WSFACTORY-SUMMARY":
                summary = obj
            else:
                end = obj
        if summary is None:
            raise BenchError(f"{path}: no WSFACTORY-SUMMARY line (not a workspace-factory.sh log, or it failed)")
        if summary.get("host"):
            ctx.host.update({"name": summary["host"], "role": "fleet"})
        cold_compiled = float(summary.get("cold_compiled") or 0)

        def values(arm: str, key: str, scale: float = 1.0) -> list[float]:
            return [float(e[key]) / scale for e in arms.get(arm, []) if isinstance(e.get(key), (int, float))]

        for arm in ("cold", "slot", "factory"):
            labels = {"arm": arm}
            ctx.row("start", unit="ms", samples=values(arm, "start_ms"), labels=labels)
            ctx.row("build", unit="s", samples=values(arm, "build_ms", 1000.0), labels=labels)
            compiled = values(arm, "compiled")
            ctx.row("compiled", unit="count", samples=compiled, labels=labels)
            if cold_compiled and compiled:
                ctx.row("cache_hit", unit="%", better="higher",
                        samples=[100.0 * (1 - c / cold_compiled) for c in compiled], labels=labels)
            ctx.row("left", unit="MB", samples=values(arm, "left_bytes", MB), labels=labels)
            ctx.row("home_left", unit="MB", samples=values(arm, "home_left_bytes", MB), labels=labels)
        seed = arms.get("seed", [{}])[0]
        if isinstance(seed.get("seed_bytes"), (int, float)):
            ctx.row("seed", seed["seed_bytes"] / MB, "MB", labels={"arm": "seed"})
        if isinstance(seed.get("build_ms"), (int, float)):
            ctx.row("seed_build", seed["build_ms"] / 1000.0, "s", labels={"arm": "seed"})
        if end and isinstance(end.get("run_left_bytes"), (int, float)):
            ctx.row("run_left", end["run_left_bytes"] / MB, "MB", labels={"arm": "run"})
        if any(e.get("seed_unchanged") is False for e in arms.get("factory", [])):
            ctx.notes.append("workspace-factory: a factory job changed the seed (wsfactory seed verify failed)")


BENCH = WorkspaceFactory()
