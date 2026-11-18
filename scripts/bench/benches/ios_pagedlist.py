"""ios-pagedlist: the shared iOS infinite-scroll list (PagedList) under load while someone scrolls it.

Harness: scripts/ci/cmux-next-ios-sim.sh `test ui=PagedListStressUITests` on a fleet simulator Mac
(cmux-next-ios/verify/paged-list.md, "Stress bench"). Each stress case (direction down/up x speed
slow/medium/fast x load flood/edits/inserts, plus a busy main thread and a 100,000-row list held in a
300-row window) prints one line

    PAGEDLIST STRESS-<direction>-<speed>-<load> {"direction":..,"speed":..,"load":..,"window":..,"hud":{..}}

and `ingest` turns each into rows labelled direction, speed and load (and window when set):

  frame_shift_pt     the worst move, in any frame, of the row being read that the scroll does not explain
                     (the per-frame layout shift; the bar is 0.5 pt)
  shifted_frames     layout passes whose shift passed half a point
  landing_shift_pt   the worst move of the row being read when a page landed
  hitch_ms_per_s     hitch time per second of scrolling (FrameIntervalLog)
  worst_frame_ms     the longest frame while scrolling
  dropped_frames     frames dropped while scrolling
  in_memory_rows     row values the model held at the end (bounded with a window)
  disk_bytes         its spill file's size at the end
  changes_applied    changes the load sent (better=none: the shape of the load, not a result)

`--arg suite=SUITE` runs another UI test suite that prints the same lines (a screen's own stress cases);
`--arg only=testDownFastFlood` one case of the suite; `--arg video=1` records the simulator.
`cmux-bench ios-pagedlist --import FILE` reads the step's evidence.zip, its ui-console.txt or its log.
"""
from __future__ import annotations

import json
import re
import subprocess
import zipfile
from pathlib import Path
from typing import Any

from benchlib.bench import Bench, BenchError, Context

SCRIPT = "scripts/ci/cmux-next-ios-sim.sh"
ARTIFACT = "artifacts/ios-sim/evidence.zip"
SUITE = "PagedListStressUITests"
LINE = re.compile(r"PAGEDLIST (STRESS-[A-Za-z0-9_-]+) (\{.*\})\s*$")
TEXT_SUFFIXES = (".txt", ".log", ".json", ".md")


def _num(value: Any) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


class IosPagedList(Bench):
    name = "ios-pagedlist"
    summary = "iOS PagedList under load while scrolling: per-frame layout shift, hitches, memory (direction x speed x load)"
    units = "pt, ms, count, bytes"
    owner = "cmux-next iOS (Aziz)"
    hosts = ("fleet",)
    harness = SCRIPT
    version = "1"
    # Shift is judged against an absolute bar (0.5 pt), not a relative change: any move is a regression.
    thresholds = {"hitch_ms_per_s": 25.0, "worst_frame_ms": 25.0, "dropped_frames": 50.0, "in_memory_rows": 10.0,
                  "disk_bytes": 50.0}
    floors = {"frame_shift_pt": 0.5, "landing_shift_pt": 0.5, "shifted_frames": 1.0, "hitch_ms_per_s": 2.0,
              "worst_frame_ms": 8.0, "dropped_frames": 5.0, "in_memory_rows": 50.0, "disk_bytes": 1 << 20}
    nightly = False

    def run(self, ctx: Context) -> None:
        suite = ctx.arg("suite") or SUITE
        if not re.fullmatch(r"[A-Za-z0-9_]+", suite):
            raise BenchError(f"ios-pagedlist: --arg suite={suite}: a CmuxMobileAppUITests suite name")
        only = ctx.arg("only")
        if only and not re.fullmatch(r"[A-Za-z0-9_]+", only):
            raise BenchError(f"ios-pagedlist: --arg only={only}: one test method name")
        args = ["test", f"ui={suite}/{only}" if only else f"ui={suite}"]
        if ctx.arg("video") == "1":
            args.append("video")
        # No extra label: the simulator minis advertise `simulator` only (a `bench` label matches no worker).
        res = ctx.fleet_step(SCRIPT, args, ARTIFACT, step_class="simulator", labels=(),
                             timeout=int(ctx.arg("timeout") or 5400), ref=ctx.arg("ref") or ctx.build.get("sha"))
        path = res.artifact_path
        if path is None and res.job_id:
            # A case that failed fails the step, and a failed step's artifact comes only with --failed:
            # its measurements are the point of the run.
            out = ctx.workdir / "evidence-failed.zip"
            got = subprocess.run(["cmux-ci", "artifact", "--failed", res.job_id, str(out)], text=True, capture_output=True)
            if got.returncode == 0 and out.exists():
                path = out
                ctx.notes.append(f"step {res.job_id} failed; its measurements come from the failed-step evidence")
        self.ingest(ctx, path or res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        cases = self._cases(path)
        if not cases:
            raise BenchError(f"ios-pagedlist: no PAGEDLIST STRESS-… lines in {path} (did the suite build and run?)")
        for name, record in sorted(cases.items()):
            hud = record.get("hud") or {}
            labels = {k: record.get(k) for k in ("direction", "speed", "load") if record.get(k)}
            if record.get("window") is not None:
                labels["window"] = record["window"]
            labels = labels or {"case": name}
            for metric, key, unit, better in (
                ("frame_shift_pt", "frameShift", "pt", "lower"),
                ("shifted_frames", "shiftedFrames", "count", "lower"),
                ("landing_shift_pt", "maxShift", "pt", "lower"),
                ("hitch_ms_per_s", "hitchMsPerS", "ms", "lower"),
                ("worst_frame_ms", "worstMs", "ms", "lower"),
                ("dropped_frames", "dropped", "count", "lower"),
                ("in_memory_rows", "inMemory", "count", "lower"),
                ("disk_bytes", "diskBytes", "bytes", "none"),
                ("changes_applied", "changes", "count", "none"),
            ):
                value = _num(hud.get(key))
                if value is not None:
                    ctx.row(metric, value, unit, better=better, labels=labels)
            if (_num(hud.get("frameShift")) or 0) > 0.5:
                ctx.notes.append(f"{name}: frame shift {hud['frameShift']} pt in {hud.get('shiftedFrames')} frames")

    @staticmethod
    def _cases(path: Path) -> dict[str, dict[str, Any]]:
        """Every STRESS record in a file, a zip of the step's evidence, or a folder (the last one per case wins).

        A record is a `PAGEDLIST STRESS-… {json}` console line, or a test attachment named `PAGEDLIST-STRESS-…`
        (ui-attachments/manifest.json maps it to its exported file: the step's console export can be empty)."""
        texts: list[str] = []
        files: dict[str, bytes] = {}
        if path.is_dir():
            files = {str(p.relative_to(path)): p.read_bytes() for p in sorted(path.rglob("*"))
                     if p.is_file() and p.suffix in TEXT_SUFFIXES}
        elif zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as z:
                files = {n: z.read(n) for n in z.namelist() if n.endswith(TEXT_SUFFIXES)}
        else:
            texts = [path.read_text(encoding="utf-8", errors="replace")]
        texts += [data.decode("utf-8", errors="replace") for data in files.values()]
        cases: dict[str, dict[str, Any]] = {}
        for name, data in files.items():
            if not name.endswith("manifest.json"):
                continue
            folder = name[: -len("manifest.json")]
            try:
                manifest = json.loads(data)
            except ValueError:
                continue
            for test in manifest if isinstance(manifest, list) else []:
                for att in test.get("attachments") or []:
                    label = str(att.get("suggestedHumanReadableName", ""))
                    if not label.startswith("PAGEDLIST-STRESS-"):
                        continue
                    body = files.get(folder + str(att.get("exportedFileName", "")))
                    try:
                        record = json.loads(body) if body else None
                    except ValueError:
                        continue
                    if isinstance(record, dict):
                        cases[label[len("PAGEDLIST-"):].split("_0_")[0]] = record
        for text in texts:
            for line in text.splitlines():
                m = LINE.search(line)
                if not m:
                    continue
                try:
                    record = json.loads(m.group(2))
                except ValueError:
                    continue
                if isinstance(record, dict):
                    cases[m.group(1)] = record
        return cases


BENCH = IosPagedList()
