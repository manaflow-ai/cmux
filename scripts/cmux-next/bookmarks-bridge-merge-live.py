#!/usr/bin/env python3
"""Live check: the chrome.bookmarks bridge merges, never replaces (cx-d0d.92).

  scripts/cmux-next/bookmarks-bridge-merge-live.py --tag <tag> [--out DIR]

Needs a tagged Debug build whose CEF has the bridge (fork API >= 22, CEF
cmux.24 or newer); on an older engine it exits 2 (nothing to check).

1. Launch with a fresh Chromium profile and fresh daemon state, add a cmux
   bookmark on the Bookmarks bar (action bookmark.add), quit. No Chromium
   tab opens, so Chromium never loads the profile in this run.
2. Write the default profile's Chromium `Bookmarks` file as an older run
   left it: the same URL as cmux's bookmark (another guid) and a bookmark
   only Chromium has, both on the Bookmarks bar.
3. Launch again (state kept), open a Chromium tab: the store loads, the
   daemon merges its file (merge-bookmarks), then the bridge syncs.
4. cmux's tree (bookmark.list) has the Chromium-only bookmark once, on the
   Bookmarks bar, and the shared URL once; Chromium's own file, once it
   saves after the sync (the seed has no checksum, a save writes one), has
   both, each once.

GUI host only (no real input: socket reads). The app is quit and the tag's
daemons stopped at the end. Exits 1 when a check fails.
"""
import argparse
import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext_e2e.app import TaggedApp  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402

DEFAULT_PROFILE_DIR = "Profile-8E5C0D1F-2B7A-4F3C-9A61-5D2E7B0C4A11"
SHARED_URL = "https://example.com/cxd092-shared"
ONLY_URL = "https://example.com/cxd092-only-chromium"
BRIDGE_API = 22

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="bookmarks-merge-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.5)
    return None


def result(reply):
    return reply.get("result") or {}


def cmux_nodes(app):
    return result(app.call("bookmark.list", {"profile": "default"})).get("bookmarks") or []


def chromium_file(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def chromium_urls(data):
    found = []

    def walk(node):
        if node.get("type") == "url":
            found.append(node.get("url"))
        for child in node.get("children") or []:
            walk(child)

    for root in ((data or {}).get("roots") or {}).values():
        if isinstance(root, dict):
            walk(root)
    return found


def seed(path):
    """A Chromium Bookmarks file with the shared URL and one Chromium-only bookmark."""
    added = str((int(time.time()) + 11_644_473_600) * 1_000_000)

    def url(node_id, guid, name, href):
        return {"date_added": added, "date_last_used": "0", "guid": guid, "id": node_id, "name": name,
                "type": "url", "url": href}

    def root(node_id, guid, name, children):
        return {"children": children, "date_added": added, "date_last_used": "0", "date_modified": "0",
                "guid": guid, "id": node_id, "name": name, "type": "folder"}

    data = {"checksum": "", "version": 1, "roots": {
        "bookmark_bar": root("1", "0bc5d13f-2cba-5d74-951f-3f233fe6c908", "Bookmarks bar", [
            url("4", "5d7b5a5e-0c1e-4b9a-9d2c-7c1f0e000001", "Shared in Chromium", SHARED_URL),
            url("5", "5d7b5a5e-0c1e-4b9a-9d2c-7c1f0e000002", "Only Chromium", ONLY_URL)]),
        "other": root("2", "82b081ec-3dd3-529c-8475-ab6c344590dd", "Other bookmarks", []),
        "synced": root("3", "4cf2e351-0e85-532b-bb37-df045d8f8d0f", "Mobile bookmarks", [])}}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(data, handle)


def normalized(href):
    return (href or "").rstrip("/")


app = TaggedApp(opts.tag, fresh_profile=True, log_dir=opts.out)
teardown = TagTeardown(app.path)
teardown.install()
store = os.path.join(app.chromium_root, DEFAULT_PROFILE_DIR)
bookmarks_file = os.path.join(store, "Bookmarks")
try:
    # 1. cmux's bookmark, with no Chromium tab.
    app.launch()
    added = app.call("action.run", {"action": "bookmark.add", "args": {
        "url": SHARED_URL, "title": "Shared in cmux", "profile": "default", "folder": "bar"}})
    check(not added.get("error"), f"cmux adds a bookmark ({json.dumps(added)[:160]})")
    shared = wait(lambda: [n for n in cmux_nodes(app) if normalized(n.get("url")) == SHARED_URL], 15)
    check(bool(shared), "cmux lists its bookmark")
    app.quit()
    check(not os.path.exists(bookmarks_file), "Chromium never loaded the profile in the first run")

    # 2. Chromium's file as an older run left it.
    seed(bookmarks_file)

    # 3. The store loads: merge, then sync.
    app.fresh_profile = False
    app.launch()
    app.open_chromium("about:blank")
    fork_api = int(((result(app.call("debug.cef")).get("windows") or {}).get("fork_api")) or 0)
    print(f"fork API {fork_api}", flush=True)
    if fork_api < BRIDGE_API:
        print(f"this engine has no bookmarks bridge (needs fork API {BRIDGE_API}); nothing to check", flush=True)
        sys.exit(2)

    # 4. cmux keeps the Chromium-only bookmark and does not duplicate the shared one.
    def merged_tree():
        nodes = cmux_nodes(app)
        return nodes if any(normalized(n.get("url")) == ONLY_URL for n in nodes) else None

    nodes = wait(merged_tree, 30) or cmux_nodes(app)
    app.dump("cmux-bookmarks.json", nodes)
    only = [n for n in nodes if normalized(n.get("url")) == ONLY_URL]
    both = [n for n in nodes if normalized(n.get("url")) == SHARED_URL]
    check(len(only) == 1, f"the Chromium-only bookmark survives the first launch, once ({json.dumps(only)[:200]})")
    check(all(n.get("path", "").lower().startswith("bar") or n.get("parent") == "bar" for n in only),
          f"it stays on the Bookmarks bar ({json.dumps(only)[:200]})")
    check(len(both) == 1, f"a bookmark in both lists is not duplicated ({json.dumps(both)[:200]})")

    # Chromium's model follows: its file, saved again after the sync, has each URL once.
    # The seed has an empty checksum; Chromium writes one when it saves the model.
    saved = wait(lambda: (chromium_file(bookmarks_file) or {}).get("checksum"), 30)
    check(bool(saved), "Chromium saves its bookmarks after the sync")
    urls = [normalized(u) for u in chromium_urls(chromium_file(bookmarks_file))]
    urls = urls if saved and urls.count(ONLY_URL) == 1 and urls.count(SHARED_URL) == 1 else None
    with open(os.path.join(opts.out, "chromium-Bookmarks.json"), "w") as handle:
        json.dump(chromium_file(bookmarks_file), handle, indent=2)
    check(bool(urls), "Chromium's bookmarks keep both URLs, each once "
          f"({[normalized(u) for u in chromium_urls(chromium_file(bookmarks_file))]})")
finally:
    try:
        app.call("action.run", {"action": "quitEndSessions"})
    except Exception:  # noqa: BLE001 - the app may be gone already
        pass
    app.quit()
    teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
