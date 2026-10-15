"""VERIFY-round6 real Codex on the open tab (prompt typed on the phone):
D7 (75 s hands-off follow, 60 fps motion + rows.py on the numbered list), then drags and
flings while it streams (frame log window), Jump to bottom 0.1/0.3/0.6 s after flings,
and a final phone-vs-Mac bottom compare.

    python3 v6_codex.py TAG
"""
import json
import os
import subprocess
import sys
import time

import tq
import v6
from v6 import ev, ctx

PROMPT = ("Print the numbers 1 to 900 in your reply, one per line, as N. followed by a different sentence "
          "of about 12 words about lighthouses each time. No tools.")


def motion(video, tag, start=2, fps=60):
    out = os.path.join(v6.V6, f"{tag}-motion.json")
    subprocess.run([sys.executable, os.path.join(tq.HERE, "motion.py"), video, "--fps", str(fps), "--start", str(start),
                    "--bottom", "0.8", "--quiet", "--json", out], capture_output=True)
    d = json.load(open(out))
    su = d["summary"]
    json.dump({"summary": su, "frames_black_or_flash": [f for f in d["frames"] if f.get("black") or f.get("flash")]}, open(out, "w"))
    return su


def main():
    tag = sys.argv[1]
    s, m, j = ctx()
    t0 = time.strftime("%Y-%m-%d %H:%M:%S")
    tq.paste_composer(PROMPT)
    j.hide_keyboard()
    ev("codex_prompt", tag=tag)
    time.sleep(15)  # stimulus pacing: Codex starts streaming
    # D7: hands-off follow
    w0 = time.time()
    v = tq.rec_start(f"{tag}-follow")
    time.sleep(75)
    tq.rec_stop()
    w1 = time.time()
    su = motion(v, f"{tag}-follow")
    ev("d7", tag=tag, window=[w0, w1], moves=su.get("moves"), moves_down=su.get("moves_down"),
       reversals=su.get("reversals"), flashes=su.get("flashes"), flash_list=su.get("flash_list"),
       black=su.get("black_frames"), source=su.get("source"))
    # scroll while streaming: drags and flings
    w2 = time.time()
    v = tq.rec_start(f"{tag}-scroll")
    taps = []
    for i in range(6):
        t = time.time(); s.drag(201, 250, 201, 600, 0.6, 30, 0.2); taps.append(("drag", t))
        time.sleep(1.0)
        t = time.time(); s.swipe(200, 250, 200, 650, duration=0.12); taps.append(("fling", t))
        time.sleep(1.5)
        t = time.time(); s.swipe(200, 600, 200, 300, duration=0.15); taps.append(("fling-down", t))
        time.sleep(1.5)
    jumps = []
    jb = None
    for delay in (0.1, 0.3, 0.6, 0.1, 0.3, 0.6):
        s.swipe(200, 250, 200, 650, duration=0.12)
        time.sleep(1.8)
        jb = jb or v6.jump_button()
        if not jb:
            continue
        s.swipe(200, 250, 200, 650, duration=0.12)
        time.sleep(delay)
        t = time.time(); s.tap(*jb.center); taps.append(("jump", t))
        time.sleep(2.5)
        jumps.append({"delay": delay, "gone": not v6.jump_button()})
    tq.rec_stop()
    w3 = time.time()
    st = json.load(open(os.path.expanduser("~/cnx-ios-e2e/termqa-state.json")))
    su2 = motion(v, f"{tag}-scroll", start=1.5, fps=30)
    ev("codex_scroll", tag=tag, window=[w2, w3], jumps=jumps, black_runs=[(r["start"], r["end"]) for r in su2["black_runs"]],
       flashes_foreign=su2.get("flashes_foreign"))
    time.sleep(3)
    p, mm = tq.compare_bottom(6) if False else (None, None)
    v6.applog(t0, os.path.join(v6.V6, f"{tag}.log"))
    json.dump({"follow_window": [w0, w1], "scroll_window": [w2, w3], "taps": taps, "jumps": jumps},
              open(os.path.join(v6.V6, f"{tag}-result.json"), "w"), indent=1)
    print(json.dumps({"d7": {k: su.get(k) for k in ("moves", "moves_down", "moves_up", "max_move_rows", "reversals", "flashes",
                                                      "flashes_jump", "flashes_foreign", "black_frames", "flash_list", "source")},
                      "scroll": {"black_runs": [(r["start"], r["end"]) for r in su2["black_runs"]],
                                 "flashes_foreign": su2.get("flashes_foreign"), "source": su2["source"]},
                      "jumps": jumps}, indent=1))


if __name__ == "__main__":
    main()
