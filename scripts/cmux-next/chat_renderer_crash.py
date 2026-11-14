#!/usr/bin/env python3
"""Chat renderer crash test and bench (Leo, 2026-11-14, row 2 of the process-sharing table: agent chats
capped at 8 per cmux-page renderer).

cmux's own pages run in Chromium, one renderer per page site (`cmux-process-per-site-schemes`), so
every agent chat shared one renderer: one renderer crash or out-of-memory kill reloaded every open chat.
With `cmux-process-per-site-main-frame-cap=8` (the fork's cmux_process_per_site_main_frame_cap) a
renderer holds at most 8 pages.

Phases (each prints CHAT-RENDERERS lines):
  open     --chats answered chats on the acpmux test agent (bench_memory.FakeChats), one workspace each,
           each pinned so its hidden page stays loaded (HiddenChatPages keeps pinned tabs); at each count
           in --counts: renderer processes, chat pages per renderer, renderer and total footprint, and
           footprint per chat
  crash    a marker set in every chat page's script context (DevTools Runtime.evaluate), then SIGKILL of
           the renderer that holds the most chat pages, a wait of --settle seconds, and the marker read
           again: a page without it reloaded (or still shows its renderer's end)

Pass (exit 0): at most --cap pages lost their marker, and every page in another renderer kept it (no
other page saw a termination). Fail (exit 1) otherwise; exit 2 when the setup did not hold (fewer live
chat pages than --min-pages, no renderer pid for a page).

Usage (a fleet GUI mini, a tagged DEV build; scripts/measure/chat-renderer-crash.sh builds one):
  chat_renderer_crash.py --app BUNDLE [--chats 20] [--counts 1,10,20] [--crash-at 10] [--cap 8] [--out FILE.json]
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory as bm  # noqa: E402  (launch, App, FakeChats, sample, end_bundle, wait_gone, chat_tab_of)
import bench_power as bp  # noqa: E402  (rpc, wipe_state)

CHAT_ORIGIN = "cmux-page://cmux.agent"
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAKE_AGENT = os.path.join(REPO, "cmux-tui/crates/acpmux/tests/fake_agent.py")


def chat_pages(sock: str) -> tuple[list[dict], dict[int, int]]:
    """The live chat pages ({browser, url, hidden, renderer}) and {renderer client id: pid}, from
    `renderers.list` (the app's own report: every Chromium page and every renderer helper)."""
    report = bp.rpc(sock, "renderers.list", {"interval_ms": 0}, timeout=30)
    if report.get("error"):
        raise SystemExit(f"chat-renderer-crash: renderers.list: {report['error']}")
    pids = {int(h["client"]): int(h["pid"]) for h in report.get("helpers") or [] if h.get("client") is not None}
    pages = []
    for page in report.get("pages") or []:
        if not str(page.get("url", "")).startswith(CHAT_ORIGIN):
            continue
        clients = [int(c) for c in page.get("renderer_clients") or []]
        renderer = next((pids[c] for c in clients if c in pids), None)
        pages.append({"browser": int(page["browser"]), "url": page.get("url"), "hidden": page.get("hidden"),
                      "renderer": renderer})
    return pages, pids


def evaluate(app: bm.App, browser: int, expression: str) -> tuple[str | None, str | None]:
    """`expression`'s string value in the page's main world, or (None, error)."""
    reply = app.call("debug.cef_page_devtools", {"browser": browser, "method": "Runtime.evaluate",
                                                 "params": {"expression": expression, "returnByValue": True}},
                     timeout=40)
    if reply.get("error"):
        return None, str(reply["error"])[:200]
    try:
        result = json.loads(reply.get("result") or "{}")
    except ValueError:
        return None, "unreadable DevTools reply"
    value = (result.get("result") or {}).get("value")
    if result.get("exceptionDetails"):
        return None, "exception"
    return (None if value is None else str(value)), None


def measure(app_pid: int, bundle: str, sock: str, chats: int) -> dict:
    """Renderers, chat pages per renderer and footprint with `chats` chats open."""
    pages, _ = chat_pages(sock)
    sample = bm.sample(app_pid, bundle, f"chats-{chats}", chats)
    renderers = [row for row in sample["processes"] if row["kind"] == "cef-renderer"]
    per = {}
    for page in pages:
        if page["renderer"] is not None:
            per[page["renderer"]] = per.get(page["renderer"], 0) + 1
    chat_renderers = [row for row in renderers if row["pid"] in per]
    result = {
        "chats": chats, "chat_pages": len(pages),
        "renderers": len(renderers), "chat_renderers": len(chat_renderers),
        "pages_per_chat_renderer": sorted(per.values(), reverse=True),
        "chat_renderer_footprint_mb": round(sum(r["footprint_mb"] for r in chat_renderers), 1),
        "renderer_footprint_mb": round(sum(r["footprint_mb"] for r in renderers), 1),
        "total_footprint_mb": sample["total_footprint_mb"],
    }
    result["chat_renderer_mb_per_chat"] = round(result["chat_renderer_footprint_mb"] / max(len(pages), 1), 1)
    result["total_mb_per_chat"] = round(result["total_footprint_mb"] / max(chats, 1), 1)
    print("CHAT-RENDERERS phase=open " + " ".join(f"{k}={json.dumps(v, separators=(',', ':'))}" for k, v in result.items()),
          flush=True)
    return result


def crash(app: bm.App, sock: str, cap: int, min_pages: int, settle: float) -> dict:
    """Marks every chat page, kills the renderer with the most chat pages, and reads the marks again."""
    pages, _ = chat_pages(sock)
    if len(pages) < min_pages:
        print(f"chat-renderer-crash: only {len(pages)} live chat pages (need {min_pages})", file=sys.stderr)
        sys.exit(2)
    if any(p["renderer"] is None for p in pages):
        print(f"chat-renderer-crash: a chat page has no renderer pid: {pages}", file=sys.stderr)
        sys.exit(2)
    mark = uuid.uuid4().hex
    for page in pages:
        value, error = evaluate(app, page["browser"], f"window.__chatRendererCrashMark = {json.dumps(mark)}")
        if value != mark:
            print(f"chat-renderer-crash: could not mark page {page['browser']}: {error or value}", file=sys.stderr)
            sys.exit(2)
    counts: dict[int, int] = {}
    for page in pages:
        counts[page["renderer"]] = counts.get(page["renderer"], 0) + 1
    victim = max(counts, key=lambda pid: counts[pid])
    print(f"CHAT-RENDERERS phase=kill pages={len(pages)} renderers={len(counts)} victim_pid={victim} "
          f"victim_pages={counts[victim]} pages_per_renderer={sorted(counts.values(), reverse=True)}", flush=True)
    os.kill(victim, signal.SIGKILL)
    time.sleep(settle)  # test script: the killed renderer's pages reload; the others must not notice
    lost, kept, lost_elsewhere = [], [], []
    for page in pages:
        value, error = evaluate(app, page["browser"], "String(window.__chatRendererCrashMark)")
        if value == mark:
            kept.append(page["browser"])
            continue
        lost.append(page["browser"])
        if page["renderer"] != victim:
            lost_elsewhere.append({"browser": page["browser"], "renderer": page["renderer"], "read": value, "error": error})
    after, _ = chat_pages(sock)
    result = {"pages": len(pages), "victim_pid": victim, "victim_pages": counts[victim], "reloaded": len(lost),
              "kept": len(kept), "reloaded_outside_victim": lost_elsewhere, "pages_after": len(after),
              "cap": cap}
    result["pass"] = len(lost) <= cap and not lost_elsewhere
    print(f"CHAT-RENDERERS phase=crash pages={len(pages)} reloaded={len(lost)} kept={len(kept)} cap={cap} "
          f"reloaded_outside_victim={len(lost_elsewhere)} pages_after={len(after)} "
          f"result={'PASS' if result['pass'] else 'FAIL'}", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--chats", type=int, default=20)
    parser.add_argument("--counts", default="1,10,20", help="chat counts to measure at (comma-separated)")
    parser.add_argument("--crash-at", type=int, default=0, help="run the crash phase at this many chats (default: --chats)")
    parser.add_argument("--cap", type=int, default=8, help="the most pages one renderer crash may reload")
    parser.add_argument("--settle", type=float, default=20, help="seconds after the kill before the marks are read")
    parser.add_argument("--out")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("chat-renderer-crash: macOS only (run it on a fleet GUI mini)")
    counts = sorted({int(c) for c in args.counts.split(",") if c.strip()} | {args.chats})
    crash_at = args.crash_at or args.chats
    if crash_at < 10:
        raise SystemExit("chat-renderer-crash: --crash-at must be at least 10 (more chats than one renderer may hold)")
    stopping = {"signal": False}

    def terminate(_signum, _frame):
        stopping["signal"] = True
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    # Hidden pages stay loaded and running: no tab freeze or hibernation, so every chat page is live
    # when its renderer is killed (pinned chats also keep their pages, HiddenChatPages).
    config = {"browser": {"hibernation": "off", "freezeHiddenTabs": "off", "keepNeighborTabsAwake": 0}}
    bundle = os.path.realpath(args.app)
    bp.wipe_state(bundle)
    extra = {}
    if os.environ.get("CI_JOB_DIR"):
        extra["CI_JOB_DIR"] = os.environ["CI_JOB_DIR"]
    pid, sock, scratch = bm.launch(bundle, config, extra)
    report = {"app": bundle, "chats": args.chats, "counts": counts, "cap": args.cap, "open": [], "crash": None}
    status = 0
    try:
        app = bm.App(bundle, sock)
        cef = bp.rpc(sock, "debug.cef") or {}
        if cef.get("unavailable") or cef.get("fallback"):
            raise SystemExit(f"chat-renderer-crash: Chromium is not available: {json.dumps(cef)[:400]}")
        report["cef"] = {k: cef.get(k) for k in ("version", "fork_api_version", "switches") if k in cef}
        chats = bm.FakeChats(app, bundle, FAKE_AGENT)
        opened = 0
        for index in range(max(counts[-1], crash_at)):
            workspace = chats.open(index)
            if workspace is None:
                raise SystemExit(f"chat-renderer-crash: chat {index} did not open")
            app.action("goToWorkspace", focus=True, workspace=workspace)
            tab = bm.CHAT_TABS.get(workspace) or bm.chat_tab_of(app, workspace)
            pinned = app.run("palette.toggleTabPin", target=tab) if tab else {"error": "no chat tab"}
            if pinned.get("error"):
                print(f"   pin {workspace}: {pinned['error']}", file=sys.stderr)
            opened += 1
            if opened in counts:
                time.sleep(5)  # test script: the newest chat's page finishes loading before the sample
                report["open"].append(measure(pid, bundle, sock, opened))
            if opened == crash_at:
                report["crash"] = crash(app, sock, args.cap, 10, args.settle)
                if not report["crash"]["pass"]:
                    status = 1
                break
    finally:
        # A cancelled step has seconds before SIGKILL: end the bundle's processes at once.
        if not stopping["signal"]:
            try:
                bm.App(bundle, sock).run("quit")
                bm.wait_gone(pid, 20)
            except Exception as error:  # noqa: BLE001  the quit failed; the processes are ended below
                print(f"   quit: {error}", file=sys.stderr)
        bm.end_bundle(bundle)
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=1)
        shutil.rmtree(scratch, ignore_errors=True)
        bp.wipe_state(bundle)
    sys.exit(status)


if __name__ == "__main__":
    main()
