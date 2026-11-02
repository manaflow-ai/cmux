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
    # The driver's t_sent is its own process clock; the movie's frames are host seconds (CACurrentMediaTime). The app's
    # input journal stamps each key-down in host time (uptimeNanos): key i's time is the i-th key-down the app got, and
    # the driver-to-host offset (from those pairs) places a note's t_sent (an action) on the host clock too.
    downs = [e["uptimeNanos"] / 1e9 for e in events.get("journal") or []
             if ((e.get("kind") or {}).get("key") or {}).get("_0", {}).get("phase") == "down"
             and ((e.get("kind") or {}).get("key") or {}).get("_0", {}).get("keyClass") != "modifier"]
    # A refused dock action falls back to a real key that the hid log does not list: one more key-down than keys,
    # the first one (the open).
    fallback_open = downs[0] if len(downs) == len(keys) + 1 else None
    if fallback_open is not None:
        downs = downs[1:]
    offsets = [d - k["t_sent"] for k, d in zip(keys, downs)]
    offset = sorted(offsets)[len(offsets) // 2] if offsets else None
    for k, d in zip(keys, downs):
        k["t_host"] = d
    def host(t):
        return t + offset if offset is not None else None
    parts = name.split("-")
    theme = parts[-2] if parts[-1].startswith("r") else parts[-1]
    rnd = int(parts[-1][1:]) if parts[-1].startswith("r") else 0
    case = "-".join(parts[1:-2]) if parts[-1].startswith("r") else "-".join(parts[1:-1])
    entry = {"theme": theme, "case": case, "round": rnd, "movie": name + ".mov", "cold": rnd == 0,
             "refresh_ms": meta.get("refresh_ms"), "scale": (meta.get("start") or {}).get("scale")}
    if name.startswith("bv-dt-"):
        act = notes.get("open-action")
        opened = act if rnd == 0 and isinstance(act, dict) and "t_sent" in act and not (act.get("reply") or {}).get("fallback_key") else None
        if rnd == 0 and isinstance(act, dict) and (act.get("reply") or {}).get("fallback_key"):
            entry["open_note"] = "the dock action was refused; the real key opened DevTools"
        # Round 0's dock action: the app's own start of that run (debug.action_budget start_uptime_ns), never a Python
        # clock; a recording without it has no open time (not judged).
        app_start = (opened or {}).get("app_start_uptime_ns")
        open_t = fallback_open if fallback_open is not None else (
            app_start / 1e9 if opened and app_start else (None if opened else (keys[0].get("t_host") if keys else None)))
        close_t = keys[-1].get("t_host") if keys else None
        entry["key_offsets"] = [round(o, 4) for o in offsets]
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
                "t_send": k.get("t_host") or host(k["t_sent"]), "via": "hid"} for k in keys]
        for label, v in notes.items():
            if isinstance(v, dict) and "t_sent" in v and host(v["t_sent"]) is not None:
                evs.append({"label": label, "t_send": host(v["t_sent"]), "via": "note"})
        evs = [e for e in evs if e["t_send"] is not None]
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
