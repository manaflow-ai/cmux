"""An agent UI surface card streaming into a long chat, in the live pane (golden.py `ui_surface_stream`).

plans/cmux-next/agent-ui-surfaces-DESIGN.md, "Streaming and frames": a streamed surface card adds no frame
over 16 ms to the chat. The scenario turns Labs `labs.agentUiSurfaces` on, then streams through the DEBUG
`debug.agent_pane` `stream` action with `surface` (webviews surfaceStreamDebug.ts): ~1,500 synthetic rows and a
running turn, then one tool row updated 40 times at 60 Hz. The `with` arm puts the golden
`cmux-catalog-cards` surface on the row, growing over the updates (webviews uiSurfaceStreamFixture.ts, the same
fixture as webviews/bench/ui-surface-stream-frames.bench.ts); the `without` arm streams the same row at the same
cadence with no surface. Arms alternate, ROUNDS each, in one run of one app.

Per arm it reports the page's animation-frame intervals from the first update to 200 ms after the last (p50,
p95, max, frames over 16.7 ms), long tasks where the engine reports them (Chromium; null in WebKit), and, for
context, the app's display-link frames over each whole call (`debug.frames`: the seed included). The flag:
`settings.set` is tried first; `labs.agentUiSurfaces` is user-only (agent policy), so the socket is refused
without a person's confirm sheet, and the scenario then edits the scratch config golden.sh made for this app
(CMUX_NEXT_CONFIG_FILE, `{}`), as a person editing cmux-next.json would; the app's file watcher applies it. It
never edits any other file, and restores the file's text afterwards. A `with` round whose page did not have the
flag on, or drew no card, counts as not measured.

Report only: no threshold fails a run.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

FLAG = "labs.agentUiSurfaces"
FIXTURE = "cmux-catalog-cards"
ROUNDS = 3
STREAM = {"rows": 1500, "updates": 40, "hz": 60, "trace": 1}
BUDGET_MS = 16.7
ARMS = ("without", "with")


def _flag_value(driver) -> tuple[object, str]:
    got = driver.call("settings.get", {"path": FLAG})
    return got.get("value"), str(got.get("file") or "")


def _wait_flag(driver, want: bool, seconds: float = 8) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if (_flag_value(driver)[0] is True) == want:
            return True
        time.sleep(0.25)
    return False


def set_flag(driver, config: Path, on: bool, original: str | None = None) -> dict:
    """Turns the flag `on` (or back, writing `original`, the config text before); says how and whether the app read it."""
    from golden import rpc  # the raw call: the expected user-only refusal is not a driver error

    reply = rpc(driver.path, "settings.set", {"path": FLAG, "value": on})
    if "error" not in reply and _wait_flag(driver, on):
        return {"how": "settings.set", "on": on, "read_back": True}
    refused = reply.get("error")
    config = config.resolve()
    _, file = _flag_value(driver)
    if not file or Path(file).resolve() != config:
        return {"how": "none", "on": on, "read_back": False, "settings_set": refused,
                "error": f"the app's config is {file or 'unknown'}, not this run's scratch {config}; left alone"}
    if original is not None:
        text = original
    else:
        try:
            root = json.loads(config.read_text() or "{}")
        except (OSError, ValueError):
            root = {}
        root = root if isinstance(root, dict) else {}
        labs = root.get("labs") if isinstance(root.get("labs"), dict) else {}
        root["labs"] = {**labs, "agentUiSurfaces": on}
        text = json.dumps(root, indent=2) + "\n"
    staged = config.with_name(config.name + ".ui-surface-stream.tmp")
    staged.write_text(text)
    os.replace(staged, config)
    return {"how": "scratch config", "on": on, "read_back": _wait_flag(driver, on), "settings_set": refused}


def _pane(driver) -> tuple[dict, dict]:
    """The chat to stream into: the one shown (golden.py's transcript opened it), else a new one."""
    from golden import rpc

    ready = rpc(driver.path, "debug.agent_pane", {"action": "readiness"}, 30)
    if "error" in ready:
        driver.call("action.run", {"action": "palette.newAgentChat"})
        for _ in range(20):
            ready = rpc(driver.path, "debug.agent_pane", {"action": "readiness"}, 30)
            if "error" not in ready:
                break
            time.sleep(0.5)
        time.sleep(2)
    return ready, ({"pane": ready["pane"]} if "error" not in ready and ready.get("pane") else {})


def drive(driver, out: Path, config: Path | None = None) -> None:
    """`config`: the scratch config this run launched the app with (golden.sh's `out/cmux-next.json` by default;
    scripts/cmux-next/ui-surface-stream-live.py passes its BenchApp's)."""
    config = config or out / "cmux-next.json"
    try:
        original = config.read_text()
    except OSError:
        original = None
    before = _flag_value(driver)[0]
    flag = set_flag(driver, config, True)
    rounds: list[dict] = []
    ready: dict = {}
    try:
        ready, target = _pane(driver)
        for index in range(ROUNDS):
            for arm in ARMS:
                driver.call("debug.frames", {"action": "start"})
                result = driver.call("debug.agent_pane", {"action": "stream", **STREAM, **target,
                                                          "surface": FIXTURE if arm == "with" else "none"}, timeout=90)
                result["app_frames"] = driver.call("debug.frames", {"action": "stop"})
                result["round"], result["arm"] = index, arm
                rounds.append(result)
                time.sleep(0.5)
    finally:
        restored = set_flag(driver, config, before is True, original if flag.get("how") == "scratch config" else None)
    driver.save("ui_surface_stream", {"flag": flag, "flag_restored": restored, "flag_before": before,
                                      "ready": ready, "stream": STREAM, "rounds": rounds})


def _percentile(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))] if ordered else 0.0


def _measured(result: dict) -> str | None:
    """Why a round measured nothing, or None."""
    if "error" in result and "intervals_ms" not in result:
        return str(result["error"])[:160]
    if not result.get("intervals_ms"):
        return "no per-frame intervals"
    if result.get("arm") == "with":
        if result.get("flag_on") is not True:
            return "the page had labs.agentUiSurfaces off"
        if result.get("card_drawn") is not True:
            return "the card never drew"
    return None


def _arm(rounds: list[dict], refresh: float) -> dict:
    intervals = [float(value) for result in rounds for value in result.get("intervals_ms") or []]
    long = [result.get("long_tasks") for result in rounds]
    app = [result.get("app_frames") or {} for result in rounds]
    return {
        "rounds": len(rounds),
        "frames": len(intervals),
        "p50_ms": round(_percentile(intervals, 0.5), 2),
        "p95_ms": round(_percentile(intervals, 0.95), 2),
        "max_ms": round(max(intervals, default=0.0), 2),
        "over_16_7": sum(1 for value in intervals if value > BUDGET_MS),
        # Over 1.5 refresh periods: a missed vsync on this display.
        "missed": sum(1 for value in intervals if refresh > 0 and value > 1.5 * refresh),
        "long_tasks": None if any(entry is None for entry in long) else sum(int(entry.get("count", 0)) for entry in long),
        "longest_task_ms": None if any(entry is None for entry in long) else max(float(entry.get("max_ms", 0)) for entry in long),
        "react_ms": [result.get("react_ms") for result in rounds],
        "app_over_16_7": sum(int(entry.get("over_16_7_ms") or 0) for entry in app),
        "app_max_ms": round(max((float(entry.get("max_ms") or 0) for entry in app), default=0.0), 2),
    }


def judge(data: dict, refresh: float) -> dict:
    if "error" in data and "rounds" not in data:
        return {"ok": True, "problems": [], "measured": False, "note": f"not measured: {data['error']}"}
    flag = data.get("flag") or {}
    rounds = data.get("rounds") or []
    skipped = [f"{result.get('arm')} {result.get('round')}: {why}" for result in rounds if (why := _measured(result))]
    good = [result for result in rounds if not _measured(result)]
    arms = {arm: _arm([result for result in good if result.get("arm") == arm], refresh) for arm in ARMS}
    measured = all(arms[arm]["rounds"] > 0 for arm in ARMS)
    verdict = {"ok": True, "problems": [], "measured": measured, "refresh_ms": refresh, "flag": flag,
               "flag_restored": data.get("flag_restored"), "skipped": skipped, **arms}
    if measured:
        added = arms["with"]["over_16_7"] - arms["without"]["over_16_7"]
        verdict["added_over_16_7"] = added
        # The design's claim, reported: the card adds no frame over 16.7 ms to the same stream without it.
        verdict["claim_holds"] = added <= 0
    else:
        verdict["note"] = "not measured: " + ("; ".join(skipped[:3]) or "no round in an arm")
    return verdict


def _arm_text(name: str, arm: dict) -> str:
    long = "n/a" if arm["long_tasks"] is None else f"{arm['long_tasks']} (longest {arm['longest_task_ms']:g} ms)"
    return (f"{name} p50/p95/max {arm['p50_ms']:g}/{arm['p95_ms']:g}/{arm['max_ms']:g} ms, "
            f">16.7 ms {arm['over_16_7']}/{arm['frames']}, missed {arm['missed']}, long tasks {long}, "
            f"app frames >16.7 ms {arm['app_over_16_7']} (whole call)")


def markdown_row(verdict: dict) -> str:
    flag = verdict.get("flag") or {}
    how = f"flag via {flag.get('how', '?')}{'' if flag.get('read_back') else ' (not read back)'}"
    if not verdict.get("measured"):
        return f"| ui_surface_stream | report | | | | {verdict.get('note', 'not measured')}; {how} (reported only) |"
    holds = "holds" if verdict.get("claim_holds") else "does NOT hold"
    timing = f"{verdict['with']['p95_ms']:g} / {verdict['with']['max_ms']:g} ms"
    notes = [f"{FIXTURE} card, 40 updates at 60 Hz over ~1,500 rows",
             _arm_text("with", verdict["with"]), _arm_text("without", verdict["without"]),
             f"card adds {verdict['added_over_16_7']} frame(s) over 16.7 ms: claim {holds}", how]
    if verdict.get("skipped"):
        notes.append(f"{len(verdict['skipped'])} round(s) skipped")
    return f"| ui_surface_stream | report | | | {timing} | {'; '.join(notes)} (reported only) |"
