#!/usr/bin/env python3
"""Table of stress-probe.py results by macOS version (plans/cmux-next/sequoia-lag.md).

Usage: stress-report.py LABEL=RUN_DIR [LABEL=RUN_DIR ...]
  RUN_DIR is a run.sh artifacts dir with one subdirectory per major (14, 15, 26),
  each holding stress.json. Prints one Markdown row per (label, major) and, per
  row, the main-thread stall time grouped by the first cmux-owned frame.
"""
import collections, json, os, re, sys


def owner(frames):
    """The first frame in the app binary that names a cmux type, else the first frame."""
    for frame in frames or []:
        if frame.startswith("cmux DEV ") or frame.startswith("cmux NEXT "):
            text = frame.split(" ", 2)[2]
            text = re.sub(r"^(\(\d+\) )?(suspend resume partial function for |await resume partial function for )?", "", text)
            text = re.sub(r"(closure #\d+ .*? in |implicit closure #\d+ .*? in |partial apply forwarder for |reabstraction thunk helper .*)", "", text)
            match = re.search(r"(Cmux\w+\.[\w.]+)", text)
            if match:
                return match.group(1)
    return (frames or ["?"])[0][:80]


rows = []
for spec in sys.argv[1:]:
    label, run = spec.split("=", 1)
    for major in sorted(os.listdir(run)):
        path = os.path.join(run, major, "stress.json")
        if not os.path.exists(path):
            continue
        d = json.load(open(path))
        p = d["phases"]
        burst = p.get("burst", {})
        owners = collections.Counter()
        for s in d.get("burst_stacks", []):
            owners[owner(s["frames"])] += s["ms"]
        rows.append((label, major, d.get("guest_os"), p.get("create_new_tab", {}), p.get("create_split_right", {}),
                     p.get("create_new_workspace", {}), [r.get("prompt_ms") for r in d.get("rounds", [])], burst,
                     p.get("rounds", {}), p.get("idle", {}), owners))

print("| run | macOS | Cmd-T tab visible p50/p90 ms | split p50/p90 ms | workspace p50/p90 ms | first prompt p50 ms "
      "| 20x Cmd-T burst: all tabs s | burst stalls n / total ms / max ms | CPU app+helpers % (rounds) | WindowServer % (rounds) | idle CPU % |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for label, major, guest, tab, split, ws, prompts, burst, rounds, idle, _ in rows:
    prompts = sorted(x for x in prompts if x is not None)
    p50 = round(prompts[len(prompts) // 2]) if prompts else None
    st = burst.get("stalls", {})
    print("| %s | %s (%s) | %s / %s | %s / %s | %s / %s | %s | %s | %s / %s / %s | %s | %s | %s |" % (
        label, major, guest, tab.get("visible_p50"), tab.get("visible_p90"), split.get("visible_p50"), split.get("visible_p90"),
        ws.get("visible_p50"), ws.get("visible_p90"), p50, burst.get("all_tabs_s"), st.get("count"), st.get("total_ms"),
        st.get("max_ms"), round((rounds.get("app_cpu") or 0) + (rounds.get("kids_cpu") or 0)), rounds.get("ws_cpu"),
        round((idle.get("app_cpu") or 0) + (idle.get("kids_cpu") or 0), 1)))
print()
for label, major, guest, *_, owners in rows:
    print("%s macOS %s burst stalls >=150 ms by owner: %s" % (label, major, ", ".join("%s %d ms" % kv for kv in owners.most_common(8))))
