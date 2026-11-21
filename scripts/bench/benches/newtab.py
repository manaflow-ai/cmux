"""newtab: New Tab (Cmd-T) first paint and settled-interactive timings in a tagged cmux NEXT app.

  mode=surfaces (default)  scripts/measure/instant-new-surfaces.sh --commands=new_tab: one Cmd-T at a time through
                           the real key path, the warm, quick and cold arms (bench_arms.py), idle and under load.
                           Per press the app reports `visible_ms` (the frame that shows the New Tab page: first
                           paint), `ready_ms` (the page painted and taking keys: settled interactive),
                           `confirmed_ms` (the daemon's object replaced the provisional one) and `key_ms` (the key's
                           main-thread time).
  mode=launch-pairs        the same script with --launch-pairs=N: per launch, the session's first Cmd-T, a second one
                           a second later, and a warm one after a ready spare (arm=launch_first|launch_second|
                           launch_warm_ref).
  mode=held                scripts/measure/held-new-tab.sh: Cmd-T held (with Cmd-W now and then) in a session of many
                           workspaces; input to the next commit per row (scenario=mixed|hold|close).

xbench's `newtab-paint` row (a browser tab's new tab command to that page's first contentful paint, per browser) is
the `xbench` bench's `newtab_paint` metric; this bench does not record it again.

`cmux-bench newtab --import FILE` reads any of their outputs: instant-new-surfaces.json, held-new-tab.json, or the
fleet log of instant-new-surfaces.sh or held-new-tab.sh.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from benchlib.bench import Bench, BenchError, Context

SURFACES = "scripts/measure/instant-new-surfaces.sh"
SURFACES_ARTIFACT = "artifacts/instant-new-surfaces.json"
HELD = "scripts/measure/held-new-tab.sh"
HELD_ARTIFACT = "held-new-tab.json"
# instant-new-surfaces' per-press fields -> (metric, unit, better).
PRESS_METRICS = {
    "visible_ms": ("first_paint_ms", "ms", "lower"),
    "ready_ms": ("interactive_ms", "ms", "lower"),
    "confirmed_ms": ("confirmed_ms", "ms", "lower"),
    "key_ms": ("key_main_thread_ms", "ms", "lower"),
}
ARM_LINE = re.compile(r"^ARM instant-new-surfaces/new_tab (\w+) (\w+): n=(\d+) missed=(\d+) p50=(\S+) p95=(\S+)")
PAIR_LINE = re.compile(r"^LAUNCHPAIR (first|second|warm_ref) #\d+: ready_ms=(\S+) visible_ms=(\S+)")


def _num(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


class NewTab(Bench):
    name = "newtab"
    summary = "New Tab (Cmd-T) first paint and settled-interactive ms, warm/quick/cold, idle and under load"
    units = "ms, count"
    owner = "instant new surfaces (cmux NEXT perf; #43728)"
    hosts = ("fleet",)
    harness = SURFACES
    version = "1"
    thresholds = {"key_main_thread_ms": 20.0, "confirmed_ms": 15.0}
    floors = {"first_paint_ms": 4.0, "interactive_ms": 4.0, "key_main_thread_ms": 2.0}
    # A bench build of the NIGHTLY's own commit and one command: the build plus about ten minutes of presses.
    nightly = True
    nightly_args = {"mode": "surfaces"}

    def _ref(self, ctx: Context) -> str | None:
        """The commit to build: --arg ref, else the measured build's sha (a NIGHTLY names its source commit)."""
        if ctx.arg("ref"):
            return ctx.arg("ref")
        sha = ctx.build.get("sha")
        if sha:
            return sha
        if ctx.build.get("channel") in ("nightly", "release"):
            raise BenchError("newtab builds the app at a commit and this build names none; pass --arg ref=SHA")
        return None  # fleet_step takes the feat-cmux-next tip

    def run(self, ctx: Context) -> None:
        mode = ctx.arg("mode", "surfaces")
        config = f"--config={ctx.arg('config') or 'bench'}"
        extra = [a for a in (ctx.arg("extra") or "").split() if a]
        if mode in ("surfaces", "launch-pairs"):
            args = [config, "--commands=new_tab"]
            if mode == "launch-pairs":
                args += [f"--launch-pairs={ctx.arg('pairs') or 5}", f"--launch-settle={ctx.arg('settle') or 5}"]
            else:
                args += [f"--runs={ctx.arg('runs') or 12}"]
                if ctx.arg("workspaces"):
                    args.append(f"--workspaces={ctx.arg('workspaces')}")
            res = ctx.fleet_step(SURFACES, args + extra, SURFACES_ARTIFACT, step_class="exclusive",
                                 labels=("measure",), timeout=int(ctx.arg("timeout") or 3600), ref=self._ref(ctx))
        elif mode == "held":
            args = [config, f"--vdisplay={ctx.arg('vdisplay') or 120}", "--no-gate"]
            if ctx.arg("workspaces"):
                args.append(f"--workspaces={ctx.arg('workspaces')}")
            res = ctx.fleet_step(HELD, args + extra, HELD_ARTIFACT, step_class="exclusive",
                                 labels=("measure", "gui-session-v1"), timeout=int(ctx.arg("timeout") or 3600),
                                 ref=self._ref(ctx))
        else:
            raise BenchError(f"newtab: --arg mode={mode}: expected surfaces, launch-pairs or held "
                             "(a browser tab's new tab paint is `cmux-bench xbench`, metric newtab_paint)")
        self.ingest(ctx, res.artifact_path or res.log_path)

    # --- ingest --------------------------------------------------------------------------------
    def ingest(self, ctx: Context, path: Path) -> None:
        text = path.read_text(encoding="utf-8", errors="replace")
        try:
            data = json.loads(text)
        except ValueError:
            data = None
        if isinstance(data, dict):
            if "launch_pairs" in data:
                return self._launch_pairs(ctx, data.get("runs") or [])
            if "runs" in data and "summary" in data:
                return self._surfaces(ctx, data["runs"])
            if "hid_grant" in data or ("rows" in data and "key_source" in data):
                return self._held(ctx, data)
            if isinstance(data.get("rows"), dict) and "browsers" in data:
                raise BenchError(f"newtab: {path} is xbench's results.json: import it with `cmux-bench xbench --import`")
            raise BenchError(f"newtab: {path}: not an output of instant-new-surfaces or held-new-tab")
        held = [ln for ln in text.splitlines() if ln.startswith("HELD-NEW-TAB {")]
        if held:
            return self._held(ctx, json.loads(held[-1].split(" ", 1)[1]))
        pairs = [m for m in map(PAIR_LINE.match, text.splitlines()) if m]
        if pairs:
            runs = [{"arm": m.group(1), "ready_ms": _num(m.group(2)), "visible_ms": _num(m.group(3))} for m in pairs]
            return self._launch_pairs(ctx, runs)
        arms = [m for m in map(ARM_LINE.match, text.splitlines()) if m]
        if arms:
            return self._arm_lines(ctx, arms)
        raise BenchError(f"newtab: {path}: no instant-new-surfaces or held-new-tab output in it")

    def _press_rows(self, ctx: Context, sel: list[dict], labels: dict[str, str]) -> None:
        for field, (metric, unit, better) in PRESS_METRICS.items():
            samples = [_num(r.get(field)) for r in sel]
            if any(s is not None for s in samples):
                ctx.row(metric, unit=unit, better=better, samples=[s for s in samples if s is not None], labels=labels)
        ctx.row("missed_presses", sum(_num(r.get("visible_ms")) is None for r in sel), "count", labels=labels)

    def _surfaces(self, ctx: Context, runs: list[dict]) -> None:
        runs = [r for r in runs if r.get("command") == "new_tab"]
        if not runs:
            raise BenchError("newtab: the instant-new-surfaces output has no new_tab presses")
        groups: dict[tuple[str, ...], list[dict]] = {}
        for r in runs:
            if r.get("arm"):
                key = (r["arm"],)
            else:  # the warm arm: each phase (idle, load, slow) and workspace count apart
                phase, _, count = (r.get("phase") or "idle").partition("@")
                key = ("warm", phase, count.removesuffix("ws"))
            groups.setdefault(key, []).append(r)
        for key, sel in sorted(groups.items()):
            labels = {"arm": key[0]}
            if len(key) > 1:
                labels["phase"] = key[1]
                if key[2]:
                    labels["workspaces"] = key[2]
            self._press_rows(ctx, sel, labels)

    def _launch_pairs(self, ctx: Context, runs: list[dict]) -> None:
        for arm in ("first", "second", "warm_ref"):
            sel = [r for r in runs if r.get("arm") == arm]
            if not sel:
                continue
            labels = {"arm": f"launch_{arm}"}
            self._press_rows(ctx, sel, labels)
            openings = [r.get("opening") for r in sel if "opening" in r]
            if openings:
                ctx.row("spare_missed", sum(not (o or {}).get("spare") for o in openings), "count", labels=labels)

    def _arm_lines(self, ctx: Context, arms: list[re.Match]) -> None:
        """The log's ARM lines: per arm and metric, p50, p95 and n (no samples in a log)."""
        for m in arms:
            field, arm, n, missed, p50, p95 = m.groups()
            if field not in PRESS_METRICS:
                continue
            metric, unit, better = PRESS_METRICS[field]
            labels = {"arm": arm} if arm != "warm" else {"arm": "warm", "phase": "idle"}
            if _num(p50) is not None:
                ctx.row(metric, _num(p50), unit, better=better, p50=_num(p50), p95=_num(p95), n=int(n) or None,
                        labels=labels)
            if field == "visible_ms":
                ctx.row("missed_presses", int(missed), "count", labels=labels)
        ctx.notes.append("newtab: read from the log's ARM lines (p50/p95 only; the warm arm pools every idle phase)")

    def _held(self, ctx: Context, report: dict) -> None:
        by: dict[str, list[dict]] = {}
        for row in report.get("rows") or []:
            if row.get("round") == "film":
                continue  # the filmed take runs slower by design
            if row.get("invalid"):
                ctx.notes.append(f"held {row.get('round')} {row.get('scenario')}: {'; '.join(row['invalid'])[:200]}")
                continue
            hidden = row.get("not_for_a_person")
            if hidden is not None:
                # The tool keeps each number of such a row below this key (the sample take's row; a row with no proof
                # of its keys' order): a count of 0 for it would be a number that no take measured.
                why = str((hidden.get("why") if isinstance(hidden, dict) else None) or "the row says no cause")[:200]
                ctx.notes.append(f"held {row.get('round')} {row.get('scenario')}: no number of this row is for a person: {why}")
                continue
            by.setdefault(row.get("scenario") or "?", []).append(row)
        for scenario, rows in sorted(by.items()):
            labels = {"scenario": scenario}
            lat = [r.get("input_to_next_commit_ms") or {} for r in rows]
            p50s = [_num(x.get("p50")) for x in lat if _num(x.get("p50")) is not None]
            if p50s:
                p95s = sorted(_num(x.get("p95")) for x in lat if _num(x.get("p95")) is not None)
                ctx.row("input_to_next_commit_ms", sorted(p50s)[len(p50s) // 2], "ms",
                        p50=sorted(p50s)[len(p50s) // 2], p95=p95s[len(p95s) // 2] if p95s else None,
                        n=sum(int(x.get("n") or 0) for x in lat) or None, labels=labels)
            ctx.row("keys_without_effect", sum(int(r.get("keys_without_effect") or 0) for r in rows), "count",
                    better="none" if scenario == "close" else "lower", labels=labels)
            ctx.row("tabs_made", sum(int(r.get("tabs_made") or 0) for r in rows), "count", better="none", labels=labels)
            ctx.row("missed_frames", sum(int((r.get("frames") or {}).get("missed") or 0) for r in rows), "count",
                    labels=labels)
        if not by:
            ctx.notes.append("held-new-tab: no row measured what it names")


BENCH = NewTab()
