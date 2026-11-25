#!/usr/bin/env python3
"""Recent pages with site icons for a bench session: held-new-tab.py --recent-sites N --recent-pages M.

A New Tab page lists the pages that the person visited last, each with its site's icon. For that list the app
sorts its history, looks for each site's icon among the open tabs of each workspace, and encodes each icon that it
has. A session that the maker made has no history and no icon, so none of that work is in a key's time. This
module gives the session M visited pages on N sites:

  - `Sites`: one server thread on N loopback ports (a site is a scheme, a host and a port). `/p/K` is a small page
    with a title and an icon link, `/favicon.ico` is a PNG of 64 x 64 pixels made here. No network.
  - One Chromium tab in one more workspace, on screen. The tab opens the first page through the app's own action.
    Each page asks its own server for its next address after its `load` event, and the server holds the answer
    until `visit_all` gives it: the page then goes there by itself. So one tab makes the M loads, and the M visits
    are in an order that the tool knows.
  - The sign of each visit is the app's own list (`debug.new_tab state`, `omnibar_history`: what a New Tab page
    opened now would list): the visit's address is its newest page and has an icon.
  - Then the workspace is closed, so no open tab shows a site, and the list is read one more time (`judge`).
  - After the last row the tool reads the list ONE time more (`after_rows`): a list that has less pages of the
    sites, or less icons, than after the close makes the option invalid for the rows.

The order (`plan`): page 0 of each site, then page 1 of each site, and so on. The last N visits are N sites.

What this does NOT give: a fetch from the network, the decode of a large icon, a site with many icons. Each read
of the list runs the work that a New Tab page runs for it, so the app's icon store is warm before the first key.
"""
import http.server
import os
import selectors
import struct
import threading
import time
import zlib
from urllib.parse import parse_qs, urlsplit

ICON_SIDE = 64
HOST = "127.0.0.1"
# The app's list has 40 pages at most (`AgentPaneOmnibar.maximumEntries`), and `judge` needs each site in it.
MOST_SITES = 40
LIMITS = (
    "the sites are loopback pages with one icon of 64 x 64 pixels each: a key's time has the sort of the history, the scan "
    "for each site's icon and the encode of each kept icon, NOT a fetch from the network and NOT the decode of a large icon",
    "the app's icon store is warm at the first key: each read of the state runs the work that a New Tab page runs for "
    "its list (the read can start a load of an icon that the store does not have, and it lists the palette's actions), "
    "and the option made `state_reads` of them: its reads before the rows and one read after the last row",
    "the pages' workspace is closed before the rows: no open tab shows a site; the closed page can be in the New Tab "
    "page's list of closed tabs, with its icon",
    "the app's list is judged before the rows and one time after the last row, NOT at each key: a page or an icon that "
    "the list lost and got back between the 2 reads is not seen",
)


def icon_png(site, side=ICON_SIDE):
    """The icon of site number `site`: a PNG of `side` x `side` pixels, RGBA, another picture for each site."""
    seed, rows = (site * 2654435761 + 12345) & 0xFFFFFFFF, []
    red, green, blue = 64 + seed % 160, 64 + (seed >> 8) % 160, 64 + (seed >> 16) % 160
    middle, reach = (side - 1) / 2, (side / 2 - 2) ** 2
    for y in range(side):
        row = bytearray([0])  # the filter of the row: none
        for x in range(side):
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            grain = (seed >> 16) & 15
            inside = (x - middle) ** 2 + (y - middle) ** 2 <= reach
            row += bytes(((red + x + grain) & 255, (green + y + grain) & 255, (blue + grain) & 255, 255 if inside else 0))
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    head = struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")


def page_html(site, page):
    """Page `page` of site `site`: a title, the icon link, and the script that asks for the page's next address."""
    return (f'<!doctype html><meta charset="utf-8"><title>Recent site {site}, page {page}</title>'
            '<link rel="icon" type="image/png" href="/favicon.ico">'
            f"<p>Recent site {site}, page {page}</p>"
            '<script>addEventListener("load",()=>{fetch("/next?at="+encodeURIComponent(location.pathname),{cache:"no-store"})'
            ".then(r=>r.text()).then(u=>{if(u)location.href=u}).catch(()=>{})})</script>").encode()


def plan(sites, pages):
    """The M visits in their order, each (site, page): page 0 of each site, then page 1 of each site, and so on."""
    return [(index % sites, index // sites) for index in range(pages)] if sites > 0 else []


class Sites:
    """`count` sites, each a port of 127.0.0.1, served by one thread; each request is answered on a thread of its own."""

    def __init__(self, count):
        self.count, self.servers, self.thread, self.lock = count, [], None, threading.Lock()
        self.icons = [icon_png(site) for site in range(count)]
        self.requests = {"page": 0, "icon": 0, "next": 0, "other": 0}
        self.asked, self.waiter, self.closed = {}, None, False
        self.wake_read, self.wake_write = os.pipe()

    def start(self):
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802  the standard library's name
                owner.answer(self, self.server.site)

            def log_message(self, *args):
                pass

        for site in range(self.count):
            server = http.server.ThreadingHTTPServer((HOST, 0), Handler)
            server.daemon_threads, server.site = True, site
            self.servers.append(server)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        return self

    def serve(self):
        with selectors.DefaultSelector() as ready:
            for server in self.servers:
                ready.register(server, selectors.EVENT_READ)
            ready.register(self.wake_read, selectors.EVENT_READ)
            while True:
                for key, _ in ready.select():
                    if key.fileobj == self.wake_read:
                        return
                    key.fileobj.handle_request()

    def url(self, site, page):
        return f"http://{HOST}:{self.servers[site].server_address[1]}/p/{page}"

    def urls(self, pages):
        return [self.url(site, page) for site, page in plan(self.count, pages)]

    def ports(self):
        return [server.server_address[1] for server in self.servers]

    def answer(self, request, site):
        path = urlsplit(request.path)
        if path.path == "/favicon.ico":
            self.send(request, "icon", "image/png", self.icons[site])
        elif path.path.startswith("/p/") and path.path[3:].isdigit():
            self.send(request, "page", "text/html; charset=utf-8", page_html(site, int(path.path[3:])))
        elif path.path == "/next":
            at = (parse_qs(path.query).get("at") or [""])[0]
            self.send(request, "next", "text/plain; charset=utf-8", self.hold(f"http://{HOST}:{self.servers[site].server_address[1]}{at}").encode())
        else:
            self.send(request, "other", "text/plain; charset=utf-8", b"", status=404)

    def send(self, request, kind, content_type, body, status=200):
        with self.lock:
            self.requests[kind] += 1
        try:
            request.send_response(status)
            request.send_header("Content-Type", content_type)
            request.send_header("Content-Length", str(len(body)))
            if kind != "icon":
                request.send_header("Cache-Control", "no-store")
            request.end_headers()
            request.wfile.write(body)
        except OSError:
            pass  # the page left before its answer: its next visit, or the close of its tab

    def event(self, url):
        with self.lock:
            return self.asked.setdefault(url, threading.Event())

    def hold(self, url):
        """The page at `url` asks for its next address: it waits here until `give` or `close`. A page that asked
        before it and still waits gets an empty answer (it stays where it is)."""
        mine = {"event": threading.Event(), "url": ""}
        with self.lock:
            old, self.waiter = self.waiter, None if self.closed else mine
        if old:
            old["event"].set()
        self.event(url).set()
        if not self.closed:
            mine["event"].wait()
        return mine["url"]

    def wait_asked(self, url, seconds):
        """True when the page at `url` asked for its next address (its `load` event came), at most `seconds` from now."""
        return self.event(url).wait(max(0.0, seconds))

    def give(self, url):
        """Gives `url` to the page that waits. False when no page waits."""
        with self.lock:
            waiter, self.waiter = self.waiter, None
        if waiter:
            waiter["url"] = url
            waiter["event"].set()
        return bool(waiter)

    def close(self):
        """Ends the thread and the ports. A page that still waits gets an empty answer."""
        with self.lock:
            waiter, self.waiter, self.closed = self.waiter, None, True
        if waiter:
            waiter["event"].set()
        if self.thread:
            os.write(self.wake_write, b"x")
            self.thread.join(5)  # a daemon thread: one that is held in a request must not hang the tool
            self.thread = None
        for server in self.servers:
            server.server_close()
        for end in (self.wake_read, self.wake_write):
            try:
                os.close(end)
            except OSError:
                pass
        self.wake_read = self.wake_write = -1


def listed(state):
    """The list of a New Tab page from the reply of `debug.new_tab state`: [{url, icon}], or None when the reply
    has no such list (an app before this option)."""
    pages = state.get("omnibar_history") if isinstance(state, dict) else None
    return [page for page in pages if isinstance(page, dict)] if isinstance(pages, list) else None


def visit_all(urls, open_first, sites, read, seconds, visit_seconds=20.0, clock=time.monotonic, pause=time.sleep):
    """Each address of `urls` in turn in one tab: `open_first(url)` opens the first one (it gives the app's refusal
    or None) and `sites.give` sends the page to each next one. A visit is seen when its page asked for its next
    address and the app's list (`read()`, as `listed` gives it) has the address as its newest page with an icon.
    {seen, state_reads, stopped: why the visits ended early or None, newest: the list of the last read}."""
    end, seen, reads, newest = clock() + seconds, 0, 0, None

    def result(stopped=None):
        return {"seen": seen, "state_reads": reads, "stopped": stopped, "newest": newest}

    for index, url in enumerate(urls):
        name = f"visit {index + 1} of {len(urls)} ({url})"
        if index == 0:
            refusal = open_first(url)
            if refusal:
                return result(f"{name}: the app did not open the tab: {refusal}")
        elif not sites.give(url):
            return result(f"{name}: the page before it does not wait for its next address")
        bound = min(end, clock() + visit_seconds)
        if not sites.wait_asked(url, bound - clock()):
            return result(f"{name}: the page did not load (no `load` event in {bound_words(bound, end, seconds, visit_seconds)})")
        while True:
            reads += 1
            newest = read()
            if newest is None:
                return result(f"{name}: the app's state has no `omnibar_history` (an app before this option)")
            first = newest[0] if newest else {}
            if first.get("url") == url and first.get("icon"):
                break
            if clock() >= bound:
                what = "has the address with NO icon" if first.get("url") == url else f"does not have the address as its newest page (that is {first.get('url')})"
                return result(f"{name}: the app's list {what} after {bound_words(bound, end, seconds, visit_seconds)}")
            pause(0.1)
        seen += 1
    return result()


def bound_words(bound, end, seconds, visit_seconds):
    return f"the option's {seconds:.0f} s" if bound >= end else f"{visit_seconds:.0f} s"


def judge(urls, pages, sites):
    """What the app's list (`pages`, as `listed` gives it) has of the visits `urls`: {history: its pages that are
    visits, icons: those with an icon, newest_in_order: how many of its first pages are the last visits, newest
    first, faults}. No fault when its first `sites` pages or more are the last visits in their order, each with an
    icon: then a New Tab page sorts the history, and scans for and encodes one icon for each of `sites` sites."""
    if pages is None:
        return {"history": 0, "icons": 0, "newest_in_order": 0, "faults": ["the app's state has no `omnibar_history`"]}
    known, want = set(urls), list(reversed(urls))
    mine = [page for page in pages if page.get("url") in known]
    in_order = 0
    for page, url in zip(pages, want):
        if page.get("url") != url:
            break
        in_order += 1
    with_icon, faults = sum(1 for page in pages[:in_order] if page.get("icon")), []
    need = min(sites, len(urls))
    if in_order < need:
        faults.append(f"the newest {need} pages of the app's list are not the last {need} visits in their order (the first {in_order} are)")
    if with_icon < in_order:
        faults.append(f"{in_order - with_icon} of those {in_order} pages have no icon")
    return {"history": len(mine), "icons": sum(1 for page in mine if page.get("icon")), "newest_in_order": in_order, "faults": faults}


def seed(builder, state, sites, pages, seconds, wait, clock=time.monotonic, make_sites=Sites, pause=time.sleep):
    """The option's whole work on a running app, through the session helper `builder` (perf-stress-session.py's
    `Stress`): the sites, one more workspace on screen with one Chromium tab, the visits, the close of that
    workspace, and what the app's list has before and after the close. `state()` is `debug.new_tab state`.
    The report's `recent_pages`: `invalid` names each reason for which the rows are NOT rows of a session with
    recent pages."""
    began, reads = clock(), [0]
    report = {"asked": {"sites": sites, "pages": pages}, "icon": None, "ports": None, "visits_seen": 0, "state_reads": 0,
              "requests": None, "before_the_close": None, "after_the_close": None, "after_the_rows": None, "seconds": None,
              "invalid": [], "limits": list(LIMITS)}
    if sites < 1 or sites > MOST_SITES or pages < sites:
        report["invalid"].append(f"asked {sites} sites and {pages} pages: the option needs 1 site or more, {MOST_SITES} sites at most "
                                 f"(the app's list has {MOST_SITES} pages at most) and a page or more for each site")
        return report

    def read():
        reads[0] += 1
        return listed(state())

    server = workspace = None
    try:
        server = make_sites(sites).start()
        sizes = sorted(len(icon) for icon in server.icons)
        report["icon"] = {"pixels": f"{ICON_SIDE} x {ICON_SIDE}", "png_bytes_least": sizes[0], "png_bytes_most": sizes[-1]}
        urls, report["ports"] = server.urls(pages), server.ports()
        workspace = builder.new_workspace()
        if not workspace:
            raise RuntimeError("no workspace came for the pages")
        builder.show(workspace)
        panes = builder.panes(builder.workspace(workspace))
        tabs = builder.settled_tabs(workspace, panes[0]["id"]) if panes else []
        beside = next((tab for tab in tabs if tab.get("selected")), tabs[-1] if tabs else None)
        if not beside:
            raise RuntimeError("the workspace for the pages has no tab to open a page beside")

        def open_first(url):
            reply = builder.action("openBrowser.chromium", {"url": url}, target=f"tab:{beside['id']}")
            return str(reply["error"])[:200] if isinstance(reply, dict) and reply.get("error") else None

        visits = visit_all(urls, open_first, server, read, seconds, clock=clock, pause=pause)
        report["visits_seen"] = visits["seen"]
        if visits["stopped"]:
            report["invalid"].append(visits["stopped"])
        before = judge(urls, visits["newest"] if visits["seen"] == len(urls) else read(), sites)
        report["before_the_close"] = {key: before[key] for key in ("history", "icons", "newest_in_order")}
        builder.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
        if not wait(lambda: not builder.workspace(workspace), 20, 0.1):
            report["invalid"].append("the pages' workspace did not close in 20 s: an open tab can still show a site")
        workspace = None
        after = judge(urls, read(), sites)
        report["after_the_close"] = {key: after[key] for key in ("history", "icons", "newest_in_order")}
        report["invalid"] += [f"after the close: {fault}" for fault in after["faults"]]
    except Exception as error:  # noqa: BLE001  the report says why, and the rows still run with their label
        report["invalid"].append(f"the option stopped: {error!r}")
        if workspace:
            try:
                builder.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
            except Exception:  # noqa: BLE001  the first reason is in the report
                pass
    finally:
        if server:
            report["requests"] = dict(server.requests)
            server.close()
    report["state_reads"], report["seconds"] = reads[0], round(clock() - began, 1)
    return report


def after_rows(report, pages):
    """ONE more judge after the last row, on `report` (what `seed` gave): `pages` is the app's list then, as `listed`
    gives it. `after_the_rows` gets {history: the list's pages of the option's sites (by the port of the address),
    icons: those with an icon}. A list with less of either than after the close, or no list, adds a reason to
    `invalid`: the list of a later key did not have what the option made. Gives the new reasons. An option that had
    no read after its close gets no judge. The read is counted in `state_reads`."""
    report["state_reads"] = (report.get("state_reads") or 0) + 1
    was = report.get("after_the_close")
    if not was or report.get("ports") is None:
        return []
    if pages is None:
        why = "the app's state has no `omnibar_history`"
    else:
        marks = tuple(f"http://{HOST}:{port}/p/" for port in report["ports"])
        mine = [page for page in pages if str(page.get("url")).startswith(marks)]
        now = report["after_the_rows"] = {"history": len(mine), "icons": sum(1 for page in mine if page.get("icon"))}
        if now["history"] >= was["history"] and now["icons"] >= was["icons"]:
            return []
        why = (f"the app's list has {now['history']} pages of the sites, {now['icons']} with an icon; after the close it had "
               f"{was['history']} pages, {was['icons']} with an icon")
    report["invalid"].append(f"after the rows: {why}")
    return [f"after the rows: {why}"]
