"""The chrome.bookmarks bridge (plans/cmux-next/bookmarks.md section 4, cx-d0d.37).

Run after the MV3 auto phase, in the test extension's service worker:

  bookmarks / cmux_to_chrome      a bookmark cmux adds (bookmark.add) is in
                                  chrome.bookmarks, on the Bookmarks bar
  bookmarks / chrome_to_cmux      a bookmark the extension creates in a folder
                                  it creates is in cmux's tree (bookmark.list)
  bookmarks / chrome_remove_to_cmux  removeTree of that folder removes both
                                  from cmux

An engine without the bridge (fork API < 22) records them as unsupported.
"""
import json
import time

BRIDGE_API = 22


def poll(probe, timeout=10):
    deadline = time.monotonic() + timeout
    value = probe()
    while not value and time.monotonic() < deadline:  # bounded wait for the app's own state
        time.sleep(0.25)
        value = probe()
    return value


def run(runner, extension_id):
    tests = ("cmux_to_chrome", "chrome_to_cmux", "chrome_remove_to_cmux")
    windows = (runner.app.call("debug.cef").get("result") or {}).get("windows") or {}
    fork_api = int(windows.get("fork_api") or 0)
    if fork_api < BRIDGE_API:
        for test in tests:
            runner.note("mv3", "bookmarks", test, "unsupported", f"fork API {fork_api} has no bridge (needs {BRIDGE_API})")
        return
    worker = runner.sw_session(extension_id)
    if not worker:
        runner.note("mv3", "bookmarks", tests[0], "fail", "no MV3 service worker")
        return
    stamp = str(int(time.time() * 1000))

    def cmux(text):
        listed = runner.app.call("bookmark.list", {"profile": "default", "text": text}).get("result") or {}
        return listed.get("bookmarks") or []

    def chrome(title):
        return worker.evaluate(f"chrome.bookmarks.search({{title: {json.dumps(title)}}})"
                               ".then((r) => r.map((n) => ({id: n.id, parentId: n.parentId, url: n.url})))") or []

    try:
        title = f"cxt cmux mark {stamp}"
        url = f"https://example.com/cmux-{stamp}"
        added = runner.app.call("action.run", {"action": "bookmark.add",
                                               "args": {"url": url, "title": title, "profile": "default"}})
        found = poll(lambda: chrome(title))
        # "1" is Chromium's Bookmarks bar node.
        ok = bool(found) and found[0].get("url") == url and found[0].get("parentId") == "1"
        runner.note("mv3", "bookmarks", "cmux_to_chrome", "pass" if ok else "fail",
                    json.dumps(found)[:200] if found else f"not in chrome.bookmarks ({json.dumps(added)[:120]})")
        runner.app.call("action.run", {"action": "bookmark.remove", "args": {"bookmark": url, "profile": "default"}})

        folder_title, mark_title = f"cxt bridge folder {stamp}", f"cxt bridge mark {stamp}"
        folder = worker.evaluate(f"chrome.bookmarks.create({{title: {json.dumps(folder_title)}}}).then((n) => n.id)")
        worker.evaluate(f"chrome.bookmarks.create({{parentId: {json.dumps(folder)}, title: {json.dumps(mark_title)},"
                        f" url: 'https://example.com/chrome-{stamp}'}})")
        mark = poll(lambda: [n for n in cmux(mark_title) if n.get("path", "").endswith(folder_title)])
        runner.note("mv3", "bookmarks", "chrome_to_cmux", "pass" if mark else "fail",
                    json.dumps(mark)[:200] if mark else f"cmux has {json.dumps(cmux(mark_title))[:160]}")

        worker.evaluate(f"chrome.bookmarks.removeTree({json.dumps(folder)})")
        gone = poll(lambda: not cmux(mark_title) and not cmux(folder_title))
        # The folder must still be gone in Chromium: cmux's next sync did not bring it back.
        time.sleep(1.0)
        back = chrome(folder_title)
        runner.note("mv3", "bookmarks", "chrome_remove_to_cmux", "pass" if gone and not back else "fail",
                    "" if gone and not back else f"cmux {json.dumps(cmux(mark_title))[:120]}, chrome {json.dumps(back)[:80]}")
    finally:
        worker.close()
