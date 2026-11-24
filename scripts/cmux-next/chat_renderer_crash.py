"""Chat renderer crash test (Leo, 2026-11-14, row 2 of the process-sharing table: agent chats capped at 8
per cmux-page renderer), run inside bench_memory.py's --fake-agent chats.

cmux's own pages run in Chromium, one renderer per page site (`cmux-process-per-site-schemes`), so every
agent chat shared one renderer: one renderer crash or out-of-memory kill reloaded every open chat. With
`cmux-process-per-site-main-frame-cap=8` (the fork's cmux_process_per_site_main_frame_cap) a renderer
holds at most 8 pages.

`CMUX_BENCH_CHAT_RENDERER_CRASH=1` in bench_memory.py's environment turns it on; perf-10x-idle.sh sets it for
its agent chats with `chat_renderer_crash=1`:
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/perf-10x-idle.sh \
    --ref SHA --arg=chat_renderer_crash=1 --arg=counts=1 --arg=measure=10 --arg=agents=2,11,21 \
    --artifact .build/perf-idle/agents.json
Each chat is then pinned and hidden pages neither freeze nor hibernate, so every chat page stays live.
At each agent count it records the chat pages per renderer (`chat_renderers`); after the last count:

  crash  a marker set in every chat page's script context (DevTools Runtime.evaluate), then SIGKILL of the
         renderer that holds the most chat pages, a wait, and the marker read again: a page without it
         reloaded (or still shows its renderer's end)

Pass: at most CAP pages lost their marker, and every page in another renderer kept it (no other page
saw a termination). bench_memory exits 1 on a fail, 2 when the setup did not hold (fewer than 10 live
chat pages, a page with no renderer pid).
"""
from __future__ import annotations

import json
import os
import signal
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from state_wait import wait_stable, wait_until  # noqa: E402
from safe_log import safe_print  # noqa: E402  (a line before a kill never skips the kill)

ENV = "CMUX_BENCH_CHAT_RENDERER_CRASH"
CAP = 8
MIN_PAGES = 10
SETTLE_S = 60  # the most the killed renderer's pages may take to load again
CHAT_ORIGIN = "cmux-page://cmux.agent"
# Hidden chat pages stay loaded and running, so the kill finds every chat page live.
CONFIG = {"browser": {"hibernation": "off", "freezeHiddenTabs": "off", "keepNeighborTabsAwake": 0}}


def enabled() -> bool:
    return os.environ.get(ENV) == "1"


def call(app, method: str, params: dict, timeout: float = 30) -> dict:
    return app.call(method, params, timeout=timeout) or {}


def chat_pages(app) -> list[dict]:
    """The live chat pages ({browser, hidden, renderer pid}) from `renderers.list` (the app's own report:
    every Chromium page and every renderer helper)."""
    report = call(app, "renderers.list", {"interval_ms": 0})
    if report.get("error"):
        raise SystemExit(f"chat-renderer-crash: renderers.list: {report['error']}")
    pids = {int(h["client"]): int(h["pid"]) for h in report.get("helpers") or [] if h.get("client") is not None}
    pages = []
    for page in report.get("pages") or []:
        if not str(page.get("url", "")).startswith(CHAT_ORIGIN):
            continue
        clients = [int(c) for c in page.get("renderer_clients") or []]
        pages.append({"browser": int(page["browser"]), "hidden": page.get("hidden"),
                      "renderer": next((pids[c] for c in clients if c in pids), None)})
    return pages


def renderers(app) -> dict:
    """Chat pages per renderer now: {"chat_pages", "chat_renderers", "pages_per_renderer"}."""
    per: dict[int, int] = {}
    pages = chat_pages(app)
    for page in pages:
        if page["renderer"] is not None:
            per[page["renderer"]] = per.get(page["renderer"], 0) + 1
    return {"chat_pages": len(pages), "chat_renderers": len(per), "chat_renderer_pids": sorted(per),
            "pages_per_renderer": sorted(per.values(), reverse=True)}


def evaluate(app, browser: int, expression: str) -> tuple[str | None, str | None]:
    """`expression`'s string value in the page's main world, or (None, error)."""
    reply = call(app, "debug.cef_page_devtools", {"browser": browser, "method": "Runtime.evaluate",
                                                  "params": {"expression": expression, "returnByValue": True}}, 40)
    if reply.get("error"):
        return None, str(reply["error"])[:200]
    try:
        result = json.loads(reply.get("result") or "{}")
    except ValueError:
        return None, "unreadable DevTools reply"
    if result.get("exceptionDetails"):
        return None, "exception"
    value = (result.get("result") or {}).get("value")
    return (None if value is None else str(value)), None


def crash(app) -> dict:
    """Marks every chat page, kills the renderer with the most chat pages, and reads the marks again."""
    pages = chat_pages(app)
    if len(pages) < MIN_PAGES or any(p["renderer"] is None for p in pages):
        print(f"chat-renderer-crash: setup: {len(pages)} live chat pages (need {MIN_PAGES}), "
              f"{sum(1 for p in pages if p['renderer'] is None)} with no renderer pid", file=sys.stderr)
        return {"setup_failed": True, "pages": pages, "pass": False}
    mark = uuid.uuid4().hex
    for page in pages:
        value, error = evaluate(app, page["browser"], f"window.__chatRendererCrashMark = {json.dumps(mark)}")
        if value != mark:
            print(f"chat-renderer-crash: setup: could not mark page {page['browser']}: {error or value}", file=sys.stderr)
            return {"setup_failed": True, "pages": pages, "pass": False}
    counts: dict[int, int] = {}
    for page in pages:
        counts[page["renderer"]] = counts.get(page["renderer"], 0) + 1
    victim = max(counts, key=lambda pid: counts[pid])
    print(f"CHAT-RENDERERS phase=kill pages={len(pages)} renderers={len(counts)} victim_pid={victim} "
          f"victim_pages={counts[victim]} pages_per_renderer={sorted(counts.values(), reverse=True)}", flush=True)
    os.kill(victim, signal.SIGKILL)
    # The killed renderer's pages reload: none is on the victim any more and each answers in its new renderer.
    # Then the page-to-renderer map settles, so a page another renderer lost late is in the read below.
    victims = [p["browser"] for p in pages if p["renderer"] == victim]

    def reloaded_all():
        now = {p["browser"]: p["renderer"] for p in chat_pages(app)}
        if any(now.get(b) in (None, victim) for b in victims):
            return False
        return all(evaluate(app, b, "1")[1] is None for b in victims)

    if not wait_until(reloaded_all, f"the {len(victims)} pages of the killed renderer to load again",
                      timeout=SETTLE_S, interval=0.5, raise_on_timeout=False):
        safe_print(f"chat-renderer-crash: the killed renderer's pages did not all load again in {SETTLE_S} s", file=sys.stderr)
    wait_stable(lambda: json.dumps(renderers(app), sort_keys=True), "the chat pages per renderer after the kill",
                timeout=20, interval=0.5, reads=4, raise_on_timeout=False)
    reloaded, elsewhere = [], []
    for page in pages:
        value, error = evaluate(app, page["browser"], "String(window.__chatRendererCrashMark)")
        if value == mark:
            continue
        reloaded.append(page["browser"])
        if page["renderer"] != victim:
            elsewhere.append({"browser": page["browser"], "renderer": page["renderer"], "read": value, "error": error})
    result = {"pages": len(pages), "renderers": len(counts), "victim_pid": victim, "victim_pages": counts[victim],
              "reloaded": len(reloaded), "kept": len(pages) - len(reloaded), "reloaded_outside_victim": elsewhere,
              "pages_after": len(chat_pages(app)), "cap": CAP}
    result["pass"] = len(reloaded) <= CAP and not elsewhere
    print(f"CHAT-RENDERERS phase=crash pages={len(pages)} reloaded={len(reloaded)} kept={result['kept']} cap={CAP} "
          f"reloaded_outside_victim={len(elsewhere)} pages_after={result['pages_after']} "
          f"result={'PASS' if result['pass'] else 'FAIL'}", flush=True)
    return result
