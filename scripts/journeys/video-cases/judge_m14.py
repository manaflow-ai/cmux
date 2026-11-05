#!/usr/bin/env python3
"""cmux-ad m18 film verdict (Lead 2026-11-05, STATUS 13889; m14 with --contract m14): in every frame of a key resize and a
divider drag, every terminal shows its text re-wrapped at that frame's pane size, drawn at the pane's pixel size, and every
page stays inside its pane and shows a frame at most 2 refreshes old.

  judge_m14.py BASE [BASE ...] [--contract m18|m14] [--no-stale] [--json OUT.json]
      BASE: a fixture film without suffix (.../px-keys-held-2-sw-terminals-on-s1), or any of its files

It runs judge_pixel.py (this folder; same interpreter, which needs numpy: the VM venv) and reads its `m18` (or `m14`) rows.
m18 per kind (terminal, page, agent), a frame fails as:
  held, stale  a terminal: the committed surface not its pane's area (> 0.5 pt), or the shown IOSurface not the surface's
               size x scale (> 1 px), from the film's trace (`terminal` rows); --no-stale: stale not judged (a build whose
               IOSurface is a render-target capacity, ghostty-next #81 plan B)
  scaled       stretched or squeezed content
  protrude     a page past its pane edge, in any frame
  gap, edge, allowed
               a terminal: shell beyond its content; an edge off its pane edge (a grid its view cuts too, while its pane
               grows: no grid once per gesture); m6's late (the previous size, anchored)
  lag          a page on a frame older than 2 refreshes (on the frame of 1 or 2 refreshes before it passes: lag_1_2)
m14 (--contract m14): held, stale, scaled, gap, edge, allowed (m6 late), page_late (m6 page late 1).
Per film, per kind: judged frames, failing frames by class, the worst edge offset in device px (its frame and edge), frames
not judged, touching edges not judged (3e.3), late as a whole (the window presented a whole old frame: information), and
the missed refreshes of the film's debug.frames read (`<film>.frames.json` beside the film or in its journey folder: the
reply's `missed`, intervals over 1.5 refreshes, and the refreshes those intervals skipped; target 0; information).

Verdict per film: fail when a kind has a failing frame; not judged when no kind has a judged frame (never a pass); else
pass. The status word names the frames not judged, the touching edges not judged and "stale not judged", so a pass is read
with them. Exit 0 when every film passes, 1 when a film fails, 2 when a film is not judged and none fails.
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


def smooth_of(base: str) -> dict:
    """The film's debug.frames read (the kit keeps `debug.frames stop raw` as `<film>.frames.json` in the journey folder,
    the film in its `video` folder; or beside the film): missed (intervals over 1.5 refreshes), refreshes_skipped (the
    refreshes those intervals skipped), frames, refresh_ms, the file. {"read": False} when there is none."""
    path = Path(base)
    candidates = [Path(f"{path}.frames.json")]
    if path.parent.name == "video":
        candidates.append(path.parent.parent / f"{path.name}.frames.json")
    for c in candidates:
        if not c.is_file():
            continue
        try:
            doc = json.loads(c.read_text())
        except (OSError, ValueError) as error:
            return {"read": False, "file": str(c), "error": str(error)}
        reply = doc.get("reply", doc) if isinstance(doc, dict) else {}
        refresh = float(reply.get("refresh_ms") or 0.0)
        intervals = [float(i) for i in reply.get("intervals_ms") or []]
        skipped = sum(max(0, round(i / refresh) - 1) for i in intervals) if refresh > 0 and intervals else None
        return {"read": True, "file": str(c), "missed": reply.get("missed"), "refreshes_skipped": skipped,
                "frames": reply.get("frames"), "refresh_ms": round(refresh, 3) if refresh else None}
    return {"read": False}


def smooth_line(smooth: dict) -> str:
    if not smooth.get("read"):
        return "smooth: no debug.frames read" + (f" ({smooth['error'][:80]})" if smooth.get("error") else "")
    skipped = f", {smooth['refreshes_skipped']} refreshes skipped" if smooth.get("refreshes_skipped") is not None else ""
    return (f"smooth: {smooth['missed']} missed refreshes{skipped} of {smooth['frames']} frames at {smooth['refresh_ms']} ms "
            f"(target 0; {Path(smooth['file']).name})")


def film_verdict(report: dict, contract: str = "m18") -> dict:
    rows = report.get(contract) or {}
    kinds = {k: v for k, v in (rows.get("kinds") or {}).items()}
    judged = {k: v for k, v in kinds.items() if v.get("judged", 0) > 0}
    status = "not judged" if not judged else ("fail" if any(v["fail"] for v in judged.values()) else "pass")
    unjudged = sum(v.get("not_judged", 0) for v in kinds.values())
    touching = sum(v.get("touch_not_judged", 0) for v in kinds.values())
    stale_judged = all(v.get("stale_judged", True) for v in kinds.values())
    return {"base": report.get("base"), "contract": contract, "status": status, "not_judged_frames": unjudged,
            "touch_not_judged_edges": touching, "stale_judged": stale_judged, "kinds": kinds,
            "late_as_a_whole": rows.get("late_as_a_whole"), "late_as_a_whole_ranges": rows.get("late_as_a_whole_ranges"),
            "notes": report.get("notes") or []}


def line_of(film: dict, classes) -> str:
    name = Path(film["base"] or "?").name
    contract = film.get("contract", "m14")
    if film["status"] == "not judged" and not film["kinds"]:
        return f"{name}: {contract} NOT JUDGED ({'; '.join(film['notes'])[:200] or 'no kind judged'})" + \
            (f" | {smooth_line(film['smooth'])}" if "smooth" in film else "")
    parts = []
    for kind, v in film["kinds"].items():
        by = ", ".join(f"{c} {v[c]}" for c in classes if v.get(c))
        extra = ""
        if v.get("lag_1_2"):
            extra += f", lag 1-2 refreshes {v['lag_1_2']} (pass)"
        if v.get("surface_frames"):
            extra += f", surface {v['surface_frames']} frames (held worst {v['held_worst_pt']:g} pt" + \
                (f", stale worst {v['stale_worst_px']:g} px" if v.get("stale_judged", True) else ", stale not judged") + ")"
        parts.append(f"{kind}: {v['fail']} of {v['judged']} judged frames fail" + (f" ({by}; frames {v['fail_ranges']})" if v["fail"] else "")
                     + f", worst {v['worst_px']:g} px" + (f" (frame {v['worst_frame']}, {v['worst_edge']})" if v["worst_frame"] is not None else "")
                     + f", scaled {v['scaled']}, not judged {v['not_judged']} (+{v['touch_not_judged']} touching edges)" + extra)
    # The status word carries what was not judged (R-HARNESS review of 7cfd91442ece): a pass reads with it.
    word = film["status"].upper() + (f", {film['not_judged_frames']} frames not judged" if film["not_judged_frames"] else "") \
        + (f", {film['touch_not_judged_edges']} touching edges not judged" if film["touch_not_judged_edges"] else "") \
        + ("" if film.get("stale_judged", True) else ", stale not judged")
    line = f"{name}: {contract} {word} | " + " | ".join(parts) + f" | late as a whole {film['late_as_a_whole']} (the window showed a whole old frame)"
    return line + (f" | {smooth_line(film['smooth'])}" if "smooth" in film else "")


def main(argv: list[str] | None = None) -> int:
    import judge_pixel as jp
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("bases", nargs="+")
    ap.add_argument("--contract", choices=("m18", "m14"), default="m18")
    ap.add_argument("--no-stale", action="store_true", help="do not judge stale (a render-target capacity build)")
    ap.add_argument("--json")
    opts = ap.parse_args(argv)
    classes = jp.M18_FAIL_CLASSES if opts.contract == "m18" else jp.M14_FAIL_CLASSES
    films = []
    for base in dict.fromkeys(base_of(b) for b in opts.bases):
        report = jp.judge(base, stale=not opts.no_stale)
        report.setdefault("base", base)
        films.append(dict(film_verdict(report, opts.contract), smooth=smooth_of(base)))
        print(line_of(films[-1], classes), flush=True)
    statuses = {f["status"] for f in films}
    status = "fail" if "fail" in statuses else "not judged" if "not judged" in statuses else "pass"
    print(f"{opts.contract}: {status} ({sum(f['status'] == 'pass' for f in films)} of {len(films)} films pass)")
    if opts.json:
        Path(opts.json).write_text(json.dumps({"status": status, "contract": opts.contract, "stale_judged": not opts.no_stale,
                                               "judge": str(HERE / "judge_pixel.py"), "films": films},
                                              indent=1, default=str) + "\n")
    return {"pass": 0, "fail": 1, "not judged": 2}[status]


if __name__ == "__main__":
    sys.exit(main())
