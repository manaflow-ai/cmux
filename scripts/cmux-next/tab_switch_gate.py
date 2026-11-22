#!/usr/bin/env python3
"""The tab switch gate: which pull requests it measures, and whether a tab-switch/v1 report met its budgets.

`.github/workflows/cmux-next-tab-switch.yml` runs `scripts/measure/tab-switch.sh` on a display Mac for a pull
request that touches a tab, a pane or the chat pane (SCOPE), and this module judges the report.json it writes.
Every switch in every scenario must meet every budget (BUDGETS):

  to_content_ms <= display_frame_ms   the returning tab shows its last frame within one display frame
  blank_frames == 0                   no frame shows an empty pane
  wrong_frames == 0                   no frame shows another tab's content
  shift_px == 0                       nothing moves when the tab comes back
  insert_ok is not False              the tab lands where it should go (null: the switch inserts nothing)
  anim_end_ok is not False            its animation ends where it should (null: no animation)

The harness's own `pass` and `budget_fail` are read too, but never trusted alone: a report whose `pass` is true
while a switch misses a budget fails here, and so does one the harness failed for a reason this module does not
know. A report that cannot be read, or lacks a load the run asked for, or a scenario with no switch, is no pass
(no verdict is never a green).

Usage:
  tab_switch_gate.py scope [--files-from FILE]           changed paths (one per line, stdin by default);
                                                         prints in_scope=true|false and the matched paths
  tab_switch_gate.py evaluate REPORT [--loads idle,cpu,agents] [--summary FILE] [--sheet NAME]
                                                         REPORT: report.json, or a .tar holding one;
                                                         exit 0 pass, 1 budget miss or unreadable report
"""
from __future__ import annotations

import argparse
import dataclasses
import fnmatch
import io
import json
import math
import os
import sys
import tarfile
from collections.abc import Iterable, Mapping, Sequence
from typing import Any

SCHEMA = "tab-switch/v1"
DEFAULT_LOADS = ("idle", "cpu", "agents")

# What the check measures: the tab strip and tabs, the pane that hosts a tab's content, the agent (chat) pane, its
# conversation and composer, and the daemon's tab and pane store ops; plus the gate and the harness themselves.
# `**` crosses directories, `*` does not. A path that matches EXCLUDE (tests, gallery fixtures, docs) is not a
# reason to measure.
SCOPE: tuple[str, ...] = (
    # The gate and the harness.
    ".github/workflows/cmux-next-tab-switch.yml",
    "scripts/cmux-next/tab_switch_gate.py",
    "scripts/measure/tab-switch.sh",
    "scripts/cmux-next/bench_tab_switch.py",
    "scripts/cmux-next/bench-tab-switch.sh",
    "scripts/cmux-next/tab-switch-stages.py",
    # Swift: the tab strip and tabs.
    "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/**",
    "Packages/macOS/CmuxNext/Sources/CmuxNextBrowserTabs/**",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/AgentTab*.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/AgentChatTab*.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/TabContent*.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/StripNewTab.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/PreparedTabClose.swift",
    # Swift: pane hosting (what mounts, parks and paints a tab's content in its pane).
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/PaneContentView*.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/PaneController*.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/PaneMounts.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/PaneTabBars.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/PaneFullWidthTabs.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/PaneSelectionPresenter.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/PaneBackdropState.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/**",
    "Packages/macOS/CmuxNext/Sources/CmuxNextLayout/**",
    # Web: the agent (chat) pane's mount, root, conversation and composer.
    "webviews/src/agent-session/acpmux/App.tsx",
    "webviews/src/agent-session/acpmux/main.tsx",
    "webviews/src/agent-session/acpmux/mount.tsx",
    "webviews/src/agent-session/acpmux/mountModel.tsx",
    "webviews/src/agent-session/acpmux/pane*.ts",
    "webviews/src/agent-session/acpmux/PaneBoundary.tsx",
    "webviews/src/agent-session/acpmux/snapshotCache.ts",
    "webviews/src/agent-session/acpmux/restoredTail.ts",
    "webviews/src/agent-session/acpmux/composerRestore.ts",
    "webviews/src/agent-session/acpmux/Composer*.tsx",
    "webviews/src/agent-session/acpmux/composer/**",
    "webviews/src/agent-session/acpmux/conversation/**",
    "webviews/src/agent-session/acpmux/chatSnapshot/**",
    # Rust: the daemon's tab and pane store ops.
    "cmux-tui/crates/cmux-tui-core/src/server/cmd_tabs.rs",
    "cmux-tui/crates/cmux-tui-core/src/server/cmd_panes.rs",
    "cmux-tui/crates/cmux-tui-core/src/server/raw_tab.rs",
    "cmux-tui/crates/cmux-tui-core/src/state/tabs.rs",
    "cmux-tui/crates/cmux-tui-core/src/state/conversation_tabs.rs",
    "cmux-tui/crates/cmux-tui-core/src/state/kept_tabs.rs",
)
EXCLUDE: tuple[str, ...] = (
    "**/Tests/**",
    "**/*Tests.swift",
    "**/Playground/**",
    "**/Demo/**",
    "**/*.test.ts",
    "**/*.test.tsx",
    "**/*.gallery.*",
    "**/*.md",
)


def _glob(pattern: str, path: str) -> bool:
    """fnmatch where `*` stays inside one path segment and `**` spans any number of them (zero included)."""
    pattern_parts, path_parts = pattern.split("/"), path.split("/")

    def match(i: int, j: int) -> bool:
        if i == len(pattern_parts):
            return j == len(path_parts)
        if pattern_parts[i] == "**":
            return any(match(i + 1, k) for k in range(j, len(path_parts) + 1))
        return j < len(path_parts) and fnmatch.fnmatchcase(path_parts[j], pattern_parts[i]) and match(i + 1, j + 1)

    return match(0, 0)


def scoped_paths(paths: Iterable[str]) -> list[str]:
    """The changed PATHS that put a pull request in the check's scope, in their order."""
    hits = []
    for raw in paths:
        path = raw.strip().removeprefix("./")
        if not path:
            continue
        if any(_glob(p, path) for p in EXCLUDE):
            continue
        if any(_glob(p, path) for p in SCOPE):
            hits.append(path)
    return hits


# --- the report -------------------------------------------------------------------------------------------------

class ReportError(ValueError):
    """The report cannot be judged. Never a pass."""


@dataclasses.dataclass
class Scenario:
    name: str
    load: str
    switches: int = 0
    worst_to_content_ms: float | None = None
    frame_ms: float | None = None
    blank_frames: int = 0
    wrong_frames: int = 0
    worst_shift_px: float = 0
    insert_misses: int = 0
    anim_misses: int = 0
    harness_fail: list[str] = dataclasses.field(default_factory=list)
    misses: list[str] = dataclasses.field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.misses


@dataclasses.dataclass
class Verdict:
    build: str
    display_hz: float | None
    scenarios: list[Scenario]
    failures: list[str]  # every reason this report is not a pass, scenario misses included

    @property
    def ok(self) -> bool:
        return not self.failures


def _number(value: Any, where: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ReportError(f"{where} is {value!r}, not a number")
    return float(value)


def _count(value: Any, where: str) -> int:
    number = _number(value, where)
    if number < 0 or number != int(number):
        raise ReportError(f"{where} is {value!r}, not a count")
    return int(number)


def _tri(value: Any, where: str) -> bool | None:
    if value is None or isinstance(value, bool):
        return value
    raise ReportError(f"{where} is {value!r}, not true, false or null")


def _fmt(value: float) -> str:
    return f"{value:.1f}".rstrip("0").rstrip(".") if value != int(value) else str(int(value))


def judge_scenario(raw: Mapping[str, Any], index: int, display_hz: float | None) -> Scenario:
    if not isinstance(raw, Mapping):
        raise ReportError(f"scenarios[{index}] is not an object")
    name = raw.get("name")
    load = raw.get("load")
    if not isinstance(name, str) or not name:
        raise ReportError(f"scenarios[{index}].name is missing")
    if load not in DEFAULT_LOADS:
        raise ReportError(f"scenario {name}: load is {load!r}, not one of {', '.join(DEFAULT_LOADS)}")
    scenario = Scenario(name=name, load=load)
    harness_fail = raw.get("budget_fail", [])
    if not isinstance(harness_fail, list):
        raise ReportError(f"scenario {name}: budget_fail is not a list")
    scenario.harness_fail = [str(item) for item in harness_fail]
    switches = raw.get("switches")
    if not isinstance(switches, list):
        raise ReportError(f"scenario {name}: switches is not a list")
    if not switches:
        scenario.misses.append("no switch was measured")
    late = 0
    for k, switch in enumerate(switches):
        where = f"scenario {name} switch {k}"
        if not isinstance(switch, Mapping):
            raise ReportError(f"{where} is not an object")
        to_content = _number(switch.get("to_content_ms"), f"{where} to_content_ms")
        if switch.get("display_frame_ms") is not None:
            frame = _number(switch.get("display_frame_ms"), f"{where} display_frame_ms")
        elif display_hz:
            frame = 1000.0 / display_hz
        else:
            raise ReportError(f"{where} has no display_frame_ms and the report no display_hz")
        if frame <= 0:
            raise ReportError(f"{where} display_frame_ms is {frame}")
        scenario.switches += 1
        if scenario.worst_to_content_ms is None or to_content - frame > scenario.worst_to_content_ms - scenario.frame_ms:
            scenario.worst_to_content_ms, scenario.frame_ms = to_content, frame
        if to_content > frame:
            late += 1
        scenario.blank_frames += _count(switch.get("blank_frames"), f"{where} blank_frames")
        scenario.wrong_frames += _count(switch.get("wrong_frames"), f"{where} wrong_frames")
        scenario.worst_shift_px = max(scenario.worst_shift_px, abs(_number(switch.get("shift_px"), f"{where} shift_px")))
        if _tri(switch.get("insert_ok"), f"{where} insert_ok") is False:
            scenario.insert_misses += 1
        if _tri(switch.get("anim_end_ok"), f"{where} anim_end_ok") is False:
            scenario.anim_misses += 1
    if late:
        scenario.misses.append(f"{late} of {scenario.switches} switches showed content after one display frame "
                               f"(worst {_fmt(scenario.worst_to_content_ms)} ms, frame {_fmt(scenario.frame_ms)} ms)")
    if scenario.blank_frames:
        scenario.misses.append(f"{scenario.blank_frames} blank frames")
    if scenario.wrong_frames:
        scenario.misses.append(f"{scenario.wrong_frames} wrong frames")
    if scenario.worst_shift_px:
        scenario.misses.append(f"{_fmt(scenario.worst_shift_px)} px shift")
    if scenario.insert_misses:
        scenario.misses.append(f"{scenario.insert_misses} switches inserted the tab in the wrong place")
    if scenario.anim_misses:
        scenario.misses.append(f"{scenario.anim_misses} animations ended in the wrong place")
    if scenario.harness_fail and not scenario.misses:
        scenario.misses.append("the harness failed it: " + "; ".join(scenario.harness_fail))
    return scenario


def judge(report: Any, loads: Sequence[str] = DEFAULT_LOADS) -> Verdict:
    """The verdict on a parsed tab-switch/v1 REPORT for a run that asked for LOADS. Raises ReportError when the
    report cannot be judged."""
    if not isinstance(report, Mapping):
        raise ReportError("the report is not a JSON object")
    if report.get("schema") != SCHEMA:
        raise ReportError(f"schema is {report.get('schema')!r}, not {SCHEMA!r}")
    display_hz = report.get("display_hz")
    display_hz = None if display_hz is None else _number(display_hz, "display_hz")
    if display_hz is not None and display_hz <= 0:
        raise ReportError(f"display_hz is {display_hz}")
    raw = report.get("scenarios")
    if not isinstance(raw, list) or not raw:
        raise ReportError("the report has no scenarios")
    scenarios = [judge_scenario(item, i, display_hz) for i, item in enumerate(raw)]
    failures = [f"{s.name} ({s.load}): {miss}" for s in scenarios for miss in s.misses]
    for load in loads:
        if not any(s.load == load for s in scenarios):
            failures.append(f"no scenario ran under load {load}")
    harness_pass = report.get("pass")
    if not isinstance(harness_pass, bool):
        failures.append(f"the harness's pass is {harness_pass!r}, not true or false")
    elif not harness_pass and not failures:
        failures.append("the harness reported pass: false with every switch in budget")
    elif harness_pass and failures:
        failures.append("the harness reported pass: true, but the budgets above were missed")
    return Verdict(build=str(report.get("build") or "?"), display_hz=display_hz, scenarios=scenarios,
                   failures=failures)


def load_report(path: str) -> tuple[Any, list[str]]:
    """The parsed report at PATH (report.json, or a tar holding one) and the image names the tar holds."""
    if tarfile.is_tarfile(path):
        with tarfile.open(path) as tar:
            members = [m for m in tar.getmembers() if m.isfile()]
            reports = [m for m in members if os.path.basename(m.name) == "report.json"]
            if not reports:
                raise ReportError(f"{path} holds no report.json")
            data = tar.extractfile(reports[0]).read()
            images = sorted(m.name for m in members if m.name.lower().endswith((".png", ".jpg", ".jpeg")))
    else:
        with open(path, "rb") as handle:
            data = handle.read()
        images = []
    try:
        return json.load(io.BytesIO(data)), images
    except ValueError as error:
        raise ReportError(f"report.json is not JSON: {error}") from error


def summary_markdown(verdict: Verdict | None, error: str | None = None, sheet: str | None = None) -> str:
    title = "### Tab switch (frames, under load): "
    if verdict is None:
        return f"{title}no verdict\n\nThe report could not be judged: {error}. No verdict is never a pass.\n"
    lines = [title + ("pass" if verdict.ok else "fail"), "",
             f"Build `{verdict.build}`, display {_fmt(verdict.display_hz) + ' Hz' if verdict.display_hz else 'Hz unknown'}. "
             "Budgets: content within one display frame, 0 blank frames, 0 wrong frames, 0 px shift.", "",
             "| scenario | load | switches | worst to content (ms) | frame (ms) | blank | wrong | shift (px) "
             "| wrong insert | wrong anim end | verdict |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|"]
    for s in verdict.scenarios:
        worst = "-" if s.worst_to_content_ms is None else _fmt(s.worst_to_content_ms)
        frame = "-" if s.frame_ms is None else _fmt(s.frame_ms)
        lines.append(f"| {s.name} | {s.load} | {s.switches} | {worst} | {frame} | {s.blank_frames} | {s.wrong_frames} "
                     f"| {_fmt(s.worst_shift_px)} | {s.insert_misses} | {s.anim_misses} | {'ok' if s.ok else 'miss'} |")
    if verdict.failures:
        lines += ["", "Missed:", *[f"- {failure}" for failure in verdict.failures]]
    if sheet:
        lines += ["", f"Contact sheet: {sheet}"]
    return "\n".join(lines) + "\n"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="command", required=True)
    scope = sub.add_parser("scope")
    scope.add_argument("--files-from", default="-")
    evaluate = sub.add_parser("evaluate")
    evaluate.add_argument("report")
    evaluate.add_argument("--loads", default=",".join(DEFAULT_LOADS))
    evaluate.add_argument("--summary", default="")
    evaluate.add_argument("--sheet", default="", help="where the contact sheet is (an artifact name or URL)")
    args = parser.parse_args(argv)

    if args.command == "scope":
        if args.files_from == "-":
            text = sys.stdin.read()
        else:
            with open(args.files_from, encoding="utf-8") as handle:
                text = handle.read()
        hits = scoped_paths(text.splitlines())
        print(f"in_scope={'true' if hits else 'false'}")
        for path in hits[:20]:
            print(f"  {path}", file=sys.stderr)
        if len(hits) > 20:
            print(f"  ... and {len(hits) - 20} more", file=sys.stderr)
        return 0

    loads = [load for load in args.loads.split(",") if load]
    verdict, error = None, None
    try:
        report, images = load_report(args.report)
        verdict = judge(report, loads)
    except (OSError, ReportError, tarfile.TarError) as caught:
        error, images = str(caught), []
    sheet = " in ".join(part for part in (", ".join(images), args.sheet) if part)
    text = summary_markdown(verdict, error, sheet or None)
    print(text)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write(text)
    return 0 if verdict is not None and verdict.ok else 1


if __name__ == "__main__":
    sys.exit(main())
