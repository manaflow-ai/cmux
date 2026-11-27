"""Summarizes scripts/measure/update-click-ab.sh: one UCA line per update, then each side's medians and p95 (ms).

Phases (ms from the Restart to Update click, ask-ad4a68e740): windows_hidden (the old windows leave), will_relaunch
(Sparkle commits), will_terminate, click_to_v1_exit, v2_process_start (the install and relaunch done), click_to_v2_frame
(the new build's first window frame), click_to_restored (its sidebar rows, launch snapshot and daemon snapshot all in).
With frames=1, the transition-frame verdicts of scripts/measure/update_frames.py per update and in all.

Usage: python3 -I update-click-ab.py OUT   (OUT holds run-<side>-<round>/timeline.json from update-harness/run.py)
"""
import json
import re
import statistics
import sys
from pathlib import Path

# The pre-warm's closing line ends "; N ms in all" (StagedUpdatePrewarm.perform).
TOTAL = re.compile(r"; (\d+) ms in all")


def metrics(result):
    t = result.get("timeline") or {}
    click_to, v2 = t.get("click_to") or {}, t.get("click_to_v2") or {}
    start = v2.get("process_start")

    def since_v2(name):
        at = v2.get(name)
        return None if at is None or start is None else at - start

    totals = [int(m.group(1)) for line in result.get("prewarm_log") or [] for m in [TOTAL.search(line)] if m]
    wait_start = click_to.get("prewarm_wait_start")
    wait_end = click_to.get("prewarm_wait_end.done") or click_to.get("prewarm_wait_end.partial")
    hidden = next((v for k, v in click_to.items() if k.startswith("windows_") and v is not None), None)
    restored = [v2.get(k) for k in ("launch.sidebar_rows_shown", "launch.launch_snapshot_shown", "launch.daemon_snapshot_loaded")]
    return {
        "windows_hidden": hidden,
        "will_terminate": click_to.get("will_terminate"),
        "v2_process_start": start,
        "click_to_v2_frame": v2.get("launch.first_window_frame_committed"),
        "click_to_restored": max(restored) if restored and all(v is not None for v in restored) else None,
        "click_to_relaunch": click_to.get("will_relaunch"),
        "click_to_v1_exit": t.get("click_to_v1_exit_ms"),
        "prewarm_wait": (wait_end - wait_start) if wait_start is not None and wait_end is not None else 0,
        "prewarm_total": totals[-1] if totals else None,
        "v2_first_frame": since_v2("launch.first_window_frame_committed"),
        "v2_home_first_page": since_v2("launch.home.first_page"),
        "click_to_home": v2.get("launch.home.first_page"),
    }


KEYS = ("windows_hidden", "click_to_relaunch", "will_terminate", "click_to_v1_exit", "v2_process_start",
        "click_to_v2_frame", "click_to_restored", "prewarm_wait", "prewarm_total", "v2_first_frame",
        "v2_home_first_page", "click_to_home")


def p95(vals):
    """Nearest rank: with under 20 updates it is the slowest one."""
    ordered = sorted(vals)
    return ordered[max(0, -(-95 * len(ordered) // 100) - 1)]


def frames_verdict(run_dir):
    path = run_dir / "frames-verdict.json"
    if not path.exists():
        return None
    try:
        v = json.loads(path.read_text())
    except ValueError:
        return None
    w, c = v.get("windows") or {}, v.get("content") or {}
    return {"transition_frames": v.get("transition_frames"), "transition_states": w.get("transition_states"),
            "partial_alpha_samples": w.get("partial_alpha_samples"), "covered_samples": w.get("covered_samples"),
            "same_frame": w.get("same_frame"),
            "blank_gap_ms": w.get("blank_gap_ms"), "content_transition_frames": c.get("content_transition_frames"),
            "recorded": c.get("recorded")}


def main(out):
    medians = {}
    for side in ("base", "head"):
        rows = []
        for timeline in sorted(out.glob(f"run-{side}-*/timeline.json")):
            result = json.loads(timeline.read_text())
            row = {k: (None if v is None else round(v)) for k, v in metrics(result).items()}
            row["prewarm_log"] = result.get("prewarm_log") or []
            row["frames"] = frames_verdict(timeline.parent)
            print("UCA", side, timeline.parent.name.rsplit("-", 1)[-1], json.dumps(row), flush=True)
            rows.append(row)
        med = {"n": len(rows)}
        for key in KEYS:
            vals = [r[key] for r in rows if r[key] is not None]
            med[key] = round(statistics.median(vals)) if vals else None
            med[key + "_p95"] = round(p95(vals)) if vals else None
        judged = [r["frames"] for r in rows if r["frames"]]
        if judged:
            med["updates_with_transition_frames"] = sum(1 for f in judged if f["transition_frames"])
            med["updates_judged"] = len(judged)
        medians[side] = med
        print("UCA-MEDIAN", side, json.dumps(med), flush=True)
    (out / "medians.json").write_text(json.dumps(medians, indent=1))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
