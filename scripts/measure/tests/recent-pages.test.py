#!/usr/bin/env python3
"""scripts/measure/recent-pages.py: the sites, the order of the visits, the sign of a visit and the verdict.

A session that the maker made has no visited page and no site icon, so a New Tab page of it has no history to sort
and no icon to look for or to encode. The option `--recent-sites N --recent-pages M` of held-new-tab.py gives the
session M visits on N loopback sites in one tab, and it reads the app's own list of recent pages as the sign of
each visit and as the proof at the end.

What these rows hold: the icon is a PNG of 64 x 64 pixels and each site has another one; a page has its title, its
icon link and the ask for its next address; the last N visits are N sites; the server gives a page, an icon and a
held next address on each port, and a page that waits gets the address that the tool gives; a visit is seen only
when the app's list has its address as the newest page WITH an icon; the visits stop with their reason when the
app refuses the tab, when a page does not load, when the list is not there and when the icon does not come; the
verdict has a fault when the newest pages are not the last visits or when one has no icon; `seed` opens ONE tab,
closes its workspace and reads the list before and after the close.

No app and no browser: the page's side is this test's own requests to the real server on loopback, and the app is
a small model of its list. So this proves the tool's own logic, NOT that a Chromium tab of the app loads these
pages, NOT that the app keeps an icon, and NOT what the list costs.
Run: python3 -I scripts/measure/tests/recent-pages.test.py"""
import importlib.util, os, struct, threading, unittest, urllib.error, urllib.request, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location("recent_pages_under_test", os.path.join(HERE, "..", "recent-pages.py"))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


def get(url):
    with urllib.request.urlopen(url, timeout=30) as reply:
        return reply.status, reply.headers.get("Content-Type"), reply.read()


def png_size(data):
    """(width, height, bit depth, color type) of a PNG whose chunks have right checksums; the count of its pixels' bytes."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n", data[:8]
    at, head, pixels = 8, None, b""
    while at < len(data):
        (length,), kind = struct.unpack(">I", data[at:at + 4]), data[at + 4:at + 8]
        body = data[at + 8:at + 8 + length]
        assert struct.unpack(">I", data[at + 8 + length:at + 12 + length])[0] == zlib.crc32(kind + body) & 0xFFFFFFFF, kind
        if kind == b"IHDR":
            head = struct.unpack(">IIBB", body[:10])
        if kind == b"IDAT":
            pixels += body
        at += 12 + length
    return head, len(zlib.decompress(pixels))


class Icon(unittest.TestCase):
    def test_the_icon_is_a_png_of_64_by_64_pixels_with_each_pixel(self):
        head, raw = png_size(M.icon_png(0))
        self.assertEqual(head, (64, 64, 8, 6))  # 8 bits, RGBA
        self.assertEqual(raw, 64 * (1 + 64 * 4))  # each row: its filter byte and 64 pixels of 4 bytes

    def test_each_site_has_another_icon_and_a_site_has_the_same_one_each_time(self):
        self.assertEqual(len({M.icon_png(site) for site in range(40)}), 40)
        self.assertEqual(M.icon_png(7), M.icon_png(7))

    def test_the_icon_is_not_a_flat_picture_of_some_bytes(self):
        # A real site icon of this size is some kB: the encode of a flat picture would be less work than a person's.
        self.assertGreater(min(len(M.icon_png(site)) for site in range(40)), 2000)


class Page(unittest.TestCase):
    def test_a_page_has_its_title_its_icon_link_and_the_ask_for_its_next_address(self):
        page = M.page_html(3, 2).decode()
        self.assertIn("<title>Recent site 3, page 2</title>", page)
        self.assertIn('<link rel="icon" type="image/png" href="/favicon.ico">', page)
        self.assertIn('addEventListener("load"', page)
        self.assertIn('fetch("/next?at="+encodeURIComponent(location.pathname)', page)
        self.assertIn("location.href=u", page)


class Plan(unittest.TestCase):
    def test_the_visits_go_through_page_0_of_each_site_then_page_1_of_each_site(self):
        self.assertEqual(M.plan(3, 7), [(0, 0), (1, 0), (2, 0), (0, 1), (1, 1), (2, 1), (0, 2)])

    def test_the_last_visits_of_40_sites_and_200_pages_are_40_sites(self):
        visits = M.plan(40, 200)
        self.assertEqual(len(visits), 200)
        self.assertEqual(len(set(visits)), 200)
        self.assertEqual(sorted(site for site, _ in visits[-40:]), list(range(40)))

    def test_no_site_gives_no_visit(self):
        self.assertEqual(M.plan(0, 5), [])


class Server(unittest.TestCase):
    def setUp(self):
        self.sites = M.Sites(3).start()
        self.addCleanup(self.sites.close)

    def test_each_site_is_a_port_of_its_own_with_its_page_and_its_icon(self):
        urls = self.sites.urls(6)
        self.assertEqual(len({url.rsplit("/p/", 1)[0] for url in urls}), 3)
        self.assertEqual([url.rsplit("/p/", 1)[1] for url in urls], ["0", "0", "0", "1", "1", "1"])
        for site in range(3):
            status, kind, body = get(self.sites.url(site, 1))
            self.assertEqual((status, kind, body), (200, "text/html; charset=utf-8", M.page_html(site, 1)))
            status, kind, body = get(self.sites.url(site, 1).rsplit("/p/", 1)[0] + "/favicon.ico")
            self.assertEqual((status, kind, body), (200, "image/png", M.icon_png(site)))
        self.assertEqual((self.sites.requests["page"], self.sites.requests["icon"]), (3, 3))

    def page_asks(self, url):
        """A page at `url` asks its server for its next address, as the page's script does: (what it got, its thread)."""
        got = []

        def ask():
            try:
                got.append(get(url.rsplit("/p/", 1)[0] + "/next?at=%2Fp%2F" + url.rsplit("/p/", 1)[1])[2])
            except OSError as error:
                got.append(error)

        page = threading.Thread(target=ask)
        page.start()
        self.addCleanup(page.join, 30)
        self.addCleanup(self.sites.close)  # first: a page that still waits is let go before the join
        return got, page

    def test_a_page_that_waits_gets_the_address_that_the_tool_gives(self):
        first, second = self.sites.url(0, 0), self.sites.url(1, 0)
        got, page = self.page_asks(first)
        self.assertTrue(self.sites.wait_asked(first, 30))  # the page's `load` event: it asked
        self.assertFalse(got)  # and it waits
        self.assertTrue(self.sites.give(second))
        page.join(30)
        self.assertEqual(got, [second.encode()])
        self.assertFalse(self.sites.give(second))  # no page waits now

    def test_a_page_that_did_not_ask_is_not_seen(self):
        self.assertFalse(self.sites.wait_asked(self.sites.url(2, 0), 0))

    def test_the_close_lets_a_page_that_waits_go_with_no_address(self):
        got, page = self.page_asks(self.sites.url(0, 0))
        self.assertTrue(self.sites.wait_asked(self.sites.url(0, 0), 30))
        self.sites.close()
        page.join(30)
        self.assertEqual(got, [b""])

    def test_another_path_is_no_page(self):
        with self.assertRaises(urllib.error.HTTPError) as refused:
            get(self.sites.url(0, 0).rsplit("/p/", 1)[0] + "/p/x")
        self.assertEqual(refused.exception.code, 404)

    def test_the_ports_are_those_of_the_addresses_in_the_order_of_the_sites(self):
        ports = getattr(self.sites, "ports", None)
        self.assertIsNotNone(ports, "the sites do not name their ports")
        self.assertEqual([f"http://127.0.0.1:{port}/p/0" for port in ports()], [self.sites.url(site, 0) for site in range(3)])


class ServerThread:
    """A thread of the server that does not end: each `join` and its limit."""

    def __init__(self):
        self.joins = []

    def join(self, timeout=None):
        self.joins.append(timeout)


class Close(unittest.TestCase):
    def test_the_close_waits_5_s_at_most_for_a_server_thread_that_does_not_end(self):
        sites, thread = M.Sites(1), ServerThread()
        sites.thread = thread
        sites.close()
        self.assertEqual(thread.joins, [5])  # no wait with no limit: a thread that is held in a request must not hang the tool


class App:
    """A small model of the app's list for one tab: a visit is in the list after `late` reads of the state, and its
    site's icon after `icon_late` more reads (None: never). `sites` stands for the server: a page waits when the
    tab is at it."""

    def __init__(self, late=0, icon_late=0, loads=True, has_list=True, refuses=None, limit=40):
        self.late, self.icon_late, self.loads, self.has_list, self.refuses, self.limit = late, icon_late, loads, has_list, refuses, limit
        self.history, self.icons, self.at, self.reads_at, self.reads, self.now, self.pauses = [], set(), None, 0, 0, 0.0, 0
        self.opened, self.given = [], []

    @staticmethod
    def site(url):
        return url.rsplit("/p/", 1)[0]

    def open_first(self, url):
        self.opened.append(url)
        if self.refuses:
            return self.refuses
        self.at, self.reads_at = url, 0
        return None

    def give(self, url):
        if self.at is None:
            return False
        self.given.append(url)
        self.at, self.reads_at = url, 0
        return True

    def wait_asked(self, url, seconds):
        return self.loads and self.at == url

    def read(self):
        self.reads += 1
        self.reads_at += 1
        if not self.has_list:
            return None
        if self.at and self.reads_at > self.late and self.at not in self.history:
            self.history.insert(0, self.at)
        if self.at and self.icon_late is not None and self.reads_at > self.late + self.icon_late:
            self.icons.add(self.site(self.at))
        return [{"url": url, "icon": self.site(url) in self.icons} for url in self.history[:self.limit]]

    def clock(self):
        return self.now

    def pause(self, seconds):
        self.pauses += 1
        self.now += seconds


URLS = [f"http://127.0.0.1:{9000 + site}/p/{page}" for site, page in ((0, 0), (1, 0), (0, 1), (1, 1))]


class Visits(unittest.TestCase):
    def visits(self, app, seconds=60.0):
        return M.visit_all(URLS, app.open_first, app, app.read, seconds, clock=app.clock, pause=app.pause)

    def test_each_visit_is_seen_in_its_order_in_one_tab(self):
        app = App()
        result = self.visits(app)
        self.assertEqual((result["seen"], result["stopped"], result["state_reads"]), (4, None, 4))
        self.assertEqual((app.opened, app.given), (URLS[:1], URLS[1:]))  # ONE tab: the first is opened, each other is given
        self.assertEqual([page["url"] for page in result["newest"]], list(reversed(URLS)))

    def test_a_visit_waits_for_its_address_and_for_its_icon_in_the_apps_list(self):
        app = App(late=2, icon_late=3)
        result = self.visits(app)
        self.assertEqual((result["seen"], result["stopped"]), (4, None))
        # Sites 0 and 1 wait for the address and the icon (6 reads each); a later page of a site waits for its address (3 reads).
        self.assertEqual(result["state_reads"], 6 + 6 + 3 + 3)
        self.assertEqual(app.pauses, result["state_reads"] - 4)

    def test_an_address_with_no_icon_is_not_a_seen_visit(self):
        app = App(icon_late=None)
        result = self.visits(app, seconds=5.0)
        self.assertEqual(result["seen"], 0)
        self.assertIn("visit 1 of 4", str(result["stopped"]))
        self.assertIn("has the address with NO icon", str(result["stopped"]))
        self.assertEqual(app.given, [])  # no next address goes to a page whose visit was not seen

    def test_a_page_that_does_not_load_stops_the_visits(self):
        result = self.visits(App(loads=False))
        self.assertEqual((result["seen"], result["state_reads"]), (0, 0))
        self.assertIn("the page did not load", str(result["stopped"]))

    def test_a_refused_tab_stops_the_visits_with_the_apps_words(self):
        result = self.visits(App(refuses="no Chromium in this build"))
        self.assertEqual(result["seen"], 0)
        self.assertIn("the app did not open the tab: no Chromium in this build", str(result["stopped"]))

    def test_an_app_with_no_list_stops_at_the_first_read(self):
        app = App(has_list=False)
        result = self.visits(app)
        self.assertEqual((result["seen"], result["state_reads"], app.pauses), (0, 1, 0))
        self.assertIn("has no `omnibar_history`", str(result["stopped"]))

    def test_an_address_that_is_not_the_newest_names_the_newest(self):
        app = App(late=10 ** 6)
        app.history = ["http://other/"]
        result = self.visits(app, seconds=1.0)
        self.assertIn("does not have the address as its newest page (that is http://other/)", str(result["stopped"]))

    def test_a_page_that_does_not_wait_for_its_next_address_stops_the_visits(self):
        app = App()

        class Deaf:
            """Sites whose page left: no page waits for an address."""
            wait_asked = staticmethod(app.wait_asked)

            @staticmethod
            def give(url):
                return False

        result = M.visit_all(URLS, app.open_first, Deaf, app.read, 60.0, clock=app.clock, pause=app.pause)
        self.assertEqual(result["seen"], 1)  # the first visit was seen; the second address found no page
        self.assertIn("visit 2 of 4", str(result["stopped"]))
        self.assertIn("the page before it does not wait for its next address", str(result["stopped"]))


def pages(urls, without=()):
    return [{"url": url, "icon": url not in without} for url in urls]


class Judge(unittest.TestCase):
    def test_the_last_visits_in_their_order_each_with_an_icon_have_no_fault(self):
        verdict = M.judge(URLS, pages(reversed(URLS)), 2)
        self.assertEqual(verdict, {"history": 4, "icons": 4, "newest_in_order": 4, "faults": []})

    def test_a_list_that_is_cut_at_the_sites_count_has_no_fault(self):
        self.assertEqual(M.judge(URLS, pages(list(reversed(URLS))[:2]), 2)["faults"], [])

    def test_a_page_with_no_icon_is_a_fault(self):
        verdict = M.judge(URLS, pages(reversed(URLS), without=URLS[2:3]), 2)
        self.assertEqual((verdict["history"], verdict["icons"]), (4, 3))
        self.assertEqual(verdict["faults"], ["1 of those 4 pages have no icon"])

    def test_two_visits_that_change_places_are_a_fault(self):
        swapped = [URLS[2], URLS[3], URLS[1], URLS[0]]
        verdict = M.judge(URLS, pages(swapped), 2)
        self.assertEqual(verdict["newest_in_order"], 0)
        self.assertIn("are not the last 2 visits in their order (the first 0 are)", " | ".join(verdict["faults"]))

    def test_a_page_of_another_visit_before_them_is_a_fault_and_is_not_counted(self):
        verdict = M.judge(URLS, pages(["http://other/"] + list(reversed(URLS))), 2)
        self.assertEqual((verdict["history"], verdict["newest_in_order"], len(verdict["faults"])), (4, 0, 1))

    def test_a_short_list_is_a_fault(self):
        self.assertEqual(len(M.judge(URLS, pages(list(reversed(URLS))[:1]), 2)["faults"]), 1)

    def test_no_list_is_a_fault(self):
        self.assertEqual(M.judge(URLS, None, 2)["faults"], ["the app's state has no `omnibar_history`"])

    def test_the_reply_of_the_state_gives_the_list_or_none(self):
        self.assertEqual(M.listed({"omnibar_history": [{"url": "a", "icon": True}, "x"]}), [{"url": "a", "icon": True}])
        self.assertIsNone(M.listed({"omnibar_tabs": []}))
        self.assertIsNone(M.listed(None))


class FakeSites:
    """The server's part of `seed` on the model: the same addresses as URLS."""

    def __init__(self, app, count):
        self.app, self.count, self.icons, self.requests, self.closed = app, count, [b"12345", b"123"], {"page": 4, "icon": 2, "next": 4, "other": 0}, False

    def start(self):
        return self

    def urls(self, count):
        return URLS[:count]

    def ports(self):
        return [9000, 9001][:self.count]

    def give(self, url):
        return self.app.give(url)

    def wait_asked(self, url, seconds):
        return self.app.wait_asked(url, seconds)

    def close(self):
        self.closed = True


class Builder:
    """The session helper on the model: its calls in their order."""

    def __init__(self, app, closes=True, icons_stay=True):
        self.app, self.closes, self.icons_stay, self.calls, self.open = app, closes, icons_stay, [], set()

    def new_workspace(self):
        self.calls.append("new_workspace")
        self.open.add("ws9")
        return "ws9"

    def show(self, workspace):
        self.calls.append(f"show {workspace}")

    def workspace(self, ident):
        return {"id": ident, "screens": [{"panes": [{"id": "pane9"}]}]} if ident in self.open else None

    @staticmethod
    def panes(workspace):
        return [pane for screen in (workspace or {}).get("screens") or [] for pane in screen.get("panes") or []]

    def settled_tabs(self, workspace, pane, seconds=20):
        return [{"id": "tab9", "kind": "terminal", "selected": True}]

    def action(self, name, args=None, target=None, focus=True, timeout=120, settle=0.0):
        self.calls.append((name, args, target, focus))
        if name == "openBrowser.chromium":
            refusal = self.app.open_first(args["url"])
            return {"error": refusal} if refusal else {}
        if name == "closeWorkspace" and self.closes:
            self.open.discard(target.split(":", 1)[1])
            self.app.at = None
            if not self.icons_stay:
                self.app.icons.clear()
        return {}


class Seed(unittest.TestCase):
    def seed(self, app, builder=None, sites=2, pages=4):
        builder = builder or Builder(app)
        made = []

        def make(count):
            made.append(FakeSites(app, count))
            return made[-1]

        report = M.seed(builder, lambda: {"omnibar_history": app.read()} if app.has_list else {}, sites, pages, 60.0,
                        lambda test, seconds, step: test(), clock=app.clock, make_sites=make, pause=app.pause)
        return report, builder, made

    def test_one_tab_makes_the_visits_and_its_workspace_is_closed_before_the_last_read(self):
        app = App()
        report, builder, made = self.seed(app)
        self.assertEqual(builder.calls, ["new_workspace", "show ws9", ("openBrowser.chromium", {"url": URLS[0]}, "tab:tab9", True),
                                         ("closeWorkspace", {"confirm": True}, "workspace:ws9", False)])
        self.assertEqual(report["invalid"], [])
        self.assertEqual((report["asked"], report["visits_seen"]), ({"sites": 2, "pages": 4}, 4))
        self.assertEqual(report["before_the_close"], {"history": 4, "icons": 4, "newest_in_order": 4})
        self.assertEqual(report["after_the_close"], {"history": 4, "icons": 4, "newest_in_order": 4})
        self.assertEqual(report["state_reads"], app.reads)  # each read of the state is counted: 4 visits and the read after the close
        self.assertEqual(report["state_reads"], 5)
        self.assertEqual(report["icon"], {"pixels": "64 x 64", "png_bytes_least": 3, "png_bytes_most": 5})
        self.assertEqual(report["requests"], {"page": 4, "icon": 2, "next": 4, "other": 0})
        self.assertTrue(made[0].closed)  # no port stays open for the rows
        self.assertTrue(any("warm at the first key" in limit for limit in report["limits"]))

    def test_icons_that_do_not_stay_after_the_close_make_the_option_invalid(self):
        app = App()
        report, _, _ = self.seed(app, Builder(app, icons_stay=False))
        self.assertEqual((report["before_the_close"] or {}).get("icons"), 4)
        self.assertEqual(report["after_the_close"], {"history": 4, "icons": 0, "newest_in_order": 4})
        self.assertEqual(report["invalid"], ["after the close: 4 of those 4 pages have no icon"])

    def test_a_workspace_that_does_not_close_makes_the_option_invalid(self):
        app = App()
        report, _, made = self.seed(app, Builder(app, closes=False))
        self.assertIn("the pages' workspace did not close in 20 s", " | ".join(report["invalid"]))
        self.assertTrue(made[0].closed)

    def test_visits_that_stop_make_the_option_invalid_and_the_workspace_is_still_closed(self):
        app = App(icon_late=None)
        report, builder, made = self.seed(app)
        self.assertEqual(report["visits_seen"], 0)
        self.assertIn("has the address with NO icon", " | ".join(report["invalid"]))
        self.assertEqual(builder.calls[-1], ("closeWorkspace", {"confirm": True}, "workspace:ws9", False))
        self.assertTrue(made[0].closed)

    def test_fewer_pages_than_sites_is_refused_before_a_workspace_is_made(self):
        app = App()
        report, builder, made = self.seed(app, sites=3, pages=2)
        self.assertEqual((builder.calls, made), ([], []))
        self.assertIn("asked 3 sites and 2 pages", " | ".join(report["invalid"]))

    def test_more_sites_than_the_apps_list_has_places_is_refused_before_a_workspace_is_made(self):
        self.assertEqual(getattr(M, "MOST_SITES", None), 40, "the option has no limit of its sites")
        app = App()
        report, builder, made = self.seed(app, sites=41, pages=41)
        self.assertEqual((builder.calls, made), ([], []))
        self.assertIn("asked 41 sites", " | ".join(report["invalid"]))
        self.assertIn("40 sites at most", " | ".join(report["invalid"]))

    def test_no_workspace_for_the_pages_makes_the_option_invalid_and_the_ports_are_closed(self):
        app = App()

        class NoWorkspace(Builder):
            def new_workspace(self):
                self.calls.append("new_workspace")
                return None

        report, builder, made = self.seed(app, NoWorkspace(app))
        self.assertEqual(report["invalid"], ["the option stopped: RuntimeError('no workspace came for the pages')"])
        self.assertEqual(builder.calls, ["new_workspace"])  # no workspace: none to close
        self.assertEqual((report["visits_seen"], report["after_the_close"]), (0, None))
        self.assertTrue(made[0].closed)

    def test_a_workspace_with_no_tab_makes_the_option_invalid_and_is_closed(self):
        app = App()

        class NoTab(Builder):
            def settled_tabs(self, workspace, pane, seconds=20):
                return []

        report, builder, made = self.seed(app, NoTab(app))
        self.assertEqual(report["invalid"], ["the option stopped: RuntimeError('the workspace for the pages has no tab to open a page beside')"])
        self.assertEqual(builder.calls[-1], ("closeWorkspace", {"confirm": True}, "workspace:ws9", False))
        self.assertTrue(made[0].closed)

    def test_the_report_names_the_ports_of_the_sites(self):
        report, _, _ = self.seed(App())
        self.assertEqual(report.get("ports"), [9000, 9001])


def seeded(**changes):
    """The report of a `seed` whose 4 visits are in the app's list with their icons after the close."""
    return {"asked": {"sites": 2, "pages": 4}, "ports": [9000, 9001], "visits_seen": 4, "state_reads": 5,
            "after_the_close": {"history": 4, "icons": 4, "newest_in_order": 4}, "invalid": [], **changes}


class AfterTheRows(unittest.TestCase):
    """ONE more judge of the app's list after the last row: the list must have the sites' pages and icons that it had
    after the close."""

    def judge(self, report, listed_pages):
        judge = getattr(M, "after_rows", None)
        self.assertIsNotNone(judge, "the option has no judge of the app's list after the rows")
        return judge(report, listed_pages)

    def test_a_list_that_kept_its_pages_and_icons_gives_no_reason(self):
        report = seeded()
        self.assertEqual(self.judge(report, pages(reversed(URLS))), [])
        self.assertEqual(report["after_the_rows"], {"history": 4, "icons": 4})
        self.assertEqual((report["invalid"], report["state_reads"]), ([], 6))  # the read after the rows is a read of the option

    def test_other_pages_above_the_sites_pages_are_no_reason(self):
        report = seeded()
        self.assertEqual(self.judge(report, pages(["http://other/", "http://127.0.0.1:9002/p/0"] + list(reversed(URLS)))), [])
        self.assertEqual(report["after_the_rows"], {"history": 4, "icons": 4})  # another port is not a site of the option

    def test_an_icon_that_the_app_lost_in_the_rows_makes_the_option_invalid(self):
        report = seeded()
        reasons = self.judge(report, pages(reversed(URLS), without=URLS[:1]))
        self.assertEqual(report["after_the_rows"], {"history": 4, "icons": 3})
        self.assertEqual(reasons, ["after the rows: the app's list has 4 pages of the sites, 3 with an icon; after the close it "
                                   "had 4 pages, 4 with an icon"])
        self.assertEqual(report["invalid"], reasons)

    def test_pages_that_left_the_list_in_the_rows_make_the_option_invalid(self):
        report = seeded()
        reasons = self.judge(report, pages(["http://other/"] + list(reversed(URLS))[:2]))
        self.assertEqual(report["after_the_rows"], {"history": 2, "icons": 2})
        self.assertEqual(len(reasons), 1)
        self.assertIn("has 2 pages of the sites, 2 with an icon; after the close it had 4 pages, 4 with an icon", reasons[0])

    def test_no_list_after_the_rows_makes_the_option_invalid(self):
        report = seeded()
        self.assertEqual(self.judge(report, None), ["after the rows: the app's state has no `omnibar_history`"])
        self.assertEqual(report["invalid"], ["after the rows: the app's state has no `omnibar_history`"])

    def test_an_option_that_stopped_before_its_close_has_no_judge_after_the_rows(self):
        report = seeded(after_the_close=None, invalid=["the option stopped: RuntimeError('x')"])
        self.assertEqual(self.judge(report, pages(reversed(URLS))), [])
        self.assertEqual((report["invalid"], report["state_reads"]), (["the option stopped: RuntimeError('x')"], 6))
        self.assertIsNone(report.get("after_the_rows"))


if __name__ == "__main__":
    unittest.main()
