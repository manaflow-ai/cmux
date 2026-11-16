#!/usr/bin/env python3
"""Hidden browser tabs under the default `browser.hibernation` (unset): which are discarded, what that
frees, and what a discarded tab costs when it is shown again (process-sharing row 4, Leo 2026-11-14:
"4 yes").

For each count in --counts (default 1,10,20), a fresh app with no `browser.hibernation` in cmux.json
(the default; `keepNeighborTabsAwake` 0 so no tab stays awake beside the shown one) opens:

  plain   --counts Chromium tabs, each its own site (its own renderer), with a --heap-mb stand-in heap
  audio   one tab playing a tone that is heard
  form    one tab with text typed into a field (trusted input: the person's unsaved edit)
  pinned  one pinned tab
  front   one shown tab in front of them all

Then, with every other tab hidden, it measures the "hidden" phase (renderer processes, footprint per
kind, CPU and idle wakeups per second), feeds critical memory pressure (`debug.hibernation.pressure`)
and waits up to --wait seconds for the plain tabs to be discarded, measures the "after" phase, and
shows one discarded plain tab again: the time until the app restored it and until its page answers,
and whether it came back at its URL and scroll position.

Prints PERF-TAB-DISCARD lines and, with --out, a JSON report. Verdict (exit 1 on a broken rule): no
audio, form or pinned tab may be discarded; with --expect-discard, every plain tab must be (the
default discards); a shown discarded tab must come back at its URL.

Usage (a fleet Mac; DEV or bench build, it reads debug.surfaces):
  bench_tab_discard.py --app BUNDLE [--counts 1,10,20] [--heap-mb 40] [--measure 15] [--wait 90]
      [--expect-discard] [--out FILE.json]
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_hibernation as bh  # noqa: E402  (the page server, pages, phase, wait_for, evaluate, PLAY)
import bench_memory as bm  # noqa: E402
import bench_power as bp  # noqa: E402

FOCUS_FIELD = "(()=>{const f=document.getElementById('f');f.name.focus();return document.activeElement===f.name})()"
READ_PLACE = "(()=>JSON.stringify({url:location.href,y:Math.round(scrollY)}))()"
SCROLL = "(()=>{scrollTo(0,%d);return Math.round(scrollY)})()" % bh.SCROLL_Y


def per_tab(phase: dict, kind: str, tabs: int) -> float | None:
    entry = phase["kinds"].get(kind) or {}
    return round(entry.get("footprint_mb", 0) / tabs, 1) if tabs else None


def run_count(args, bundle: str, count: int, ports: list[int]) -> dict:
    config = bm.merged({"browser": {"keepNeighborTabsAwake": 0}}, json.loads(args.config))
    bp.wipe_state(bundle)
    pid, sock, scratch = bm.launch(bundle, config)
    app = bm.App(bundle, sock)
    report: dict = {"count": count, "config": config, "phases": []}
    opened: list[str] = []

    def open_tab(url: str) -> str | None:
        response = app.run("openBrowser.chromium", url=url)
        created = [item for item in response.get("created", []) if str(item).startswith("tab_")]
        if response.get("error") or not created:
            print(f"   open {url}: {response.get('error') or response}", file=sys.stderr)
            return None
        tab = created[0]
        opened.append(tab)
        app.run("tab.focus", target=tab)
        bh.evaluate(sock, tab, SCROLL)
        return tab

    try:
        plain = [t for t in (open_tab(bh.page_url("chromium", i, ports)) for i in range(count)) if t]
        audio = open_tab(bh.page_url("chromium", 900, ports) + "&audio=1")
        audible = bh.evaluate(sock, audio, bh.PLAY) if audio else None
        form = open_tab(bh.page_url("chromium", 901, ports))
        typed = None
        if form:
            bh.evaluate(sock, form, FOCUS_FIELD)
            typed = bp.rpc(sock, "browser.page.insert_text", {"tab": form, "text": "unsaved draft"})
        pinned = open_tab(bh.page_url("chromium", 902, ports))
        if pinned:
            app.run("palette.toggleTabPin", target=pinned)
        front = open_tab(f"http://front.localhost:{ports[0]}/?n=front")
        app.run("tab.focus", target=front)
        kept = {"audio": audio, "form": form, "pinned": pinned}
        report.update({"plain": plain, "kept": kept, "audible": audible, "typed": typed})
        print(f"PERF-TAB-DISCARD-SETUP count={count} plain={len(plain)} audible={audible} typed={json.dumps(typed)} "
              f"pinned={bool(pinned)}", flush=True)
        # Agent grace (30 s after the bench's script calls) passes first, as for the person's own tabs.
        time.sleep(35)  # test script: let the hidden pages settle past the agent grace
        hidden = bh.phase(pid, bundle, "hidden", args.measure, report, sock)
        how = bh.feed_pressure(sock, "critical")
        report["pressure_source"] = how
        started = time.monotonic()
        ever: set[str] = set()

        def plain_gone():
            asleep = set(bh.hibernation(sock).get("hibernated") or [])
            ever.update(asleep)
            return set(plain) <= asleep and time.monotonic()

        done = bh.wait_for(plain_gone, args.wait, 0.25)
        status = bh.hibernation(sock)
        report["discard_s"] = round(done - started, 2) if done else None
        report["discarded_plain"] = len(set(plain) & ever)
        report["discarded_kept"] = {name: tab in ever for name, tab in kept.items() if tab}
        report["exemptions"] = {name: (status.get("exemptions") or {}).get(tab) for name, tab in kept.items() if tab}
        bh.feed_pressure(sock, "normal")
        time.sleep(10)  # test script: discarded pages' renderers exit and the app settles
        after = bh.phase(pid, bundle, "after", args.measure, report, sock)
        gone = bh.exited(hidden, after, "cef-renderer")
        report["renderers"] = {"hidden": hidden["cef_renderers"], "after": after["cef_renderers"], "exited": len(gone)}
        report["renderer_mb_per_plain_tab"] = {"hidden": per_tab(hidden, "cef-renderer", len(plain)),
                                               "after": per_tab(after, "cef-renderer", len(plain))}
        report["freed_mb_per_plain_tab"] = round((bh.total(gone, "footprint_mb") or 0) / max(len(plain), 1), 1)
        report["idle_wakeups_per_s"] = {
            "hidden": (hidden["kinds"].get("cef-renderer") or {}).get("wakeups_per_s"),
            "after": (after["kinds"].get("cef-renderer") or {}).get("wakeups_per_s"),
            "app_hidden": (hidden["kinds"].get("app") or {}).get("wakeups_per_s"),
            "app_after": (after["kinds"].get("app") or {}).get("wakeups_per_s"),
        }
        report["total_mb"] = {"hidden": hidden["total_footprint_mb"], "after": after["total_footprint_mb"]}
        # Show one discarded plain tab again: it reloads at its URL (and scroll), its snapshot shown until it paints.
        woken = next((t for t in plain if t in set(bh.hibernation(sock).get("hibernated") or [])), None)
        if woken:
            want = bh.page_url("chromium", plain.index(woken), ports)
            row = bh.wake(app, sock, woken, "chromium")
            place = bh.evaluate(sock, woken, READ_PLACE, 10)
            got = json.loads(place) if isinstance(place, str) else {}
            row.update({"url_ok": got.get("url") == want, "url": got.get("url"), "scroll_y": got.get("y")})
            report["wake"] = row
        print(f"PERF-TAB-DISCARD count={count} source={how} discard_s={report['discard_s']} "
              f"discarded_plain={report['discarded_plain']}/{len(plain)} discarded_kept={json.dumps(report['discarded_kept'])} "
              f"exemptions={json.dumps(report['exemptions'])} renderers={json.dumps(report['renderers'])} "
              f"renderer_mb_per_plain_tab={json.dumps(report['renderer_mb_per_plain_tab'])} "
              f"freed_mb_per_plain_tab={report['freed_mb_per_plain_tab']} total_mb={json.dumps(report['total_mb'])} "
              f"idle_wakeups_per_s={json.dumps(report['idle_wakeups_per_s'])} "
              f"wake={json.dumps({k: (report.get('wake') or {}).get(k) for k in ('mounted_ms', 'usable_ms', 'app_mounted_ms', 'loaded_ms', 'snapshot', 'url_ok', 'scroll_y')})}",
              flush=True)
    finally:
        app.run("quit")
        bm.wait_gone(pid, 20)
        bm.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--counts", default="1,10,20")
    parser.add_argument("--heap-mb", type=int, default=40)
    parser.add_argument("--measure", type=float, default=15)
    parser.add_argument("--wait", type=float, default=90, help="seconds to wait for the plain tabs under pressure")
    parser.add_argument("--config", default="{}", help="extra cmux.json settings (JSON)")
    parser.add_argument("--expect-discard", action="store_true", help="fail unless every plain tab was discarded")
    parser.add_argument("--out")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("bench-tab-discard: macOS only (run it on a fleet Mac)")
    bh._Handler.heap_mb = args.heap_mb
    signal.signal(signal.SIGTERM, bm.interrupted)
    ports = [bh.serve()]
    bundle = os.path.realpath(args.app)
    runs = [run_count(args, bundle, int(n), ports) for n in args.counts.split(",") if n]
    if args.out:
        with open(args.out, "w") as handle:
            json.dump({"app": bundle, "runs": runs}, handle, indent=1)
    broken = []
    for run in runs:
        broken += [f"{run['count']}:{name}" for name, gone in (run.get("discarded_kept") or {}).items() if gone]
        if args.expect_discard and run.get("discarded_plain") != len(run.get("plain") or []):
            broken.append(f"{run['count']}:plain_not_discarded")
        if args.expect_discard and not (run.get("wake") or {}).get("url_ok"):
            broken.append(f"{run['count']}:wake_url")
    print("PERF-TAB-DISCARD-VERDICT " + ("FAIL " + ",".join(broken) if broken else "ok"), flush=True)
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
