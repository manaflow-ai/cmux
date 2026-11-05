#!/usr/bin/env python3
"""cmux-ad m14 film verdict (Lead 2026-11-05, Lawrence P0): in every frame of a key resize and a divider drag, every
terminal and every page shows live pixels rendered at that frame's pane size: each content edge within 1 device px of its
pane edge as cmux's own layer shows it, never frozen, never stretched or squeezed, never the old frame anchored.

  judge_m14.py BASE [BASE ...] [--json OUT.json]
      BASE: a fixture film without suffix (.../px-keys-held-2-sw-terminals-on-s1), or any of its files

It runs judge_pixel.py (this folder; same interpreter, which needs numpy: the VM venv) and reads its `m14` rows: the
edges of the m6 check, with m6's allowances failed in their own classes (allowed: m6 late; page_late: m6 page late 1).
Per film, per kind (terminal, page, agent): judged frames, failing frames by class (scaled, gap, edge, allowed,
page_late), the worst edge offset in device px (its frame and edge), scaled frames, frames not judged, touching edges
not judged (3e.3), and late as a whole (the window presented a whole old frame: information, not a content class).

Verdict per film: fail when a kind has a failing frame; not judged when no kind has a judged frame (never a pass); else
pass. The status word names the frames not judged and the touching edges not judged, so a pass is read with them; late
as a whole is on every line. Exit 0 when every film passes, 1 when a film fails, 2 when a film is not judged and none fails.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

SUFFIXES = (".mov.frames.json", ".mov.scan", ".trace.json", ".events.json", ".meta.json", ".result.json", ".mov")


def base_of(path: str) -> str:
    for suffix in SUFFIXES:
        if path.endswith(suffix):
            return path[: -len(suffix)]
    return path


def film_verdict(report: dict) -> dict:
    m14 = report.get("m14") or {}
    kinds = {k: v for k, v in (m14.get("kinds") or {}).items()}
    judged = {k: v for k, v in kinds.items() if v.get("judged", 0) > 0}
    status = "not judged" if not judged else ("fail" if any(v["fail"] for v in judged.values()) else "pass")
    unjudged = sum(v.get("not_judged", 0) for v in kinds.values())
    touching = sum(v.get("touch_not_judged", 0) for v in kinds.values())
    return {"base": report.get("base"), "status": status, "not_judged_frames": unjudged, "touch_not_judged_edges": touching,
            "kinds": kinds,
            "late_as_a_whole": m14.get("late_as_a_whole"), "late_as_a_whole_ranges": m14.get("late_as_a_whole_ranges"),
            "notes": report.get("notes") or []}


def line_of(film: dict, classes) -> str:
    name = Path(film["base"] or "?").name
    if film["status"] == "not judged" and not film["kinds"]:
        return f"{name}: m14 NOT JUDGED ({'; '.join(film['notes'])[:200] or 'no kind judged'})"
    parts = []
    for kind, v in film["kinds"].items():
        by = ", ".join(f"{c} {v[c]}" for c in classes if v[c])
        parts.append(f"{kind}: {v['fail']} of {v['judged']} judged frames fail" + (f" ({by}; frames {v['fail_ranges']})" if v["fail"] else "")
                     + f", worst {v['worst_px']:g} px" + (f" (frame {v['worst_frame']}, {v['worst_edge']})" if v["worst_frame"] is not None else "")
                     + f", scaled {v['scaled']}, not judged {v['not_judged']} (+{v['touch_not_judged']} touching edges)")
    # The status word carries what was not judged (R-HARNESS review of 7cfd91442ece): a pass reads with it.
    word = film["status"].upper() + (f", {film['not_judged_frames']} frames not judged" if film["not_judged_frames"] else "") \
        + (f", {film['touch_not_judged_edges']} touching edges not judged" if film["touch_not_judged_edges"] else "")
    return f"{name}: m14 {word} | " + " | ".join(parts) + f" | late as a whole {film['late_as_a_whole']} (the window showed a whole old frame)"


def main(argv: list[str] | None = None) -> int:
    import judge_pixel as jp
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("bases", nargs="+")
    ap.add_argument("--json")
    opts = ap.parse_args(argv)
    films = []
    for base in dict.fromkeys(base_of(b) for b in opts.bases):
        report = jp.judge(base)
        report.setdefault("base", base)
        films.append(film_verdict(report))
        print(line_of(films[-1], jp.M14_FAIL_CLASSES), flush=True)
    statuses = {f["status"] for f in films}
    status = "fail" if "fail" in statuses else "not judged" if "not judged" in statuses else "pass"
    print(f"m14: {status} ({sum(f['status'] == 'pass' for f in films)} of {len(films)} films pass)")
    if opts.json:
        Path(opts.json).write_text(json.dumps({"status": status, "judge": str(HERE / "judge_pixel.py"), "films": films},
                                              indent=1, default=str) + "\n")
    return {"pass": 0, "fail": 1, "not judged": 2}[status]


if __name__ == "__main__":
    sys.exit(main())
