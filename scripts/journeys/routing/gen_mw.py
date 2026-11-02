#!/usr/bin/env python3
"""Writes the multi-window video journeys (VIDEO EXTRA item 6) from the multi-window P0 journeys (journeys/p0/mw-*.json).

    python3 scripts/journeys/routing/gen_mw.py [--check]

Each mw-*.json gives two copies in journeys/video/mw/:
  mwv-<name>.json     filmed: the HARNESS recorder (ext_video video_start/video_stop, debug.motion record_*) from the
                      first judged step (the first remember_windows, after the set-up; after the last relaunch, as the
                      recorder ends with its process) to the end, at most 120 s;
  mwv-<name>-nf.json  the same steps with no recording (builds without the in-app recorder).
Both put one set-up step first: the person's first terminal by the New Terminal key (new_terminal via key). At launch
the window shows Home with its composer holding the keyboard, and a script's newTab (the journeys' socket
new_terminal) then makes its workspace without showing it (the rule of cp/fix-chief-composer-focus: automation never
takes a person's text input), so every mw-* journey stopped at its first set-up step on f350103 (14 of 14 runs,
02:40-02:45Z). The judged steps are not changed. --check exits 1 when a written file differs.
"""
import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "journeys"
SRC, OUT = HERE / "p0", HERE / "video" / "mw"
FIRST = {"do": "new_terminal", "via": "key", "as": "person",
         "title": "set-up: the person's first terminal (New Terminal key), so the keyboard is in a terminal, not in Home's "
                  "composer, and a script's newTab shows its workspace"}
SECONDS = 120


def variants(spec):
    steps = spec["steps"]
    start = next((i for i, st in enumerate(steps) if st.get("do") == "remember_windows"), len(steps))
    relaunch = [i for i, st in enumerate(steps) if st.get("do") == "relaunch"]
    if relaunch:
        # The in-app recorder ends with its process (KIT 2b): film from the reopened app (after the relaunch).
        start = max(start, relaunch[-1] + 1)
    name = "mwv-" + spec["id"][len("mw-"):]
    out = []
    for film in (True, False):
        body = [dict(st) for st in steps]
        if film:
            body = body[:start] + [{"do": "video_start", "name": name, "seconds": SECONDS,
                                    "title": "film the judged part (geometry and content, no pacing claim)"}] + \
                body[start:] + [{"do": "video_stop", "name": name, "tail": 0.6}]
        fin = list(spec.get("finally") or [])
        if film:
            fin = [{"do": "video_close_open", "title": "stop a recording a failed check left open"}] + fin
        out.append(dict(spec, id=name + ("" if film else "-nf"),
                        title=spec["title"] + ("" if film else " (no film)"),
                        source=f"VIDEO EXTRA item 6 (multi-window), from journeys/p0/{spec['id']}.json",
                        budget_seconds=int(spec.get("budget_seconds", 120)) + 30 + (12 if film else 0),
                        steps=[dict(FIRST)] + body, **({"finally": fin} if fin else {})))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true")
    opts = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    bad = 0
    for path in sorted(SRC.glob("mw-*.json")):
        for spec in variants(json.loads(path.read_text())):
            target = OUT / f"{spec['id']}.json"
            text = json.dumps(spec, indent=2, ensure_ascii=False) + "\n"
            if opts.check:
                if not target.is_file() or target.read_text() != text:
                    print(f"differs: {target}")
                    bad = 1
                continue
            target.write_text(text)
            print(f"wrote {target} ({len(spec['steps'])} steps)")
    return bad


if __name__ == "__main__":
    sys.exit(main())
