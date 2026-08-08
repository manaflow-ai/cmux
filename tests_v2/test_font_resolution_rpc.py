#!/usr/bin/env python3
"""Proof script for debug.font.resolve / debug.font.rasterize.

Drives a running TAGGED cmux dev instance (never the user's default socket)
and asserts the fork font-query API answers structurally correct, pipeline-
authoritative results: face identity + source classification per cluster,
sprite routing for box drawing, color-glyph routing for emoji, and pixel
payloads with the documented formats and sizes.

Usage: tests_v2/test_font_resolution_rpc.py --socket /tmp/cmux-debug-<tag>.sock
"""

import argparse
import base64
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--socket",
        default=os.environ.get("CMUX_SOCKET_PATH", cmux.DEFAULT_SOCKET_PATH),
        help="Tagged debug socket path",
    )
    args = parser.parse_args()

    if os.path.realpath(args.socket) == "/tmp/cmux-debug.sock":
        print("FAIL: refusing to run against the user's default socket", file=sys.stderr)
        return 2

    c = cmux(args.socket)
    c.connect()

    failures = []

    def check(name, ok, detail=""):
        status = "ok" if ok else "FAIL"
        print(f"{status}: {name}" + (f" ({detail})" if detail and not ok else ""))
        if not ok:
            failures.append(name)

    surfaces = c.list_surfaces()
    check("at least one surface", bool(surfaces))
    if not surfaces:
        return 1
    panel = 0

    def one(resp):
        items = resp.get("items") or []
        return items[0] if items else {}

    def first_run(doc):
        runs = doc.get("runs") or []
        return runs[0] if runs else {}

    # --- resolve: plain ASCII (primary font) ---
    doc = one(c.font_resolve(panel, [{"cluster": "A"}]))
    run = first_run(doc)
    check("ascii: one run", len(doc.get("runs") or []) == 1, str(doc))
    check("ascii: source primary", run.get("source") == "primary", str(run))
    check("ascii: ps_name non-empty", bool(run.get("ps_name")), str(run))
    check("ascii: not color", run.get("color") is False, str(run))
    glyphs = run.get("glyphs") or []
    check("ascii: one glyph with nonzero index",
          len(glyphs) == 1 and glyphs[0].get("glyph_index", 0) > 0, str(glyphs))
    check("ascii: metrics present",
          (doc.get("metrics") or {}).get("cell_width", 0) > 0, str(doc.get("metrics")))

    # --- resolve: bold style routing ---
    doc_b = one(c.font_resolve(panel, [{"cluster": "A", "bold": True}]))
    run_b = first_run(doc_b)
    check("bold: style is bold", run_b.get("style") == "bold", str(run_b))

    # --- resolve: box drawing is served by the sprite face ---
    doc_s = one(c.font_resolve(panel, [{"cluster": "─"}]))
    run_s = first_run(doc_s)
    check("boxdraw: source sprite", run_s.get("source") == "sprite", str(run_s))
    check("boxdraw: glyph index is the codepoint",
          (run_s.get("glyphs") or [{}])[0].get("glyph_index") == 0x2500, str(run_s))

    # --- resolve: emoji routes to a color face ---
    doc_e = one(c.font_resolve(panel, [{"cluster": "\U0001F600", "constraint_width": 2}]))
    run_e = first_run(doc_e)
    check("emoji: color", run_e.get("color") is True, str(run_e))
    check("emoji: fallback source",
          run_e.get("source") in ("embedded", "discovered", "asset"), str(run_e))

    # --- resolve: CJK resolves via a non-primary path with a real face name.
    # On a cmux app with auto-injected CJK mappings this is "codepoint-map"
    # (cmux's font-codepoint-map config decides the face, e.g. PingFang);
    # without mappings it comes from dynamic fallback discovery.
    doc_c = one(c.font_resolve(panel, [{"cluster": "一", "constraint_width": 2}]))
    run_c = first_run(doc_c)
    check("cjk: ps_name non-empty", bool(run_c.get("ps_name")), str(run_c))
    check("cjk: non-primary source",
          run_c.get("source") in ("codepoint-map", "embedded", "discovered", "asset"),
          str(run_c))

    # --- resolve: batch answers preserve order ---
    batch = c.font_resolve(panel, [{"cluster": "x"}, {"cluster": "y"}, {"cluster": "z"}])
    order = [it.get("cluster") for it in (batch.get("items") or [])]
    check("batch: order preserved", order == ["x", "y", "z"], str(order))

    # --- resolve: invalid params rejected ---
    try:
        c.font_resolve(panel, [{"cluster": "A", "constraint_width": 3}])
        check("invalid constraint rejected", False)
    except cmuxError as e:
        check("invalid constraint rejected", "invalid_params" in str(e), str(e))
    try:
        c.font_resolve(panel, [])
        check("empty items rejected", False)
    except cmuxError as e:
        check("empty items rejected", "invalid_params" in str(e), str(e))

    # --- rasterize: monochrome coverage16-le with exact payload size ---
    doc_r = one(c.font_rasterize(panel, [{"cluster": "A"}]))
    g = (first_run(doc_r).get("glyphs") or [{}])[0]
    check("raster ascii: format coverage16-le",
          g.get("pixel_format") == "coverage16-le", str(g.get("pixel_format")))
    w, h = g.get("width", 0), g.get("height", 0)
    check("raster ascii: nonzero size", w > 0 and h > 0, f"{w}x{h}")
    data = base64.b64decode(g.get("data_b64") or "")
    check("raster ascii: payload w*h*2", len(data) == w * h * 2, f"{len(data)} vs {w * h * 2}")
    check("raster ascii: some coverage", any(data), "all zero")
    # v16 = v8 * 257 (lossless widening) => hi byte == lo byte per sample.
    widened_ok = all(data[i] == data[i + 1] for i in range(0, min(len(data), 4096), 2))
    check("raster ascii: v16 == v8*257", widened_ok)

    # --- rasterize: emoji is premultiplied P3 BGRA ---
    doc_re = one(c.font_rasterize(panel, [{"cluster": "\U0001F600", "constraint_width": 2}]))
    ge = (first_run(doc_re).get("glyphs") or [{}])[0]
    check("raster emoji: format bgra8-premul-p3",
          ge.get("pixel_format") == "bgra8-premul-p3", str(ge.get("pixel_format")))
    we, he = ge.get("width", 0), ge.get("height", 0)
    de = base64.b64decode(ge.get("data_b64") or "")
    check("raster emoji: payload w*h*4", len(de) == we * he * 4, f"{len(de)} vs {we * he * 4}")
    # Premultiplied: every channel <= alpha.
    premul_ok = all(
        de[i] <= de[i + 3] and de[i + 1] <= de[i + 3] and de[i + 2] <= de[i + 3]
        for i in range(0, min(len(de), 8192), 4)
    )
    check("raster emoji: premultiplied", premul_ok)

    # --- rasterize: sprite glyph renders ---
    doc_rs = one(c.font_rasterize(panel, [{"cluster": "─"}]))
    gs = (first_run(doc_rs).get("glyphs") or [{}])[0]
    check("raster sprite: nonzero coverage",
          gs.get("width", 0) > 0 and any(base64.b64decode(gs.get("data_b64") or "")),
          str(gs))

    print(f"\n{'PASS' if not failures else 'FAIL'}: {len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
