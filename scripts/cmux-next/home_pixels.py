"""Pixel reads of Swift Home window snapshots (stdlib only), for the tagged-app checks
home-typing-still.py, home-hidden-messages.py and home-scale-change.py.

read_png decodes a window snapshot. row_edges reads the straight edges of the message rows
that `debug.home.drive {action: rows}` reports (window points, bottom-left origin) and counts
partial pixels: on a straight edge that lies on whole device pixels, the last pixel outside the
bubble is the background and the first pixel inside is the fill; an edge that lies on a
fraction of a device pixel blends one pixel row (or column) of the two along its whole length.
"""
import struct, zlib

# The proofs not run (check_rows on a window that is not 2x), for the caller's summary.
SKIPPED = []


def read_png(path):
    """8-bit RGB or RGBA, non-interlaced PNG (window snapshots): (width, height, (rows of bytes, 3 or 4 per pixel))."""
    data = open(path, "rb").read()
    pos, idat, w, h, bpp = 8, b"", 0, 0, 3
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or interlace:
                raise ValueError(f"unsupported PNG depth {depth} colour type {ctype} interlace {interlace}")
            bpp = 4 if ctype == 6 else 3
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    return w, h, (rows, bpp)


def mean_rgb(px, w, h, x0, y0, x1, y1):
    rows, bpp = px
    xs = range(max(0, int(x0)), min(w, int(x1))); ys = range(max(0, int(y0)), min(h, int(y1)))
    n = max(1, len(xs) * len(ys)); sums = [0, 0, 0]
    for y in ys:
        r = rows[y]
        for x in xs:
            for k in range(3): sums[k] += r[x * bpp + k]
    return [round(v / n, 1) for v in sums]


def _pixel(px, w, h, x, y):
    rows, bpp = px
    if not (0 <= x < w and 0 <= y < h):
        return None
    return rows[y][x * bpp:x * bpp + 3]


def _dist(a, b):
    return sum(abs(a[k] - b[k]) for k in range(3)) / 3


def _edge(px, w, h, samples, contrast_min=24):
    """samples: per line across the edge, the pixel places (outside far, last outside, first inside, inside far).
    A crisp edge: the last outside pixel is the far outside colour and the first inside pixel the far inside
    colour (within a quarter of their contrast). Returns (measured, partial)."""
    measured = partial = 0
    for far_out, last_out, first_in, far_in in samples:
        o, lo, fi, i = (_pixel(px, w, h, *p) for p in (far_out, last_out, first_in, far_in))
        if None in (o, lo, fi, i):
            continue
        contrast = _dist(o, i)
        if contrast < contrast_min:
            continue
        measured += 1
        tol = max(6, contrast * 0.25)
        if _dist(lo, o) > tol or _dist(fi, i) > tol:
            partial += 1
    return measured, partial


def flat_span(a, b, height_pt, scale):
    """The flat part of a balloon's top or bottom edge between device px a and b: the middle 40 %, and never within
    a corner's reach of either end (22.9 pt for a continuous corner, or half the height: a 1-line text ends in half
    circles, MessagesLab 267d218 RowDraw.circularEnds; the curves have partial pixels by design). Empty when no flat part is left."""
    # A 1-line text ends in half circles (half the height); a taller balloon's continuous corner reaches
    # 1.528665 x 15 = 22.9 pt along its side (UIKit's continuous corner; MessagesLab Shapes.swift).
    reach = ((height_pt / 2 if height_pt < 2 * 15 * 1.528665 else 15 * 1.528665) + 1) * scale
    lo, hi = max(a + (b - a) * 0.3, a + reach), min(a + (b - a) * 0.7, b - reach)
    return range(int(lo), int(hi)) if hi > lo else range(0)


def row_edges(px, w, h, scale, frame, window_height):
    """The straight edges of one row's bubble (frame: window points, bottom-left origin): top and bottom
    over the middle 40 % of its width; left and right over the middle 40 % of its height when the bubble is
    at least 60 pt tall (shorter bubbles have no straight side between their corners). Returns
    {edge: (device px place, measured lines, partial lines)}. The far outside sample is 3 device px out at 2x
    and 2 at 1x (grouped bubbles are 3 pt apart: at 1x, 3 px out is the next bubble's edge)."""
    x0 = frame["x"] * scale; x1 = (frame["x"] + frame["width"]) * scale
    top = (window_height - frame["y"] - frame["height"]) * scale; bottom = (window_height - frame["y"]) * scale
    out = {}
    T, B, L, R = round(top), round(bottom), round(x0), round(x1)
    f = 3 if scale >= 2 else 2
    xs = flat_span(x0, x1, frame["height"], scale)
    out["top"] = (top,) + _edge(px, w, h, [((x, T - f), (x, T - 1), (x, T), (x, T + 2)) for x in xs])
    out["bottom"] = (bottom,) + _edge(px, w, h, [((x, B + f - 1), (x, B), (x, B - 1), (x, B - 3)) for x in xs])
    if frame["height"] >= 60:
        ys = range(int(top + (bottom - top) * 0.3), int(top + (bottom - top) * 0.7))
        out["left"] = (x0,) + _edge(px, w, h, [((L - f, y), (L - 1, y), (L, y), (L + 2, y)) for y in ys])
        out["right"] = (x1,) + _edge(px, w, h, [((R + f - 1, y), (R, y), (R - 1, y), (R - 3, y)) for y in ys])
    return out


def check_crisp(check, name, report, path, min_rows=1):
    """At any backing scale (home-scale-change.py: 1x and 2x): the snapshot's incoming text balloons have crisp
    straight edges (top, bottom, a tall row's left: at most 10 % partial lines, 8 lines measured or more each, at
    least `min_rows` rows with a measured edge). A bitmap drawn at another scale, or a row off the device pixel
    grid, blends a pixel line along the whole edge. Outgoing text balloons are soft by design (MessagesLab 3ded59a)
    and are not read here. Returns the scale of the snapshot."""
    w, h, px = read_png(path)
    scale = w / report["windowWidth"]; wh = report["windowHeight"]
    rows = [r for r in report["rows"] if r["kind"] == "text" and not r["outgoing"]
            and r["y"] >= 64 and r["y"] + r["height"] <= wh - 90]
    bad, measured_rows = [], 0
    for r in rows:
        line, any_measured = [], False
        for edge, (place, measured, partial) in row_edges(px, w, h, scale, r, wh).items():
            if edge == "right":
                continue
            line.append(f"{edge} {place:.2f}px partial {partial}/{measured}")
            if measured >= 8:
                any_measured = True
                if partial > measured * 0.1:
                    bad.append({r["key"]: edge, "partial": partial, "measured": measured, "place": round(place, 3)})
        measured_rows += any_measured
        print(f"     {name} {r['key']} (in, {scale:g}x): " + ", ".join(line), flush=True)
    check(f"{name}: at least {min_rows} incoming text rows with a measured straight edge at {scale:g}x",
          measured_rows >= min_rows, {"rows": len(rows), "measured": measured_rows})
    check(f"{name}: no straight edge of an incoming balloon has partial pixels at {scale:g}x (at most 10 % of its lines)",
          not bad, bad)
    return scale


def _coverage(p, o, i):
    """How much of pixel p is the inside colour i (0: the outside colour o, 1: i), least squares over RGB."""
    den = sum((i[k] - o[k]) ** 2 for k in range(3))
    if den <= 0:
        return None
    return min(1.0, max(0.0, sum((p[k] - o[k]) * (i[k] - o[k]) for k in range(3)) / den))


def edge_position(px, w, h, edge, near, span, contrast_min=24, min_lines=8):
    """The measured place (device px) of a straight edge near the whole pixel `near`, from the summed coverage
    of the 4 pixel lines around it (the far outside and far inside colours 4 and 3 lines away), the mean over the
    lines across `span` whose contrast is at least `contrast_min`. edge: top or left (inside after the edge) or
    bottom or right (inside before it). None when fewer than 8 lines have contrast."""
    first = edge in ("top", "left")
    places = []
    for t in span:
        def at(k):
            return _pixel(px, w, h, t, k) if edge in ("top", "bottom") else _pixel(px, w, h, k, t)
        o, i = (at(near - 4), at(near + 3)) if first else (at(near + 3), at(near - 4))
        if o is None or i is None or _dist(o, i) < contrast_min:
            continue
        covs = [at(k) for k in range(near - 2, near + 2)]
        if None in covs:
            continue
        c = [_coverage(q, o, i) for q in covs]
        if None in c:
            continue
        places.append(near + 2 - sum(c) if first else near - 2 + sum(c))
    return (sum(places) / len(places), len(places)) if len(places) >= min_lines else (None, len(places))


def check_rows(check, name, report, path, keys=None, min_rows=3):
    """check(name, ok, detail): the caller's check. Text rows fully inside the transcript area (not under the
    title bar or the composer):
    - the row's frame (its snapped content) has its anchored side (incoming left, outgoing right; the other side
      is the text's width) and its top on whole device pixels;
    - the drawn balloon's edges are where the app draws them (`balloon`: RowDraw.balloon; an incoming balloon is
      its frame, an outgoing text balloon is a little inside it on macOS 27, MessagesLab 2281879), measured from
      the snapshot's coverage within 0.12 device px and nearer the balloon than the frame (half their distance):
      top, bottom and the anchored side (a tall incoming row's left; every outgoing row's right, a 1-line
      pill at its vertical centre); every one of them must be measured; the tolerance has a 0.015 px floor;
    - on a window whose backing scale is not 2, nothing is checked: a SKIP line, and `name` in SKIPPED;
    - an incoming balloon's straight edges have no partial pixels (at most 10 % of their lines). An outgoing text
      balloon's edges are soft on macOS 27 (MessagesLab 3ded59a SoftBalloon: two partly covered device px, as
      Messages): only their measured place (the summed coverage, which the soft edge keeps) is checked.
    `keys`: only these rows."""
    w, h, px = read_png(path)
    scale = w / report["windowWidth"]; wh = report["windowHeight"]
    if abs(scale - 2) > 0.01:
        # The sample places (4 device px around an edge, 3 pt between grouped bubbles) and the half-pixel move
        # assume a 2x backing store: on another scale the proof is not run, and says so.
        print(f"SKIP {name}: the row proof needs a 2x display (this window's backing scale is {scale:.2f})", flush=True)
        SKIPPED.append(name)
        return []
    rows = [r for r in report["rows"] if r["kind"] == "text" and (keys is None or r["key"] in keys)
            and r["y"] >= 64 and r["y"] + r["height"] <= wh - 90]
    check(f"{name}: at least {min_rows} text rows to measure", len(rows) >= min_rows, report["rows"][:12])
    bad_place, bad_edges, off_edges, unmeasured, checked = [], [], [], [], 0
    for r in rows:
        side = (r["x"] + r["width"] if r["outgoing"] else r["x"]) * scale
        top = (wh - r["y"] - r["height"]) * scale
        if abs(side - round(side)) > 0.01 or abs(top - round(top)) > 0.01:
            bad_place.append({r["key"]: [round(side, 3), round(top, 3)]})
        b = r.get("balloon") or r
        bl, br = b["x"] * scale, (b["x"] + b["width"]) * scale
        bt, bb = (wh - b["y"] - b["height"]) * scale, (wh - b["y"]) * scale
        flat = flat_span(bl, br, b["height"], scale)
        y0, y1 = bt + (bb - bt) * 0.3, bt + (bb - bt) * 0.7
        # The frame's edges: where an edge would be if the balloon were drawn on its frame.
        ft, fb = top, (wh - r["y"]) * scale
        fl, fr = r["x"] * scale, (r["x"] + r["width"]) * scale
        # A balloon too short for a flat top and bottom (its ends meet): only its anchored side and place are checked.
        expected = {"top": (bt, ft, flat, 8), "bottom": (bb, fb, flat, 8)} if len(flat) >= 8 else {}
        if not expected:
            print(f"     {name} {r['key']}: no flat top or bottom (balloon {b['width']:.1f} pt wide)", flush=True)
        if r["height"] >= 60:
            expected["right" if r["outgoing"] else "left"] = ((br, fr) if r["outgoing"] else (bl, fl)) + (range(int(y0), int(y1)), 8)
        elif r["outgoing"]:
            # My row's anchored side (MessagesLab 82ccac1: my rows snap their right edge). A 1-line balloon is a pill:
            # its side is straight only at the vertical centre; the 3 pixel lines there (the curve leaves the
            # tangent by about 0.04 px within 1.5 px of it at a 15 pt radius, 2x; the 1-line right inset is 0.21 px,
            # so the tolerance there is 0.106 px).
            c = (bt + bb) / 2
            expected["right"] = (br, fr, range(int(c - 1), int(c + 2)), 3)
        line = []
        for edge, (want, frame_at, span, need) in expected.items():
            checked += 1
            got, n = edge_position(px, w, h, edge, round(want), span, min_lines=need)
            if got is None:
                unmeasured.append({r["key"]: edge, "lines": n})
            # Within 0.12 px, and nearer the balloon than its frame where the two differ (the outgoing top inset
            # is 0.05-0.08 px: a balloon drawn on its frame fails).
            gap = abs(want - frame_at)
            # A floor of 0.015 px (the coverage measurement's own noise) where balloon and frame nearly coincide.
            tol = max(0.015, min(0.12, gap / 2)) if gap > 0.001 else 0.12
            line.append(f"{edge} {want:.2f}/{'-' if got is None else f'{got:.2f}'}px (frame {frame_at:.2f}, tol {tol:.3f})")
            if got is not None and abs(got - want) > tol:
                off_edges.append({r["key"]: edge, "drawn": round(want, 3), "frame": round(frame_at, 3), "measured": round(got, 3),
                                  "tolerance": round(tol, 3)})
        if not r["outgoing"]:
            for edge, (place, measured, partial) in row_edges(px, w, h, scale, r, wh).items():
                if edge == "right":
                    continue
                line.append(f"{edge} partial {partial}/{measured}")
                if measured >= 8 and partial > measured * 0.1:
                    bad_edges.append({r["key"]: edge, "partial": partial, "measured": measured, "place": round(place, 3)})
        print(f"     {name} {r['key']} ({'out' if r['outgoing'] else 'in'}; edge drawn/measured): " + ", ".join(line), flush=True)
    check(f"{name}: every text row's anchored side (incoming left, outgoing right) and top are on whole device pixels",
          not bad_place, bad_place)
    check(f"{name}: every checked edge was measured (top, bottom and a tall row's anchored side; 8 lines each or more)",
          bool(rows) and checked > 0 and not unmeasured, {"unmeasured": unmeasured, "checked": checked})
    check(f"{name}: every balloon edge is where the app draws it (within 0.12 device px, nearer the balloon than its frame)",
          not off_edges, off_edges)
    check(f"{name}: no straight edge of an incoming balloon has partial pixels (at most 10 % of its lines)", not bad_edges, bad_edges)
    return rows
