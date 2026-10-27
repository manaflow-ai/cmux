#!/usr/bin/env python3
"""tab_pages.py: the Chromium process classifier on fixture command lines (the kinds idle-budget.py and bench_idle.py
report, and the classes browser-idle-cost-live.py's report and budget key on), and the page server (each page, the
reports pages POST, the held load, close). Runs anywhere (no libproc). Run: python3 -I scripts/cmux-next/tests/test_tab_pages.py"""
import importlib.util, os, sys, threading, unittest, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
spec = importlib.util.spec_from_file_location("tab_pages", os.path.join(HERE, "..", "tab_pages.py"))
tp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tp)

APP = "/Users/x/DerivedData/cmux-t/Build/Products/Debug/cmux DEV t.app"
FW = f"{APP}/Contents/Frameworks"
GPU = f"{FW}/cmux DEV t Helper (GPU).app/Contents/MacOS/cmux DEV t Helper (GPU) --type=gpu-process --lang=en"
RENDERER = f"{FW}/cmux DEV t Helper (Renderer).app/Contents/MacOS/cmux DEV t Helper (Renderer) --type=renderer --renderer-client-id=5"
EXTENSION = f"{FW}/cmux DEV t Helper (Renderer).app/Contents/MacOS/cmux DEV t Helper (Renderer) --type=renderer --extension-process"
NETWORK = f"{FW}/cmux DEV t Helper.app/Contents/MacOS/cmux DEV t Helper --type=utility --utility-sub-type=network.mojom.NetworkService"
CRASHPAD = f"{FW}/cmux DEV t Helper.app/Contents/MacOS/cmux DEV t Helper --type=crashpad-handler --database=/x"
PLUGIN = f"{FW}/cmux DEV t Helper (Plugin).app/Contents/MacOS/cmux DEV t Helper (Plugin) --type=ppapi"
# The Chromium Host: a second executable of the app (embed-cef.sh), started with no --type.
HOST = f"{APP}/Contents/MacOS/cmux DEV t Chromium Host --framework=/x/Chromium Embedded Framework.framework"
# The Chromium Host app of older builds, in Contents/Frameworks.
OLD_HOST = f"{FW}/cmux DEV t Chromium Host.app/Contents/MacOS/cmux DEV t Chromium Host --cmux-socket=/tmp/h.sock"
BARE_HELPER = f"{FW}/cmux DEV t Helper.app/Contents/MacOS/cmux DEV t Helper"
# A --type process whose executable is not in a Helper app (the app's own binary run as a subprocess).
OUTSIDE = f"{APP}/Contents/MacOS/cmux DEV --type=utility --utility-sub-type=x.mojom.X"

# (pid, ppid, command): the app (100), its helpers, its daemon and a shell, and a renderer of another parent.
TABLE = [
    (100, 1, f"{APP}/Contents/MacOS/cmux DEV"),
    (101, 100, GPU), (102, 100, RENDERER), (103, 100, EXTENSION), (104, 100, NETWORK), (105, 100, CRASHPAD),
    (106, 100, f"{APP}/Contents/Resources/bin/cmux-tui server --socket s"), (107, 100, "/bin/zsh -f"),
    (108, 1, RENDERER), (109, 100, PLUGIN), (110, 100, HOST), (111, 100, BARE_HELPER), (112, 100, OUTSIDE),
]


def base_perf100_processes(app_pid, table):
    """browser-idle-cost-live.py's processes() at the base of p14-energy-130 (before tab_pages.py), word for word
    but for reading `table` instead of its own `ps -axww` call: the golden its classes are checked against."""
    rows = {}
    for pid, ppid, command in table:
        if ppid == app_pid:
            if "--type=gpu-process" in command:
                kind = "gpu"
            elif "--type=renderer" in command:
                kind = "extension-renderer" if "--extension-process" in command else "renderer"
            elif "--type=utility" in command:
                kind = "utility"
            elif "--type=" in command:
                kind = "other-helper"
            else:
                continue  # daemons and other children are not this lane's
            rows[pid] = kind
    rows[app_pid] = "app"
    return rows


def get(url):
    with urllib.request.urlopen(url, timeout=10) as reply:
        return reply.status, reply.read()


def post(url):
    request = urllib.request.Request(url, data=b"", method="POST")
    with urllib.request.urlopen(request, timeout=10) as reply:
        return reply.status


class ClassifierTests(unittest.TestCase):
    def test_kinds_follow_the_process_type(self):
        self.assertEqual(tp.chromium_kind(GPU), "cef-gpu")
        self.assertEqual(tp.chromium_kind(RENDERER), "cef-renderer")
        self.assertEqual(tp.chromium_kind(EXTENSION), "cef-extension")
        self.assertEqual(tp.chromium_kind(NETWORK), "cef-utility")
        self.assertEqual(tp.chromium_kind(CRASHPAD), "cef-helper")
        self.assertEqual(tp.chromium_kind(PLUGIN), "cef-helper")
        self.assertEqual(tp.chromium_kind(BARE_HELPER), "cef-helper")
        self.assertEqual(tp.chromium_kind(HOST), "cef-host")
        self.assertEqual(tp.chromium_kind(OLD_HOST), "cef-host")
        self.assertIsNone(tp.chromium_kind(OUTSIDE), "a --type outside a Helper app is not a Chromium helper")

    def test_process_type_kind_reads_the_type_alone(self):
        self.assertEqual(tp.process_type_kind(RENDERER), "cef-renderer")
        self.assertEqual(tp.process_type_kind(EXTENSION), "cef-extension")
        self.assertEqual(tp.process_type_kind(CRASHPAD), "cef-helper")
        self.assertEqual(tp.process_type_kind(OUTSIDE), "cef-utility")
        self.assertIsNone(tp.process_type_kind(BARE_HELPER))
        self.assertIsNone(tp.process_type_kind(HOST))

    def test_non_chromium_processes_have_no_kind(self):
        self.assertIsNone(tp.chromium_kind(f"{APP}/Contents/MacOS/cmux DEV"))
        # The host's name only at the end of the executable: an argument naming it is not the host.
        self.assertIsNone(tp.chromium_kind(f"{APP}/Contents/MacOS/cmux DEV t Chromium Host Tool"))
        self.assertIsNone(tp.chromium_kind("/bin/zsh -c ls /x.app/Contents/MacOS/cmux DEV t Chromium Host"))
        self.assertIsNone(tp.chromium_kind(f"{APP}/Contents/Resources/bin/cmux-tui __terminal-host --owner a@1"))
        self.assertIsNone(tp.chromium_kind("/bin/zsh -f"))
        # A shell whose arguments name a helper or a --type is not a Chromium process of its own.
        self.assertIsNone(tp.chromium_kind("/bin/zsh -c echo cmux Helper"))

    def test_children_are_the_app_s_own_chromium_processes(self):
        self.assertEqual(tp.chromium_children(100, TABLE), {101: "cef-gpu", 102: "cef-renderer", 103: "cef-extension",
                                                            104: "cef-utility", 105: "cef-helper", 109: "cef-helper",
                                                            110: "cef-host", 111: "cef-helper"})

    def test_perf100_classes_are_what_browser_idle_cost_live_reported(self):
        # The lane's classes as its base code gave them (its budget file and history key on them): a child of the app
        # with a --type, whatever its executable, and no child without one (the Chromium Host, a bare Helper).
        with open(os.path.join(HERE, "..", "browser-idle-cost-live.py")) as handle:
            self.assertIn("chromium_children(app_pid, process_table(), PERF100_CLASSES, process_type_kind)", handle.read(),
                          "browser-idle-cost-live.py's processes() sorts by --type alone")
        got = {**tp.chromium_children(100, TABLE, tp.PERF100_CLASSES, tp.process_type_kind), 100: "app"}
        self.assertEqual(got, base_perf100_processes(100, TABLE))
        self.assertIn(112, got)
        self.assertNotIn(111, got)
        self.assertNotIn(110, got)


# browser-idle-cost-live.py's pages as its own server served them before tab_pages.py (marker cmux-idle-cost-0a1b2c3d).
GOLDEN = {
    "/static-0": "<title>static 0</title><body style='font:16px system-ui'><h1>Static page 0</h1><p>Nothing runs here.</p>"
                 "<script>fetch('/loaded/0',{method:'POST'});const v=()=>fetch('/vis/0/'+document.visibilityState,{method:'POST'});"
                 "v();document.addEventListener('visibilitychange',v)</script>",
    "/loading-x": "<title>loading</title><body><h1>This load never ends</h1><img src='/never'>"
                  "<script>fetch('/loaded/loading',{method:'POST'})</script>",
    "/chatty-x": "<title>chatty</title><body><h1>Console chatter</h1><script>let i=0;"
                 "setInterval(()=>{console.log('cmux-idle-cost-0a1b2c3d ' + (i++));if(i%4==0)fetch('/tick',{method:'POST'})}, 250);"
                 "fetch('/loaded/chatty',{method:'POST'})</script>",
}


class PageServerTests(unittest.TestCase):
    def setUp(self):
        self.pages = tp.TabPages(marker="cmux-idle-cost-feedf00d")
        self.addCleanup(self.pages.close)

    def test_browser_idle_cost_live_pages_are_unchanged(self):
        pages = tp.TabPages(marker="cmux-idle-cost-0a1b2c3d")
        self.addCleanup(pages.close)
        for path, html in GOLDEN.items():
            self.assertEqual(get(pages.origin + path)[1], html.encode(), path)

    def test_each_page_is_served(self):
        status, body = get(self.pages.url("static", 3))
        self.assertEqual(status, 200)
        self.assertIn(b"<h1>Static page 3</h1>", body)
        self.assertIn(b"fetch('/loaded/3',{method:'POST'})", body)
        self.assertIn(b"console.log('cmux-idle-cost-feedf00d ' + (i++))", get(self.pages.url("chatty", "x"))[1])
        self.assertNotIn(b"<script", get(self.pages.url("plain"))[1])
        grid = get(self.pages.url("grid", 7))[1]
        self.assertIn(b"<title>idle 7</title>", grid)
        self.assertNotIn(b"<script", grid, "the grid page is STRESS's page without its rAF spinner")
        self.assertEqual(grid.count(b"<div></div>"), 120)

    def test_an_unknown_page_is_404(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            get(f"{self.pages.origin}/nothing-1")
        self.assertEqual(caught.exception.code, 404)
        with self.assertRaises(ValueError):
            self.pages.url("nothing")

    def test_url_without_arguments_counts_up_on_the_default_kind(self):
        grid = tp.TabPages(default_kind="grid")
        self.addCleanup(grid.close)
        self.assertEqual([grid.url(), grid.url()], [f"{grid.origin}/grid-1", f"{grid.origin}/grid-2"])

    def test_engine_page_reports_its_vendor(self):
        body = get(self.pages.url("engine", 4))[1]
        self.assertIn(b"fetch('/loaded/4',{method:'POST'})", body)
        self.assertIn(b"fetch('/engine/4/'+encodeURIComponent(navigator.vendor),{method:'POST'})", body)
        self.assertIn(b"addEventListener('visibilitychange',v)", body)
        self.assertNotIn(b"setInterval", body)
        self.assertEqual(post(self.pages.origin + "/engine/4/Apple%20Computer%2C%20Inc."), 204)
        self.assertEqual(post(self.pages.origin + "/engine/5/Google%20Inc."), 204)
        self.assertEqual(self.pages.vendors, {"4": "Apple Computer, Inc.", "5": "Google Inc."})

    def test_pages_report_loads_visibility_and_ticks(self):
        for path in ("/loaded/0", "/vis/0/hidden", "/vis/0/visible", "/vis/1/hidden", "/tick", "/tick"):
            self.assertEqual(post(self.pages.origin + path), 204)
        self.assertEqual(self.pages.loaded, {"0"})
        self.assertEqual(self.pages.visibility, {"0": "visible", "1": "hidden"})
        self.assertEqual(self.pages.ticks, 8)

    def test_close_ends_a_held_load(self):
        done = threading.Event()

        def held():
            try:
                get(f"{self.pages.origin}/never")
            except (OSError, urllib.error.URLError):
                pass  # the server closes the connection without a reply
            done.set()

        threading.Thread(target=held, daemon=True).start()
        self.assertFalse(done.wait(0.3), "the /never load ended on its own")
        self.pages.close()
        self.assertTrue(done.wait(10), "close() did not end the held load")
        self.pages.close()  # a second close is nothing


if __name__ == "__main__":
    unittest.main()
