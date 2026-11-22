#!/usr/bin/env python3
"""launch-ready.sh's summary: per side LR-MEDIAN, LR-REOPENED, LR-USABLE and LR-SURFACE, LR-KEYS with --keys 1, and
LR-SURFACE-DIFF when an A/B's arms first showed different surfaces.

  launch-ready-summary.py RUNS_JSONL [--state kept|bare] [--case update] [--daemon cold] [--snapshot unknown|foreign]
                          [--front home|tab] [--keys 1]

The launch reopens exactly where the person was, Home included (Leo, 2026-11-18: "fresh startup opening home is obv
fine but if it's not first time and the user was on a workspace and a tab, obv just take them there"; "ofc reopening
home if they were prev on home is fine"). Each case's expectation is one entry of EXPECT:
  fresh    state=bare/state=fresh: no saved state, so Home (home.first_page, the window taking keys, and no tab first)
  kept     state=kept: the last front: Home if it was Home, else that (workspace, tab)
  update   case=update: the old copy's last front, on the new copy's first launch
  cold     daemon=cold: the last front, the daemon ended first as a reboot ends it
  foreign  snapshot=foreign: no foreign windows drawn (no launch_snapshot_shown), then this home's own last front
  unknown  snapshot=unknown: the snapshot's front workspace no longer exists in the daemon, so Home
front=home|tab seeds the priming launch's front; every measured launch is then judged against that front.
keys=1 (--keys 1): LR-KEYS SIDE MEDIAN N/M, the side's median first_key_ms (the first key Home's box kept, ms from
process start) over the measured launches whose sent message held a key, and how many of the M measured launches sent one.
A front's compare key: Home when Home is in front (`home`, or topPage "home", or the focused tab's page "home-dock"),
else (workspace, tab): the front window's shown workspace key and its focused pane's selected tab id.
kept, cold and foreign judge every launch after the priming one (or the stress3 seed), the preruns included, against
that launch's front; a prerun that changed it fails the arm. With that front unreadable the arm is not judged
(LR-REOPENED SIDE not-judged: ...), never compared with the launch before instead.
Prints an LR-FAIL row per launch that did not land where it should, and LR-SAME-FRONT: ok only when every arm was
judged and none failed, else invalid with the arms that were not judged or failed. In case=update, a launch whose
launch before left no readable front cannot be judged against it: LR-SKIP, outside N/M, not an LR-FAIL. The stress3 seed quits the app itself, so its
probe reads no front; --out DIR reads the one the seed wrote just before (DIR/seed-SIDE.front.json).
"""
import argparse
import json
import os
import statistics
import sys
from collections import Counter

# The expectation per case, in one place: "home" (the launch shows Home), "last" (the launch before's front, Home
# included) or "own" (as last, and no window drawn from a foreign launch snapshot). daemon=cold is "last": a dead
# daemon never sends the launch to Home; only a missing workspace does, and that is snapshot=unknown.
# Each arm maps 1:1 to the restore lane's Rust test of the same case:
#   state=fresh                  state_fresh_lands_on_home
#   state=kept                   state_kept_reopens_the_last_workspace_and_tab
#   state=kept case=update       state_kept_case_update_reopens_the_last_workspace_and_tab
#   state=kept daemon=cold       state_kept_daemon_cold_reopens_the_last_workspace_and_tab
#   state=kept snapshot=foreign  state_kept_snapshot_foreign_draws_no_foreign_windows_then_reopens_its_own
#   state=kept snapshot=unknown  state_kept_snapshot_unknown_lands_on_home
#   state=kept front=home        state_kept_front_home_reopens_home (and with case=update or daemon=cold: Home too)
# snapshot=unknown: the snapshot's front workspace key no longer exists in the daemon (same session and registry id;
# a different registry id is snapshot=foreign).
EXPECT = {"fresh": "home", "kept": "last", "update": "last", "cold": "last", "foreign": "own", "unknown": "home"}


def case_name(state="kept", case="", daemon="", snapshot="own"):
    """The case a run measures, the key of EXPECT."""
    if state in ("bare", "fresh"):
        return "fresh"
    if snapshot in ("unknown", "foreign"):
        return snapshot
    if daemon == "cold":
        return "cold"
    return "update" if case == "update" else "kept"


def is_home(front):
    front = front or {}
    return front.get("home") is True or front.get("top_page") == "home" or front.get("page") == "home-dock"


def key(front):
    """("home",) or ("tab", workspace, tab): what a launch must reopen."""
    return ("home",) if is_home(front) else ("tab", (front or {}).get("workspace"), (front or {}).get("tab"))


def unreadable(front):
    """Why `front` names nothing a launch could reopen, or None. A window with no workspace, no tab and no Home in
    front is no front: the app never loaded its daemon's tree. cmux#47182's A/B (2026-11-20): the head arm's daemon
    never connected, every launch read {"tab": null, "workspace": null}, and equal nulls passed as reopened 5/5."""
    if not front or "error" in front:
        return str((front or {}).get("error") or "none read")
    if not is_home(front) and not front.get("tab") and not front.get("workspace"):
        return "no workspace, tab or Home in front: " + json.dumps(front, sort_keys=True)
    return None


def describe(front):
    k = key(front)
    return "Home" if k == ("home",) else f"workspace={k[1]} tab={k[2]}"


# What a person sees of a tab: a terminal frame or the launch snapshot's windows. The window's own regions
# (reveal.sidebar, reveal.tabs, reveal.pane) ready before Home's page in a fresh window too: they hold Home.
TAB_DRAWN = ("launch_snapshot_shown", "first_terminal_frame", "launch.visible_terminals_drawn")


def first_surface(row):
    """What the launch showed first: home or tabs (a terminal, restored tabs, the launch snapshot's windows), or none."""
    first, marks = row.get("first_reveal"), row.get("marks") or {}
    home = marks.get("reveal.home", marks.get("home.first_page"))
    if home is not None:
        return "tabs" if any(marks.get(k, home) < home for k in TAB_DRAWN) else "home"
    if first:
        return "home" if first == "home" else "tabs"
    if "launch_snapshot_shown" in marks:
        return "tabs"
    return "home" if "home.first_page" in marks else "none"


def judge(row, expect, prev):
    """The reason a measured launch failed its case, or None."""
    front, marks = row.get("front"), row.get("marks") or {}
    if row.get("cross_arm"):
        return "cross-arm " + json.dumps(row["cross_arm"])
    if expect == "home" and prev is None:  # fresh: the probe opens a terminal after Home takes keys, so no front
        if "home.first_page" not in marks:
            return "not on Home: no home.first_page"
        if first_surface(row) == "tabs":
            return f"on a tab with no saved state: first_reveal={row.get('first_reveal') or 'none'}"
        return None if "window_usable" in marks else "no window_usable: Home's message field never took keys"
    if unreadable(front):
        return "no front: " + str(row.get("error") if not front and row.get("error") else unreadable(front))
    if expect == "home":
        return None if is_home(front) else "on " + describe(front) + ", want Home"
    if unreadable(prev):
        return "no front for the launch before"
    if expect == "own" and "launch_snapshot_shown" in marks:
        return "drew windows from a foreign launch snapshot (launch_snapshot_shown)"
    if key(front) == key(prev):
        return None
    if is_home(front):
        return "landed on Home, last front was " + describe(prev)
    if is_home(prev):
        return "landed on " + describe(front) + ", last front was Home"
    return "opened " + json.dumps(front, sort_keys=True) + " after " + json.dumps(prev, sort_keys=True)


# The cases whose every launch must show the priming launch's front (or the stress3 seed's); case=update's old copy
# sets the front its new copy must reopen, so it keeps comparing with the launch before.
PRIME_ANCHORED = ("kept", "cold", "foreign")
# The launches between the priming one and a measured one: the full-settle preruns (prerun=) and case=update's old copy.
PRERUNS = ("full", "old")


def judge_against_anchor(row, expect, anchor, anchor_drew_home):
    """judge() against the priming launch's front; when that front is Home, Home's page must draw too."""
    reason = judge(row, expect, anchor)
    if reason is None and is_home(anchor) and anchor_drew_home and "home.first_page" not in (row.get("marks") or {}):
        return "Home in front but Home's page did not draw (home.first_page), as the priming launch's did"
    return reason and reason + " (judged against the priming launch's front)"


def fill_seed_fronts(rows, out):
    """The stress3 seed quits the app itself, so its probe read no front; the seed wrote the one it left just before."""
    for r in rows:
        seeded = os.path.join(out, f"seed-{r['side']}.front.json")
        if r["label"] == "seed" and (not r.get("front") or "error" in r["front"]) and os.path.exists(seeded):
            with open(seeded) as handle:
                r["front"] = json.load(handle)


def summarize(rows, case="kept", seeded="", keys=False):
    """Prints the summary; returns the lines' data: {side: {"failed": [...], "surface": first}}."""
    expect, result = EXPECT[case], {}
    print("LR-CASE", case, f"expect={expect}" + (f" front={seeded}" if seeded else ""), flush=True)
    for side in dict.fromkeys(r["side"] for r in rows if not r["side"].startswith("foreign-")):  # not a donor
        own = [r for r in rows if r["side"] == side]
        done = [r for r in own if r["label"].startswith("run") and r.get("window_on_screen") is not None]
        loads = [r["load_1m"] for r in done if r.get("load_1m") is not None]
        med = {"n": len(done), "max_load_1m": max(loads) if loads else None}
        for name in ("finished_launching", "window_on_screen", "active", "request_to_start", "shell_requested"):
            vals = [r[name] for r in done if r.get(name) is not None]
            med[name] = round(statistics.median(vals), 1) if vals else None
        # Which region each launch showed first, counted (a side that opens on a pane is not timed as Home).
        med["first_reveal"] = dict(sorted(Counter(r.get("first_reveal") or "none" for r in done).items()))
        names = dict.fromkeys(name for r in done for name in r["marks"])
        for name in sorted(names, key=lambda n: statistics.median([r["marks"][n] for r in done if n in r["marks"]])):
            med[name] = round(statistics.median([r["marks"][name] for r in done if name in r["marks"]]), 1)
        failed, prev, prev_label, measured, usable, anchor, skipped = [], None, None, 0, 0, None, 0
        drifted, anchor_drew_home, not_judged = [], False, None
        if seeded:  # front=: the priming launch's front is the front every measured launch must reopen
            prime = next((r for r in own if r["label"] == "prime"), {})
            anchor = prime.get("front")
            anchor_drew_home = "home.first_page" in (prime.get("marks") or {})
            if unreadable(anchor) or key(anchor)[0] != ("home" if seeded == "home" else "tab"):
                print("LR-FAIL", side, "prime", f"front={seeded} not seeded: front " + json.dumps(anchor, sort_keys=True), flush=True)
                failed.append("prime")
        # kept, cold, foreign: nothing between launches moves the front, so every launch after the priming one (or the
        # stress3 seed, which sets its own) must show that front: the preruns too, which used to be skipped while still
        # moving `prev`, so a change at prime -> full1 read as N/N reopened (cmux#44491's lost Home front). A launch
        # that changed it fails the arm even when a later one changes it back. With that front unreadable the arm is
        # not judged at all: comparing with the launch before instead is the same blind spot.
        anchored = not seeded and case in PRIME_ANCHORED
        for r in own:
            # The stress3 seed sets the front every later launch must reopen, with front= too: it makes the session
            # and leaves its last workspace's tab (front=tab) in front, so the prime's front is no longer the anchor.
            if (anchored and r["label"] in ("prime", "seed")) or (seeded and r["label"] == "seed"):
                front = r.get("front")
                if unreadable(front):
                    not_judged = f"{r['label']} front unreadable: " + unreadable(front)
                    anchor = None
                else:
                    anchor, not_judged = front, None
                anchor_drew_home = "home.first_page" in (r.get("marks") or {})
            # A seeded run (front=) judges its preruns against the seeded front the same way: a prerun that moved the
            # front and a measured launch that moved it back read 1/1 and LR-SAME-FRONT ok before.
            elif (anchored or seeded) and anchor is not None and r["label"].startswith(PRERUNS):
                reason = judge_against_anchor(r, expect, anchor, anchor_drew_home)
                if reason:
                    print("LR-FAIL", side, r["label"], reason, flush=True)
                    drifted.append(r["label"])
            if r["label"].startswith("run"):
                measured += 1
                usable += "window_usable" in (r.get("marks") or {})
                front, before = r.get("front"), None if case == "fresh" else (anchor if seeded else prev)
                if anchored:
                    reason = None if not_judged else judge_against_anchor(r, expect, anchor, anchor_drew_home)
                elif (expect != "home" and not seeded and not r.get("cross_arm") and not unreadable(front)
                        and unreadable(before)):
                    skipped, reason = skipped + 1, None
                    print("LR-SKIP", side, r["label"], f"{prev_label or 'the launch before'} left no readable front:",
                          str((before or {}).get("error") or "none read"), flush=True)
                else:
                    reason = judge(r, expect, before)
                if reason:
                    print("LR-FAIL", side, r["label"], reason, flush=True)
                    failed.append(r["label"])
            prev, prev_label = r.get("front"), r["label"]
        runs = [r for r in own if r["label"].startswith("run")]
        reopened = measured - sum(1 for label in failed if label != "prime")
        med["reopened"] = f"{reopened - skipped}/{measured - skipped}" + (f" ({skipped} skipped)" if skipped else "")
        if drifted:  # the arm fails: a prerun left the prime's front, whatever the measured launches read
            med["reopened"] += " (front changed at " + ",".join(drifted) + ")"
            failed.extend(drifted)
        if not_judged:
            med["reopened"] = "not-judged: " + not_judged
        med["usable"] = f"{usable}/{measured}"
        surfaces = Counter(first_surface(r) for r in runs)
        first = surfaces.most_common(1)[0][0] if surfaces else "none"
        drawn = sum(1 for r in runs if "home.first_page" in (r.get("marks") or {}))
        med["surface"] = {"first": first, "home_page_drawn": f"{drawn}/{measured}", "mix": dict(sorted(surfaces.items()))}
        print("LR-MEDIAN", side, json.dumps(med), flush=True)
        print("LR-REOPENED", side, med["reopened"], f"case={case}", flush=True)
        print("LR-USABLE", side, med["usable"], flush=True)
        if keys:
            firsts = [r["first_key_ms"] for r in runs if r.get("first_key_ms") is not None]
            landed = sum(1 for r in runs if (r.get("keys_landed") or 0) > 0)
            median = round(statistics.median(firsts), 1) if firsts else None
            print("LR-KEYS", side, median, f"{landed}/{len(runs)}", flush=True)
        mix = ",".join(f"{k}:{v}" for k, v in sorted(surfaces.items()))
        print("LR-SURFACE", side, f"first={first} home_page_drawn={drawn}/{measured} mix={mix}", flush=True)
        # layout=1: what moved after the first frame, per measured launch (moved_pt, changes) and its median and highest.
        laid = [r["layout"] for r in runs if r.get("layout")]
        if laid:
            frames = {"n": len(laid)}
            for part in ("window", "sidebar"):
                seen = [l[part] for l in laid if l[part].get("first") is not None]
                moved, changes = [s["moved_pt"] for s in seen], [s["changes"] for s in seen]
                frames[part] = {"n": len(seen), "moved_pt": moved, "changes": changes,
                                "median_moved_pt": round(statistics.median(moved), 1) if moved else None,
                                "max_moved_pt": max(moved) if moved else None,
                                "median_changes": statistics.median(changes) if changes else None,
                                "launches_that_moved": f"{sum(1 for m in moved if m > 0)}/{len(seen)}"}
            print("LR-FRAMES", side, json.dumps(frames), flush=True)
        result[side] = {"failed": failed, "surface": first, "judged": not not_judged}
    # An A/B whose arms first showed different surfaces times different work: not like for like.
    firsts = {side: data["surface"] for side, data in result.items()}
    if len(set(firsts.values())) > 1:
        print("LR-SURFACE-DIFF", " ".join(f"{s} first={f}" for s, f in firsts.items()) + ": not like for like", flush=True)
    # Whether this run may be quoted as "every launch reopened the same front": every arm judged and none failed.
    unjudged = [s for s, data in result.items() if not data["judged"]]
    moved = [s for s, data in result.items() if data["judged"] and data["failed"]]
    if unjudged or moved:
        print("LR-SAME-FRONT invalid: " + "; ".join([f"{s} not judged" for s in unjudged] +
                                                    [f"{s} failed {','.join(result[s]['failed'])}" for s in moved]), flush=True)
    else:
        print("LR-SAME-FRONT ok: " + ", ".join(result), flush=True)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("runs")
    parser.add_argument("--state", default="kept", choices=["kept", "bare", "fresh"])
    parser.add_argument("--case", default="", choices=["", "update"])
    parser.add_argument("--daemon", default="", choices=["", "warm", "cold"])
    parser.add_argument("--snapshot", default="own", choices=["own", "unknown", "foreign"])
    parser.add_argument("--front", default="", choices=["", "home", "tab"])
    parser.add_argument("--keys", default="0", choices=["0", "1"])
    parser.add_argument("--out", default="", help="the step's output folder (the stress3 seed's front file)")
    args = parser.parse_args(argv)
    rows = [json.loads(line) for line in open(args.runs) if line.strip()]
    if args.out:
        fill_seed_fronts(rows, args.out)
    summarize(rows, case_name(args.state, args.case, args.daemon, args.snapshot), args.front, args.keys == "1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
