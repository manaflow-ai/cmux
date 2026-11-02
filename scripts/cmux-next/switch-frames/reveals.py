#!/usr/bin/env python3
"""Lines up the trace build's per-reveal rows (diag-reveals.json) with each switch key and the switch judge.

Usage: reveals.py --reveals diag-reveals.json --keys NAME-keys.events.json [--judge NAME.switch-judge.json]
Per switch: each terminal revealed within 0.5 s of the key-down, with the reveal's time after the key, whether a
volatile hidden frame existed, whether the layer was EMPTY after the reclaim (a purged frame), the ink of the frame on
the layer at the reveal, and the next presented frames (time after the key, ink). With --judge, the movie's blank
frames of that switch. Prints a table and a summary: how many reveals had an empty layer, a low-ink frame at the
reveal, or a low-ink first presented frame (an empty screen drawn by Ghostty).
"""
import argparse
import json

LOW_INK = 400  # sampled pixels (every 4th px): a beacon pane has thousands; an empty screen with a cursor < 100


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reveals", required=True)
    ap.add_argument("--keys", required=True)
    ap.add_argument("--judge")
    a = ap.parse_args()
    allrows = json.load(open(a.reveals))
    if isinstance(allrows, dict):
        raise SystemExit(f"no reveal rows: {allrows}")
    # v2 rows carry kind: 0 reveal, 1 hide, 2 a reader found the hidden frame purged. v1 rows are reveals.
    reveals = [r for r in allrows if int(r.get("kind", 0)) == 0]
    others = [r for r in allrows if int(r.get("kind", 0)) != 0]

    def before(r):
        """The same surface's last hide and any purge between it and this reveal."""
        mine = [o for o in others if o.get("surface") == r.get("surface") and o["t"] <= r["t"]]
        hide = max((o for o in mine if int(o["kind"]) == 1), key=lambda o: o["t"], default=None)
        purged = [o for o in mine if int(o["kind"]) == 2 and (hide is None or o["t"] >= hide["t"])]
        return hide, purged
    keys = [e for e in json.load(open(a.keys))["events"] if "t" in e]
    judge = {round(e["t"], 4): e for e in json.load(open(a.judge))["events"]} if a.judge else {}
    total = {"reveals": 0, "contents_nil": 0, "had_volatile": 0, "low_ink_at_reveal": 0, "low_ink_first_frame": 0,
             "no_new_frame": 0}
    for i, e in enumerate(keys):
        t0 = e["t"]
        t1 = keys[i + 1]["t"] if i + 1 < len(keys) else t0 + 1.0
        rows = [r for r in reveals if t0 - 0.01 <= r["t"] < min(t1, t0 + 0.5)]
        j = judge.get(round(t0, 4))
        blank = [d for d in (j or {}).get("defects", []) if d["kind"] == "blank"]
        print(f"{e['case']:8} t={t0:.4f} reveals={len(rows)} movie_blank="
              + ",".join(f"+{(d['t'] - t0) * 1000:.0f}ms x{d['frames']}" for d in blank))
        for r in rows:
            total["reveals"] += 1
            total["contents_nil"] += int(r.get("contents_nil", 0))
            total["had_volatile"] += int(r.get("had_volatile", 0))
            total["low_ink_at_reveal"] += int(0 <= r.get("ink", -1) < LOW_INK)
            frames = []
            k = 1
            while f"f{k}_t" in r:
                frames.append((round((r[f"f{k}_t"] - t0) * 1000, 1), int(r[f"f{k}_ink"]), int(r.get(f"f{k}_nil", 0))))
                k += 1
            if not frames:
                total["no_new_frame"] += 1
            elif 0 <= frames[0][1] < LOW_INK:
                total["low_ink_first_frame"] += 1
            hide, purged = before(r)
            if hide is not None:
                total["hide_empty"] = total.get("hide_empty", 0) + int(hide.get("contents_nil", 0))
                total["hide_seen"] = total.get("hide_seen", 0) + 1
            total["purged_on_read"] = total.get("purged_on_read", 0) + int(bool(purged))
            hide_txt = ("hide: none" if hide is None else
                        f"hide {(hide['t'] - t0) * 1000:+.0f}ms empty_layer={int(hide.get('contents_nil', 0))} ink={int(hide.get('ink', -1))}")
            print(f"    surface {int(r.get('surface', 0)) % 100000:5d} [{hide_txt}{' PURGED-ON-READ' if purged else ''}] reveal +{(r['t'] - t0) * 1000:6.1f}ms "
                  f"volatile={int(r.get('had_volatile', 0))} empty_layer={int(r.get('contents_nil', 0))} "
                  f"ink={int(r.get('ink', -1))} frames(ms,ink,nil)={frames}")
    print(json.dumps(total))


if __name__ == "__main__":
    main()
