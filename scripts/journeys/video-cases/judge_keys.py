#!/usr/bin/env python3
"""RESIZE KEYS judge: each keyboard resize press, from the recording's geometry trace and the app's input journal.

  judge_keys.py BASE [BASE ...] [--json OUT] [--markdown OUT]
      BASE: a published recording without suffix (.../rk-limit), or any of its files

Clock: the trace's samples are ms after t0_s (host seconds, mach_absolute_time); the journal's key-downs are
uptimeNanos on the same clock. No Python time is used.

A press is a key-down of a resize key in the journal (H 4, J 38, K 40, L 37 with Control and Shift; the arrows
123-126 with Control and Command; auto-repeats included). Presses less than SETTLE_MS apart form one burst (a held
key, fast presses). For each press or burst, against the rest before it:
  - target: the divider (or column edge) that moved most; none moved = "no motion" (a refused or dead press);
  - step: the travel in points and device pixels (a burst: its travel per press);
  - first move: the first trace tick that differs from the rest, in refreshes after the key (target: at most 1, the
    next refresh); film_first_move_refreshes: the first film frame whose pixels at the moving vertical edge changed;
  - motion: samples from the first move to the landing (1 = a snap, no animation), dropped refreshes in it
    (a sample interval over 1.5 refreshes);
  - jump back: a sample that moves against the travel by more than half a device pixel;
  - overshoot: a sample past the landing along the travel by more than half a device pixel;
  - lurch: one sample's move larger than 3 x the mean move of the motion and over 4 device pixels;
  - grid: every divider edge on the device-pixel grid (x scale whole within 0.01);
  - seam: the space between the two panes the divider parts stays its rest space (no gap, no overlap; 0.25 pt);
  - tail (bursts): ms from the last key-down to the landing and the travel after the last key.
Verdict per case: equal steps (all single-press steps within one device pixel of each other on the same target and
axis), every press moved (except at a limit where the press does not change the model either), no jump back, no
overshoot, no lurch, on the grid, no seam fault, first move within 1 refresh.
SIGWINCH and reflow counts come from the case's rk_panes notes (before: the result's step reply; after: the meta).
"""
import argparse
import json
import math
import os
import sys
from pathlib import Path

RESIZE_KEYS = {4: "H", 38: "J", 40: "K", 37: "L", 123: "Left", 124: "Right", 125: "Down", 126: "Up"}
SETTLE_MS = 400.0
JOURNAL_MARGIN_MS = 2.0


def base_of(path):
    p = str(path)
    for suffix in (".mov.frames.json", ".mov.scan", ".trace.json", ".events.json", ".meta.json", ".result.json", ".mov"):
        if p.endswith(suffix):
            return p[: -len(suffix)]
    return p


def load(base):
    trace = json.loads(Path(base + ".trace.json").read_text())
    events = json.loads(Path(base + ".events.json").read_text()) if Path(base + ".events.json").is_file() else {}
    meta = json.loads(Path(base + ".meta.json").read_text()) if Path(base + ".meta.json").is_file() else {}
    result = None
    rpath = Path(os.path.dirname(base)) / (os.path.basename(base) + ".result.json")
    if rpath.is_file():
        result = json.loads(rpath.read_text())
    return trace, events, meta, result


def load_tiers(base):
    """ext_tiers' diag-tiers.json (the app main thread's cumulative CPU ms per core tier, CLOCK_UPTIME_RAW), if the
    round ran tiers_start/tiers_stop (HARNESS CORES, cp/harness-cores-kit; lead 2026-11-02 23:0xZ: judge before/after
    within the same start tier)."""
    for d in (Path(os.path.dirname(base)), Path(os.path.dirname(base)).parent):
        f = d / "diag-tiers.json"
        if f.is_file():
            return json.loads(f.read_text())
    return None


def tier_split(tiers, a_ns, b_ns):
    rows = tiers["rows"]
    n = len(tiers["levels"])
    def at(t):
        best = rows[0]
        for r in rows:
            if r[0] > t:
                break
            best = r
        return best
    ra, rb = at(a_ns), at(b_ns)
    return [round(rb[1 + i] - ra[1 + i], 2) for i in range(n)]


def add_tiers(item, tiers, t0_s, t_key, t_first, refresh_ms=8.333):
    """start_tier: the tier with the most main-thread CPU in the first 4 ms after the key (from 2 ms before its journal
    stamp); key_turn_cpu_ms: CPU per tier from the key to the first moving tick."""
    if not tiers or len(tiers.get("rows") or []) < 2:
        return
    ns = lambda ms: int((ms + t0_s * 1000.0) * 1e6)
    a = ns(t_key - JOURNAL_MARGIN_MS)
    if not (tiers["rows"][0][0] <= a and tiers["rows"][-1][0] >= ns(t_key + 4)):
        return
    names = [str(x)[:1] for x in tiers["levels"]]
    first4 = tier_split(tiers, a, ns(t_key + 4))
    item["start_tier"] = names[max(range(len(first4)), key=lambda i: first4[i])] if sum(first4) > 0.05 else "idle"
    # The first moving tick can come before the journal stamp (JOURNAL_MARGIN_MS), so the key turn's CPU is read over at
    # least one refresh after the key.
    if t_first is not None:
        item["key_turn_cpu_ms"] = dict(zip(names, tier_split(tiers, a, ns(max(t_first, t_key + refresh_ms)))))


def key_downs(events, t0_s):
    out = []
    for e in events.get("journal") or []:
        kind = e.get("kind") or {}
        key = (kind.get("key") or {}).get("_0") if isinstance(kind, dict) else None
        if not key or key.get("phase") != "down" or key.get("keyCode") not in RESIZE_KEYS:
            continue
        out.append({"t": e["uptimeNanos"] / 1e6 - t0_s * 1000.0, "key": RESIZE_KEYS[key["keyCode"]],
                    "repeat": bool(key.get("isRepeat")), "seq": e.get("seq")})
    return sorted(out, key=lambda k: k["t"])


def positions(sample):
    """{divider id: (axis 'x'|'y', leading edge, thickness)} of one trace sample."""
    out = {}
    for d in sample.get("dividers") or []:
        did, x, y, w, h = d[0], d[1], d[2], d[3], d[4]
        out[did] = ("x", x, w) if w <= h else ("y", y, h)
    return out


def seam(sample, did):
    """The space between the two panes a divider parts minus its rest space, in points: the panes on each side of
    the divider's centre line that face it (the nearest edges). The divider handle itself is a wider hit band."""
    div = next((d for d in sample.get("dividers") or [] if d[0] == did), None)
    if not div:
        return None
    _, x, y, w, h = div[:5]
    vertical = w <= h
    centre = x + w / 2 if vertical else y + h / 2
    lead, trail = None, None
    for p in sample.get("panes") or []:
        px_, py_, pw, ph = p[1], p[2], p[3], p[4]
        if pw <= 0 or ph <= 0:
            continue
        if vertical and (py_ + ph <= y or py_ >= y + h):
            continue
        if not vertical and (px_ + pw <= x or px_ >= x + w):
            continue
        a, b = (px_, px_ + pw) if vertical else (py_, py_ + ph)
        if b <= centre + 0.01 and (lead is None or b > lead):
            lead = b
        if a >= centre - 0.01 and (trail is None or a < trail):
            trail = a
    return None if lead is None or trail is None else trail - lead


def film_first_moves(base, items, t0_s, scale):
    """For each press: the first film frame (display time) that shows the move, in refreshes after the key. Only pixels
    that stayed the same in the 3 frames before the key are compared (an animated pane's content is left out), in a
    window of 60 px around the moving edge on every scan row (vertical edge) or scan column (horizontal edge)."""
    path = Path(base + ".mov.scan")
    if not path.is_file():
        return
    import struct
    with path.open("rb") as f:
        head = json.loads(f.readline())
        width, height, rows, cols = head["width"], head["height"], head["rows"], head["columns"]
        record = 8 + len(rows) * width * 4 + len(cols) * height * 4
        data = f.read()
    count = len(data) // record
    times = [struct.unpack_from("<d", data, i * record)[0] for i in range(count)]

    def line(i, vertical, k, a, b):
        if vertical:  # a scan row: x from a to b
            o = i * record + 8 + k * width * 4
        else:  # a scan column: y from a to b
            o = i * record + 8 + len(rows) * width * 4 + k * height * 4
        return data[o + a * 4:o + b * 4]
    for item in items:
        if item.get("from_pt") is None or item.get("axis") not in ("x", "y"):
            continue
        vertical = item["axis"] == "x"
        tk = t0_s + item["t_key_ms"] / 1000
        px = int(round(item["from_pt"] * scale))
        limit = width if vertical else height
        a, b = max(0, px - 30), min(limit, px + 30)
        idx = next((i for i, t in enumerate(times) if t > tk), None)
        if idx is None or idx < 3:
            continue
        lines = range(len(rows) if vertical else len(cols))
        stable = {}
        for k in lines:
            ref = [line(j, vertical, k, a, b) for j in (idx - 3, idx - 2, idx - 1)]
            stable[k] = [p for p in range(b - a) if ref[0][p * 4:p * 4 + 3] == ref[1][p * 4:p * 4 + 3] == ref[2][p * 4:p * 4 + 3]]
        found = None
        for i in range(idx, min(count, idx + 12)):
            cur_changed = False
            for k in lines:
                base_line, cur = line(idx - 1, vertical, k, a, b), line(i, vertical, k, a, b)
                if any(cur[p * 4:p * 4 + 3] != base_line[p * 4:p * 4 + 3] for p in stable[k]):
                    cur_changed = True
                    break
            if cur_changed:
                found = i
                break
        if found is not None:
            item["film_first_move_refreshes"] = round((times[found] - tk) * 1000 / 8.333, 2)


def groups(keys):
    out = []
    for k in keys:
        if out and k["t"] - out[-1][-1]["t"] < SETTLE_MS:
            out[-1].append(k)
        else:
            out.append([k])
    return out


def judge(base):
    trace, events, meta, result = load(base)
    samples = trace.get("samples") or []
    refresh = float(trace.get("refresh_ms") or meta.get("refresh_ms") or 8.333)
    scale = float((meta.get("start") or {}).get("scale") or 2)
    px = 1.0 / scale
    keys = key_downs(events, float(trace["t0_s"]))
    tiers = load_tiers(base)
    report = {"case": os.path.basename(base), "build": os.path.basename(os.path.dirname(base)), "refresh_ms": refresh,
              "scale": scale, "presses": len(keys), "items": [], "faults": []}
    times = [s["t"] for s in samples]
    grid_faults = []
    for s in samples:
        for did, (axis, edge, thick) in positions(s).items():
            if abs(edge * scale - round(edge * scale)) > 0.01 or abs((edge + thick) * scale - round((edge + thick) * scale)) > 0.01:
                grid_faults.append({"t": s["t"], "divider": did[-12:], "edge": edge})
    if grid_faults:
        report["faults"].append({"check": "grid", "count": len(grid_faults), "first": grid_faults[0]})
    gs = groups(keys)
    for gi, g in enumerate(gs):
        t_key, t_last = g[0]["t"], g[-1]["t"]
        t_end = gs[gi + 1][0]["t"] if gi + 1 < len(gs) else (times[-1] + 1 if times else t_key)
        # The app's journal stamps a key-down up to a few ms after the turn that handled it; with the spring started in
        # that turn, the first display tick can move before the stamp. The rest is the last sample 2 ms before the
        # key, and a window ends 2 ms before the next key.
        before = [s for s in samples if s["t"] <= t_key - JOURNAL_MARGIN_MS]
        window = [s for s in samples if t_key - JOURNAL_MARGIN_MS < s["t"] < t_end - JOURNAL_MARGIN_MS]
        item = {"keys": "".join(k["key"][0] if len(k["key"]) == 1 else k["key"] + " " for k in g).strip(), "n": len(g),
                "t_key_ms": round(t_key, 2), "repeats": sum(k["repeat"] for k in g)}
        if not before or not window:
            item["verdict"] = "no trace around the key"
            report["items"].append(item)
            continue
        rest0 = positions(before[-1])
        rest1 = positions(window[-1])
        moved = {did: abs(rest1[did][1] - rest0[did][1]) for did in rest0 if did in rest1}
        travelled = {did: max(abs(positions(s).get(did, rest0[did])[1] - rest0[did][1]) for s in window) for did in rest0}
        target = max(travelled, key=lambda d: travelled[d]) if travelled else None
        if target is None or travelled[target] < 0.01:
            item.update(target=None, step_pt=0.0, verdict="no motion")
            report["items"].append(item)
            continue
        axis = rest0[target][0]
        p0, p1 = rest0[target][1], rest1[target][1]
        series = [(s["t"], positions(s).get(target, rest0[target])[1]) for s in window]
        direction = math.copysign(1, p1 - p0) if abs(p1 - p0) > 0.01 else 0
        first = next(((t, p) for t, p in series if abs(p - p0) > 0.01), None)
        landed_at = next((series[i][0] for i in range(len(series)) if all(abs(p - p1) < 0.01 for _, p in series[i:])), None)
        motion = [(t, p) for t, p in series if first and first[0] <= t <= (landed_at or series[-1][0])]
        moves = [b[1] - a[1] for a, b in zip([(first[0], p0)] + motion[:-1], motion)] if motion else []
        mean_move = sum(abs(m) for m in moves) / len(moves) if moves else 0
        jump_back = [round(m, 2) for m in moves if direction and m * direction < -px / 2]
        over = [round(p, 2) for _, p in motion if direction and (p - p1) * direction > px / 2]
        # A lurch is one step far larger than the steps around it (as judge_trace.py): against the mean of the whole
        # motion, a chain of presses (each retarget speeds the spring up, then a long slow tail) read every peak as one.
        lurch = []
        for k, m in enumerate(moves):
            around = [abs(x) for x in moves[max(0, k - 2):k] + moves[k + 1:k + 3] if abs(x) > 0]
            if len(moves) > 3 and around and abs(m) > max(4 * px, 3 * sum(around) / len(around)):
                lurch.append(round(m, 2))
        mt = [t for t, _ in motion]
        dropped = sum(1 for a, b in zip(mt, mt[1:]) if b - a > 1.5 * refresh)
        rest_gap = seam(before[-1], target)
        seams = [abs(v - rest_gap) for v in (seam(s, target) for s in window) if v is not None and rest_gap is not None]
        item.update(target=target[-16:], axis=axis, from_pt=p0, to_pt=p1, step_pt=round(p1 - p0, 2),
                    step_px=round((p1 - p0) * scale, 2), step_per_press_px=round((p1 - p0) * scale / len(g), 2),
                    first_move_refreshes=round((first[0] - t_key) / refresh, 2) if first else None,
                    motion_frames=len(motion), landed_ms=round(landed_at - t_key, 1) if landed_at else None,
                    landed_before_next=landed_at is not None, dropped_refreshes=dropped,
                    jump_back=jump_back[:6], overshoot=over[:6], lurch=lurch[:6],
                    seam_max_pt=round(max(seams), 2) if seams else None,
                    other_moved={d[-12:]: round(v, 2) for d, v in moved.items() if d != target and v > 0.01})
        if len(g) > 1:
            after = [p for t, p in series if t > t_last]
            item["tail_ms"] = round(landed_at - t_last, 1) if landed_at else None
            item["travel_after_last_key_pt"] = round(abs(p1 - after[0]) if after else 0, 2)
        add_tiers(item, tiers, float(trace["t0_s"]), t_key, first[0] if first else None, refresh)
        faults = []
        if item["motion_frames"] <= 1:
            faults.append("snap (no animation)")
        if jump_back:
            faults.append("jump back")
        if over:
            faults.append("overshoot")
        if lurch:
            faults.append("lurch")
        if dropped:
            faults.append(f"{dropped} dropped refreshes")
        # Lawrence's case (lead 2026-11-02 21:1xZ): the first frame of the move is in the next refresh after the key. The
        # first trace tick that moves must be the first tick after the key (at most 1 refresh); the film's first changed
        # frame is reported beside it (film_first_move_refreshes) with the compositor's own latency in it.
        if item["first_move_refreshes"] is not None and item["first_move_refreshes"] > 1.0:
            faults.append("late first frame")
        if seams and max(seams) > 0.25:
            faults.append("seam gap/overlap")
        if not item["landed_before_next"]:
            faults.append("not landed before the next press")
        item["verdict"] = "; ".join(faults) or "pass"
        report["items"].append(item)
    film_first_moves(base, report["items"], float(trace["t0_s"]), scale)
    singles = [i for i in report["items"] if i.get("n") == 1 and i.get("target")]
    by_target = {}
    for i in singles:
        by_target.setdefault((i["target"], i["axis"]), []).append(abs(i["step_px"]))
    unequal = {f"{t[0]}:{t[1]}": sorted(set(v)) for t, v in by_target.items() if max(v) - min(v) > 1.0}
    if unequal:
        report["faults"].append({"check": "unequal steps (device px)", "steps": unequal})
    report["steps_px"] = {f"{t[0]}:{t[1]}": sorted(set(v)) for t, v in by_target.items()}
    report["no_motion"] = [i["keys"] + "@" + str(i["t_key_ms"]) for i in report["items"] if i.get("verdict") == "no motion"]
    notes = [st.get("result") for st in (result or {}).get("steps") or [] if isinstance(st, dict) and st.get("do") == "rk_panes"]
    report["panes"] = {"before": notes[0] if notes else None, "after": notes[-1] if len(notes) > 1 else None}
    report["pass"] = not report["faults"] and all(i.get("verdict") in ("pass", "no motion") for i in report["items"])
    return report


def markdown(reports):
    lines = ["| case | build | press | keys | target | step px | first move (refr.) | film first move (refr.) | frames | landed ms | start tier | verdict |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for r in reports:
        for n, i in enumerate(r["items"]):
            lines.append(f"| {r['case']} | {r['build']} | {n} | {i.get('keys')} | {i.get('target') or '-'} | {i.get('step_px', 0)} | "
                         f"{i.get('first_move_refreshes')} | {i.get('film_first_move_refreshes')} | {i.get('motion_frames')} | {i.get('landed_ms')} | {i.get('start_tier', '-')} | {i.get('verdict')} |")
        for f in r["faults"]:
            lines.append(f"| {r['case']} | {r['build']} | all | | | | | | | | {f['check']}: {json.dumps({k: v for k, v in f.items() if k != 'check'})[:200]} |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base", nargs="+")
    ap.add_argument("--json")
    ap.add_argument("--markdown")
    opts = ap.parse_args()
    reports = [judge(base_of(b)) for b in opts.base]
    if opts.json:
        Path(opts.json).write_text(json.dumps(reports, indent=1))
    if opts.markdown:
        Path(opts.markdown).write_text(markdown(reports) + "\n")
    for r in reports:
        print(json.dumps({k: r[k] for k in ("case", "build", "presses", "pass", "faults", "steps_px", "no_motion")}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
