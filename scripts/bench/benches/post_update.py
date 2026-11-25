"""post-update: the first launch of cmux NEXT after an update, and what moves or flashes in it.

One bench, one mode per harness (--arg mode=NAME); every row carries labels mode=NAME and arm=base|head.

  update-click (default)  scripts/measure/update-click-ab.sh (CMUX-571): a real Sparkle update of a bench app to a
               newer copy of itself, Restart to Update clicked click_delay seconds (default 3) after it staged, base
               and head built on one Mac and interleaved. Rows from its `UCA <side> <round>` lines, rounds as samples:
               click_to_relaunch, click_to_v1_exit, prewarm_wait, prewarm_total, v2_first_frame and
               v2_home_first_page (from v2's process start), click_to_home. Head is --build <sha> (or the NIGHTLY's
               source commit); base is --arg base=<sha>, else the feat-cmux-next tip. Two builds: about 1 to 2 hours.
  shift        scripts/measure/relaunch-shift.sh --variants=update: a seeded session (windows, splits, terminals,
               pages, agent chats) relaunched through the updater's relaunch path, every window recorded from its
               first frame. Rows per relaunch from `LAUNCH-SHIFT <n>-update` lines: first_paint_ms, last_paint_ms,
               last_change_ms, and counts of geometry_frames, pixel_frames, blank_frames, blank_first, window_moves,
               layout_passes, view_layouts, errors; the chat's shifts, scroll jumps, rows appearing late and first
               rows come from the `RELAUNCH-SHIFT` medians. It builds the step's checkout (a feat-cmux-next commit:
               --build <sha>, or the NIGHTLY's source commit). About 30 minutes.
  fresh-copy   scripts/measure/nightly-fresh-launch.sh: the first exec of a new copy of the app (what an update's
               new bundle pays: signature checks, dyld's first look) next to the same copy again and a warm home.
               Rows per launch from `NFL-LAUNCH <round> <copy>` lines, label copy=fresh-copy|same-copy|warm|...:
               pre_main, to_frame, to_page, first_frame, home_first_page, home_rendered. Takes the NIGHTLY's DMG
               (--build nightly, about 4 minutes; the mode the nightly runs) or builds a feat-cmux-next commit.

Each mode is one entry in MODES (its fleet step and the parser for its output); a new post-update harness joins as one
more entry, and the post-update hitch harness from the post-update-lag-spikes lane goes in as mode=lag-spikes.
`--import PATH` reads a step's log (the mode is found from its lines, or --arg mode=NAME) or the mode's artifact.
"""
from __future__ import annotations

import importlib.util
import json
import re
import tarfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context, base_tip, parse_build

UCA = re.compile(r"(?:^|\s)UCA (base|head) (\d+) (\{.*\})\s*$")
UCA_KEYS = ("click_to_relaunch", "click_to_v1_exit", "prewarm_wait", "prewarm_total", "v2_first_frame",
            "v2_home_first_page", "click_to_home")
SHIFT = re.compile(r"(?:^|\s)LAUNCH-SHIFT (\d+)-(\w+) (\{.*\})\s*$")
SHIFT_MEDIAN = re.compile(r"^RELAUNCH-SHIFT (\{.*\})\s*$")
SHIFT_MS = ("first_paint_ms", "last_paint_ms", "last_change_ms")
SHIFT_COUNTS = ("geometry_frames", "pixel_frames", "blank_frames", "blank_first", "window_moves", "layout_passes",
                "view_layouts", "closed_while_recorded", "errors")
# The shown chat, from the run's medians only (LAUNCH-SHIFT lines leave it out). chat_first_rows: rows on its
# first frame (more is better); the others are rows or moves after it.
SHIFT_CHAT = {"chat_shifts": "lower", "chat_scroll_jumps": "lower", "chat_appeared": "lower", "chat_first_rows": "higher"}
NFL = re.compile(r"^(?:\[(base|head)\] )?NFL-LAUNCH (\d+) ([\w-]+) (\{.*\})\s*$")
NFL_PHASES = {"pre_main": "pre_main", "to_frame": "to_frame", "to_page": "to_page", "frame": "first_frame",
              "page": "home_first_page", "harness": "home_rendered"}
HOSTS = (re.compile(r'(?:NFL|L5) host (\S+) chip="([^"]*)" macOS (\S+)'), re.compile(r'UCA host chip="([^"]*)" macOS (\S+)'))


def _host(ctx: Context, text: str) -> None:
    if ctx.host.get("name") not in ("fleet", "", None):
        return
    m = HOSTS[0].search(text)
    if m:
        ctx.host.update({"name": m.group(1), "chip": m.group(2), "os": f"macOS {m.group(3)}"})
        return
    m = HOSTS[1].search(text)
    if m:
        ctx.host.update({"chip": m.group(1), "os": f"macOS {m.group(2)}"})


def _uca_metrics() -> Callable[[dict], dict]:
    """update-click-ab.py's own metrics(), so an archive's timeline.json files read exactly as the step reads them."""
    path = REPO_ROOT / "scripts/measure/update-click-ab.py"
    spec = importlib.util.spec_from_file_location("update_click_ab", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.metrics


def _head_sha(ctx: Context, mode: str) -> str:
    sha = ctx.build.get("sha")
    if not sha:
        raise BenchError(f"post-update mode={mode} builds a commit: pass --build <sha> (the NIGHTLY's feed item "
                         "names no source commit)")
    return sha


# --- update-click ------------------------------------------------------------------------------------------------
def update_click_step(ctx: Context) -> tuple[list[str], str, int, str | None]:
    head = _head_sha(ctx, "update-click")
    base = parse_build(ctx.arg("base"))["sha"] if ctx.arg("base") else base_tip()
    args = [f"base={base}", f"head={head}", f"rounds={ctx.arg('rounds', '3')}"]
    for key in ("click_delay", "stress"):
        if ctx.arg(key):
            args.append(f"{key}={ctx.arg(key)}")
    return args, ".build/update-click-ab/report.tgz", 7200, None


def update_click_parse(ctx: Context, text: str, tar: tarfile.TarFile | None) -> bool:
    per: dict[str, dict[str, dict]] = {}
    for line in text.splitlines():
        m = UCA.search(line)
        if m:
            per.setdefault(m.group(1), {})[m.group(2)] = json.loads(m.group(3))
    if not per and tar is not None:
        metrics = _uca_metrics()
        for member in tar.getmembers():
            m = re.search(r"run-(base|head)-(\d+)/timeline\.json$", member.name)
            if m:
                result = json.loads(tar.extractfile(member).read())
                per.setdefault(m.group(1), {})[m.group(2)] = metrics(result)
    for side, rounds in per.items():
        labels = {"mode": "update-click", "arm": side}
        for key in UCA_KEYS:
            ctx.row(key, unit="ms", samples=[r[key] for r in rounds.values() if r.get(key) is not None], labels=labels)
    return bool(per)


# --- shift -------------------------------------------------------------------------------------------------------
def shift_step(ctx: Context) -> tuple[list[str], str, int, str | None]:
    args = [f"--rounds={ctx.arg('rounds', '3')}", f"--variants={ctx.arg('variants', 'update')}",
            f"--config={ctx.arg('config', 'bench')}"]
    if ctx.arg("seconds"):
        args.append(f"--seconds={ctx.arg('seconds')}")
    return args, "artifacts/relaunch-shift/report.json", 5400, _head_sha(ctx, "shift")


def shift_parse(ctx: Context, text: str, tar: tarfile.TarFile | None) -> bool:
    rounds: dict[str, dict] = {}
    median = None
    variant = ctx.arg("variants", "update")
    stripped = text.strip()
    if stripped.startswith("{"):  # the step's report.json
        report = json.loads(stripped)
        for i, r in enumerate(report.get("rounds") or [], 1):
            rounds[str(i)] = {**(r.get("total") or {}), "errors": r.get("errors", (r.get("total") or {}).get("errors"))}
        median = report.get("median")
    else:
        for line in text.splitlines():
            m = SHIFT.search(line)
            if m:  # the step prints each round twice (live and again at the end); one per round
                rounds[m.group(1)] = json.loads(m.group(3))
                variant = m.group(2)
                continue
            m = SHIFT_MEDIAN.match(line.strip())
            if m:
                median = json.loads(m.group(1))
    if not rounds:
        return False
    labels = {"mode": "shift", "variant": variant}
    for key in SHIFT_MS:
        ctx.row(key, unit="ms", samples=[r[key] for r in rounds.values() if isinstance(r.get(key), (int, float))],
                labels=labels)
    for key in SHIFT_COUNTS:
        ctx.row(key, unit="count", samples=[r[key] for r in rounds.values() if isinstance(r.get(key), (int, float))],
                labels=labels)
    for key, better in SHIFT_CHAT.items():
        if median and isinstance(median.get(key), (int, float)):
            ctx.row(key, median[key], "count", better=better, labels=labels)
    return True


# --- fresh-copy --------------------------------------------------------------------------------------------------
def fresh_copy_step(ctx: Context) -> tuple[list[str], str, int, str | None]:
    args = [f"rounds={ctx.arg('rounds', '3')}"]
    if ctx.arg("arms"):
        args.append(f"arms={ctx.arg('arms')}")
    if ctx.build["channel"] == "nightly" and not ctx.arg("build_from_source"):
        return [f"dmg={ctx.build.get('url') or 'nightly'}", *args], ".build/nightly-fresh-launch/report.tgz", 1800, None
    args = ["dmg=build", *args]
    if ctx.arg("base"):
        args.append(f"base={parse_build(ctx.arg('base'))['sha']}")
    return args, ".build/nightly-fresh-launch/report.tgz", 5400, _head_sha(ctx, "fresh-copy")


def fresh_copy_parse(ctx: Context, text: str, tar: tarfile.TarFile | None) -> bool:
    # A list, not keyed by round: with base= each round is its own rounds=1 run, so every line says round 1.
    per: dict[tuple[str, str], list[dict]] = {}
    for line in text.splitlines():
        m = NFL.match(line.strip())
        if m:
            row = json.loads(m.group(4))
            if row.get("rendered_at") is not None:
                per.setdefault((m.group(1) or "head", m.group(3)), []).append(row.get("phases") or {})
    for (side, copy), rounds in per.items():
        labels = {"mode": "fresh-copy", "arm": side, "copy": copy}
        for key, metric in NFL_PHASES.items():
            ctx.row(metric, unit="ms", samples=[r[key] for r in rounds if r.get(key) is not None], labels=labels)
    return bool(per)


@dataclass(frozen=True)
class Mode:
    script: str
    step: Callable[[Context], tuple[list[str], str, int, str | None]]  # (args, artifact, timeout, ref or None)
    parse: Callable[[Context, str, "tarfile.TarFile | None"], bool]
    marker: str  # a line prefix only this harness prints, to find the mode of an imported log


MODES: dict[str, Mode] = {
    "update-click": Mode("scripts/measure/update-click-ab.sh", update_click_step, update_click_parse, "UCA "),
    "shift": Mode("scripts/measure/relaunch-shift.sh", shift_step, shift_parse, "LAUNCH-SHIFT "),
    "fresh-copy": Mode("scripts/measure/nightly-fresh-launch.sh", fresh_copy_step, fresh_copy_parse, "NFL-LAUNCH "),
}


class PostUpdate(Bench):
    name = "post-update"
    summary = "First launch after an update: click to Home, the new copy's first exec, shifts and flashes after it"
    units = "ms, count"
    owner = "launch (CMUX-571, next-launch-instant)"
    hosts = ("fleet",)
    harness = "scripts/measure/update-click-ab.sh"
    version = "1"
    # One to three rounds per run, and a relaunch's paint times move by hundreds of ms: compare wide.
    thresholds = {"first_paint_ms": 25.0, "last_paint_ms": 25.0, "last_change_ms": 25.0, "layout_passes": 25.0,
                  "view_layouts": 25.0, "prewarm_wait": 25.0, "prewarm_total": 25.0, "to_page": 25.0}
    floors = {"geometry_frames": 2.0, "pixel_frames": 2.0, "layout_passes": 20.0, "view_layouts": 500.0,
              "chat_appeared": 1.0, "chat_first_rows": 1.0, "to_page": 50.0, "prewarm_wait": 50.0}
    nightly = True
    nightly_args = {"mode": "fresh-copy", "rounds": "3"}

    def _mode(self, ctx: Context) -> tuple[str, Mode]:
        name = ctx.arg("mode", "update-click")
        if name not in MODES:
            raise BenchError(f"post-update: no mode {name!r}; modes: {', '.join(MODES)}")
        return name, MODES[name]

    def run(self, ctx: Context) -> None:
        name, mode = self._mode(ctx)
        args, artifact, timeout, ref = mode.step(ctx)
        res = ctx.fleet_step(mode.script, args, artifact, labels=tuple(ctx.arg("labels", "measure").split(",")), display=True,
                             timeout=timeout, ref=ref)
        self.ingest(ctx, res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        tar = tarfile.open(path) if tarfile.is_tarfile(path) else None
        try:
            if tar is not None:
                text = ""
                for member in tar.getmembers():
                    if member.isfile() and member.name.endswith((".log", "report.json")) and "/" not in member.name.strip("./"):
                        text += tar.extractfile(member).read().decode("utf-8", "replace") + "\n"
            else:
                text = path.read_text(encoding="utf-8", errors="replace")
            _host(ctx, text)
            if ctx.arg("mode"):
                names = [self._mode(ctx)[0]]
            else:
                names = [n for n, m in MODES.items() if m.marker in text] or list(MODES)
            parsed = next((n for n in names if MODES[n].parse(ctx, text, tar)), None)
            if parsed is None:
                raise BenchError(f"{path}: no post-update lines ({', '.join(m.marker.strip() for m in MODES.values())})")
        finally:
            if tar is not None:
                tar.close()
        # Each row names the mode's own harness, and its version the mode.
        version = ctx.harness_version.replace(f"{self.name}@", f"{self.name}:{parsed}@", 1)
        ctx.harness_version = version
        for row in ctx.rows:
            row["harness"] = {"name": MODES[parsed].script, "version": version}


BENCH = PostUpdate()
