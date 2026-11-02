#!/usr/bin/env python3
"""Turns a published resize-videos kit folder of BROWSER VIDEO recordings (<case>.mov, .frames.json, .meta.json,
.events.json) into the rounds.json browser-video-judge.py reads.

  browser-video-kitadapt.py FOLDER [--prefix bv-dt-]

DevTools rounds (bv-dt-<dock>-<page>-<theme>-rN): open = the action's send time (notes.open, round 0) or the first
HID key (rounds 1..N); close = the last HID key. State before/open/after from the notes (bv_state).
Event rounds (bv-pane-*, bv-agent-*): every HID key and bv_action/bv_agent note with a send time, in time order."""
import argparse, glob, json, os

parser = argparse.ArgumentParser()
parser.add_argument("folder")
parser.add_argument("--prefix", default="bv-")
parser.add_argument("--out", required=True, help="a work folder: links to the recordings and rounds.json (the published folder is read-only)")
opts = parser.parse_args()
rounds = []
for meta_path in sorted(glob.glob(os.path.join(opts.folder, opts.prefix + "*.meta.json"))):
    name = os.path.basename(meta_path)[: -len(".meta.json")]
    meta = json.load(open(meta_path))
    events = json.load(open(os.path.join(opts.folder, name + ".events.json")))
    notes = meta.get("notes") or {}
    keys = [e for e in events.get("hid") or [] if e.get("kind") == "key"]
    parts = name.split("-")
    theme = parts[-2] if parts[-1].startswith("r") else parts[-1]
    rnd = int(parts[-1][1:]) if parts[-1].startswith("r") else 0
    case = "-".join(parts[1:-2]) if parts[-1].startswith("r") else "-".join(parts[1:-1])
    entry = {"theme": theme, "case": case, "round": rnd, "movie": name + ".mov", "cold": rnd == 0,
             "refresh_ms": meta.get("refresh_ms"), "scale": (meta.get("start") or {}).get("scale")}
    if name.startswith("bv-dt-"):
        opened = notes.get("open") if rnd == 0 and isinstance(notes.get("open"), dict) and "t_sent" in notes["open"] else None
        open_t = opened["t_sent"] if opened else (keys[0]["t_sent"] if keys else None)
        close_t = keys[-1]["t_sent"] if keys else None
        if open_t is None or close_t is None:
            print(f"skip {name}: no open or close time"); continue
        def page(n):
            v = notes.get(n)
            return (v or {}).get("page") if isinstance(v, dict) else None
        entry.update({"open": {"t_send": open_t, "via": "action" if opened else "hid"}, "close": {"t_send": close_t, "via": "hid"},
                      "state_before": page("before"), "state_open": page("open"), "state_after": page("after"),
                      "devtools_open": (notes.get("open") or {}).get("devtools") if isinstance(notes.get("open"), dict) else None})
    else:
        evs = [{"label": f"{k['args'].get('key')}{'+' + '+'.join(k['args'].get('modifiers') or []) if k['args'].get('modifiers') else ''}",
                "t_send": k["t_sent"], "via": "hid"} for k in keys]
        for label, v in notes.items():
            if isinstance(v, dict) and "t_sent" in v:
                evs.append({"label": label, "t_send": v["t_sent"], "via": "note"})
        entry.update({"kind": "events", "events": sorted(evs, key=lambda e: e["t_send"]),
                      "readiness": {k: v for k, v in notes.items() if k.startswith(("streaming", "after"))}})
    rounds.append(entry)
os.makedirs(opts.out, exist_ok=True)
for entry in rounds:
    for suffix in ("", ".frames.json"):
        link = os.path.join(opts.out, entry["movie"] + suffix)
        if not os.path.lexists(link):
            os.symlink(os.path.abspath(os.path.join(opts.folder, entry["movie"] + suffix)), link)
json.dump({"rounds": rounds}, open(os.path.join(opts.out, "rounds.json"), "w"), indent=1)
print(f"{len(rounds)} rounds -> {os.path.join(opts.out, 'rounds.json')}")
