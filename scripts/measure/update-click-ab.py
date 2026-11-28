"""Summarizes scripts/measure/update-click-ab.sh: one UCA line per update, then each side's medians (ms).

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
    return {
        "click_to_relaunch": click_to.get("will_relaunch"),
        "click_to_v1_exit": t.get("click_to_v1_exit_ms"),
        "prewarm_wait": (wait_end - wait_start) if wait_start is not None and wait_end is not None else 0,
        "prewarm_total": totals[-1] if totals else None,
        "v2_first_frame": since_v2("launch.first_window_frame_committed"),
        "v2_home_first_page": since_v2("launch.home.first_page"),
        "click_to_home": v2.get("launch.home.first_page"),
    }


def main(out):
    medians = {}
    for side in ("base", "head"):
        rows = []
        for timeline in sorted(out.glob(f"run-{side}-*/timeline.json")):
            result = json.loads(timeline.read_text())
            row = {k: (None if v is None else round(v)) for k, v in metrics(result).items()}
            row["prewarm_log"] = result.get("prewarm_log") or []
            print("UCA", side, timeline.parent.name.rsplit("-", 1)[-1], json.dumps(row), flush=True)
            rows.append(row)
        med = {"n": len(rows)}
        for key in ("click_to_relaunch", "click_to_v1_exit", "prewarm_wait", "prewarm_total", "v2_first_frame",
                    "v2_home_first_page", "click_to_home"):
            vals = [r[key] for r in rows if r[key] is not None]
            med[key] = round(statistics.median(vals)) if vals else None
        medians[side] = med
        print("UCA-MEDIAN", side, json.dumps(med), flush=True)
    (out / "medians.json").write_text(json.dumps(medians, indent=1))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
