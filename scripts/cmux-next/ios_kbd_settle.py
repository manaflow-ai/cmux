#!/usr/bin/env python3
"""ios_kbd_settle: the iOS keyboard content-settle table from KeyboardInjectBenchUITests' testSettle* traces.

Usage: python3 -I scripts/cmux-next/ios_kbd_settle.py TAG=DIR [TAG=DIR ...]
  DIR holds the exported kbm-trace-*.txt attachments of one run (an evidence zip's ui-*-attachments).

Per run, surface (chat, terminal) and direction (show, hide): from the keyboard's will-show/will-hide to its last
drawn frame, when the content behind the composer stops, and when it comes within 1 pt (and 0.1 pt) of its end, both
measured from the keyboard coming within 1 pt of its own end. Negative: the content got there before the keyboard did
(a snap at will-change, not a ride).

A surface whose content reading (`cb=`, `cf=`, `off=`) never changes in any slide while the keyboard moves is
refused, exit 2: that probe reads a view that does not draw the content (the terminal's scroll view, which keeps its
offset while Ghostty's rows move inside it, scored -320 ms that way). The trace's `csrc=` says what it read.
"""
import glob
import re
import sys

KB_MOVE = 50.0  # pt the keyboard must travel in a slide for its content's stillness to mean a dead probe
CONTENT_MOVE = 0.5


def kv(line):
    return dict(m.groups() for m in re.finditer(r"(\w+)=(\S+)", line))


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))] if v else None


def keyboard_top(s, screen=874.0):
    k = s.get("kb")
    return screen if k in (None, "-") else num(k)


def content(s):
    cf, cb, off = s.get("cf"), num(s.get("cb")), num(s.get("off"))
    if not cf or cb is None or off is None:
        return None
    a, b = cf.split(",")
    return (num(a), num(b), cb, off)


def last_move(win, key):
    last = None
    for a, b in zip(win, win[1:]):
        va, vb = key(a), key(b)
        if va is None or vb is None:
            continue
        if any(abs(p - q) > CONTENT_MOVE for p, q in zip(va, vb)):
            last = num(b["t"])
    return last


def settle(win, key, tol):
    vals = [(num(s["t"]), key(s)) for s in win]
    vals = [(t, v) for t, v in vals if v is not None]
    if not vals:
        return None
    fin, at = vals[-1][1], vals[0][0]
    for t, v in vals:
        if any(abs(p - q) > tol for p, q in zip(v, fin)):
            at = None
        elif at is None:
            at = t
    return at


def spread(win, key):
    vals = [v for v in (key(s) for s in win) if v is not None]
    if not vals:
        return 0.0
    return max(max(v[i] for v in vals) - min(v[i] for v in vals) for i in range(len(vals[0])))


def surface_of(samples):
    for x in samples:
        field = x.get("field", "")
        if field.startswith("chat"):
            return "chat"
        if field.startswith("terminal"):
            return "terminal"
    return None


def slides(lines):
    """(direction, window of samples) per will-show/will-hide with a duration."""
    samples = [x for x in lines if "ev" not in x and "t" in x and "win" in x]
    events = [x for x in lines if x.get("ev") in ("willShow", "willHide") and (num(x.get("dur")) or 0) > 0]
    starts = sorted(num(x["t"]) for x in lines if x.get("ev") in ("willShow", "willHide", "willChange"))
    for e in events:
        t0 = num(e["t"])
        end = min([t for t in starts if t > t0 + 0.01] + [t0 + 1.3])
        win = [s for s in samples if t0 - 0.001 <= num(s["t"]) < end]
        if len(win) >= 10:
            yield ("show" if e["ev"] == "willShow" else "hide"), t0, win


def table(runs):
    rows, motion = {}, {}
    for tag, directory in runs:
        for path in sorted(glob.glob(directory + "/*.txt")):
            with open(path, errors="replace") as fh:
                lines = [kv(line) for line in fh]
            surf = surface_of([x for x in lines if "ev" not in x and "t" in x and "win" in x])
            if not surf:
                continue
            for d, t0, win in slides(lines):
                key = (tag, surf, d)
                r = rows.setdefault(key, {"slide": [], "trail": [], "t1": [], "t0": [], "gap": [], "mtb": [], "src": set()})
                r["src"].update(s.get("csrc", "scroll") for s in win if s.get("cb"))
                if spread(win, lambda s: (keyboard_top(s),)) >= KB_MOVE:
                    m = motion.setdefault((tag, surf), [0, 0])
                    m[0] += 1
                    m[1] += spread(win, content) > CONTENT_MOVE
                kb_last = last_move(win, lambda s: (keyboard_top(s),))
                kb1, c1, c0 = settle(win, lambda s: (keyboard_top(s),), 1.0), settle(win, content, 1.0), settle(win, content, 0.1)
                if kb1 is not None and c1 is not None:
                    r["t1"].append((c1 - kb1) * 1000)
                    r["t0"].append(((c0 or c1) - kb1) * 1000)
                if kb_last is None:
                    continue
                c_last = last_move(win, content)
                ts = [num(s["t"]) for s in win if num(s["t"]) <= kb_last + 0.0001]
                r["slide"].append((kb_last - t0) * 1000)
                r["trail"].append(max(0.0, ((c_last or t0) - kb_last) * 1000))
                gaps = [(b - a) * 1000 for a, b in zip(ts, ts[1:])]
                if gaps:
                    r["gap"].append(max(gaps))
                busy = [num(s.get("mtb")) or 0 for s in win if num(s["t"]) <= kb_last + 0.0001]
                if busy:
                    r["mtb"].append(max(busy))
    dead = sorted(k for k, (moved, rode) in motion.items() if moved and not rode)
    return rows, dead


def render(rows, dead):
    out = ["| run | surface | dir | n | content read | will -> kb last frame p50/p95 ms | kb last frame -> content stops p50/p95 ms "
           "| kb within 1 pt -> content within 1 pt p50/p95 ms | kb within 1 pt -> content exact (0.1 pt) p50/p95 ms "
           "| longest frame in slide p50/p95 ms | max main busy/frame p50/p95 ms |",
           "|---|---|---|---|---|---|---|---|---|---|---|"]
    g = lambda v: "%.0f / %.0f" % (pct(v, .5), pct(v, .95)) if v else "-"
    for k in sorted(rows):
        r = rows[k]
        src = ",".join(sorted(r["src"])) or "-"
        if (k[0], k[1]) in dead:
            out.append("| %s | %s | %s | %d | %s | refused: the content never moved while the keyboard did (dead probe) | | | | | |"
                       % (k[0], k[1], k[2], len(r["slide"]), src))
            continue
        out.append("| %s | %s | %s | %d | %s | %s | %s | %s | %s | %s | %s |" % (
            k[0], k[1], k[2], len(r["slide"]), src, g(r["slide"]), g(r["trail"]), g(r["t1"]), g(r["t0"]), g(r["gap"]), g(r["mtb"])))
    return "\n".join(out)


def main(argv):
    runs = [a.split("=", 1) for a in argv]
    if not runs or any(len(r) != 2 for r in runs):
        print(__doc__.strip(), file=sys.stderr)
        return 64
    rows, dead = table(runs)
    print(render(rows, dead))
    for tag, surf in dead:
        print("refused %s %s: in every slide the keyboard moved %.0f+ pt and the content reading stayed within %.1f pt;"
              " the probe does not read what the surface draws" % (tag, surf, KB_MOVE, CONTENT_MOVE), file=sys.stderr)
    return 2 if dead else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
