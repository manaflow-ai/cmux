#!/usr/bin/env python3
"""Compares two motion parity corpora: cmux-motion's (Rust,
`cargo run -p cmux-motion --example motion_trajectories`) and cmux-next
macOS's (Swift, `debug.motion {"action": "trajectory"}` on a tagged app).

Every resolved token (response, damping fraction, visible end) and every
frame path (200 pt move and mid-flight retarget, 60 and 120 Hz, bounce none
and subtle) must agree: tokens within 1e-6, visible ends within one 1/480 s
probe step, path samples within 0.01 pt (Rust steps in f32, Swift in
CGFloat), and the frame a path rests on within one frame (the f32/f64 settle
test can flip at the boundary). Prints the largest differences and exits 1
on any mismatch.

usage: motion-parity.py RUST.json SWIFT.json [--report OUT.json]
"""
import json
import sys

TOKEN_TOL = 1e-6
VISIBLE_END_TOL = 1 / 480 + 1e-9
SAMPLE_TOL = 0.01


def load(path):
    with open(path) as f:
        doc = json.load(f)
    # A debug socket reply wraps the document in {"ok": true, "result": ...}.
    for key in ("result", "value"):
        if isinstance(doc, dict) and key in doc and "tokens" not in doc:
            doc = doc[key]
    return doc


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    report_path = argv[argv.index("--report") + 1] if "--report" in argv else None
    if report_path in args:
        args.remove(report_path)
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    a, b = load(args[0]), load(args[1])
    failures = []
    key = lambda r: (r["token"], r["bounce"])
    ta = {key(r): r for r in a["tokens"]}
    tb = {key(r): r for r in b["tokens"]}
    if set(ta) != set(tb):
        failures.append(f"token sets differ: {sorted(set(ta) ^ set(tb))}")
    worst_token = worst_end = worst_sample = 0.0
    worst_frames = 0
    for k in sorted(set(ta) & set(tb)):
        for field in ("response", "damping_fraction"):
            d = abs(ta[k][field] - tb[k][field])
            worst_token = max(worst_token, d)
            if d > TOKEN_TOL:
                failures.append(f"{k} {field}: {ta[k][field]} vs {tb[k][field]}")
        d = abs(ta[k]["visible_end"] - tb[k]["visible_end"])
        worst_end = max(worst_end, d)
        if d > VISIBLE_END_TOL:
            failures.append(f"{k} visible_end: {ta[k]['visible_end']} vs {tb[k]['visible_end']}")
    pkey = lambda r: (r["token"], r["bounce"], r["hz"], r["case"])
    pa = {pkey(r): r["values"] for r in a["paths"]}
    pb = {pkey(r): r["values"] for r in b["paths"]}
    if set(pa) != set(pb):
        failures.append(f"path sets differ: {sorted(set(pa) ^ set(pb))}")
    for k in sorted(set(pa) & set(pb)):
        va, vb = pa[k], pb[k]
        frames = abs(len(va) - len(vb))
        worst_frames = max(worst_frames, frames)
        if frames > 1:
            failures.append(f"{k} rests after {len(va)} vs {len(vb)} frames")
        for i, (x, y) in enumerate(zip(va, vb)):
            d = abs(x - y)
            worst_sample = max(worst_sample, d)
            if d > SAMPLE_TOL:
                failures.append(f"{k} frame {i}: {x} vs {y}")
                break
    summary = {
        "ports": [a.get("port"), b.get("port")],
        "tokens": len(set(ta) & set(tb)),
        "paths": len(set(pa) & set(pb)),
        "max_token_delta": worst_token,
        "max_visible_end_delta_s": worst_end,
        "max_sample_delta_pt": worst_sample,
        "max_rest_frame_delta": worst_frames,
        "failures": failures,
        "ok": not failures,
    }
    print(json.dumps(summary, indent=1))
    if report_path:
        with open(report_path, "w") as f:
            json.dump(summary, f, indent=1)
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
