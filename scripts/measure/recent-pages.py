#!/usr/bin/env python3
"""Recent pages with site icons for a bench session: held-new-tab.py --recent-sites N --recent-pages M.

This commit has the names only: each function gives an empty answer, and the server answers each request with an
empty text. The rows of scripts/measure/tests/recent-pages.test.py say what each one has to give.
"""
import http.server
import threading
import time

ICON_SIDE = 64
HOST = "127.0.0.1"
LIMITS = ()


def icon_png(site, side=ICON_SIDE):
    return b""


def page_html(site, page):
    return b""


def plan(sites, pages):
    return []


class Sites:
    def __init__(self, count):
        self.count, self.server, self.thread = count, None, None
        self.icons = [icon_png(site) for site in range(count)]
        self.requests = {"page": 0, "icon": 0, "next": 0, "other": 0}

    def start(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802  the standard library's name
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer((HOST, 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        return self

    def url(self, site, page):
        return f"http://{HOST}:{self.server.server_address[1]}/p/{page}"

    def urls(self, pages):
        return [self.url(0, page) for page in range(pages)]

    def wait_asked(self, url, seconds):
        return False

    def give(self, url):
        return False

    def close(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.server = None


def listed(state):
    return None


def visit_all(urls, open_first, sites, read, seconds, visit_seconds=20.0, clock=time.monotonic, pause=time.sleep):
    return {"seen": 0, "state_reads": 0, "stopped": None, "newest": None}


def judge(urls, pages, sites):
    return {"history": 0, "icons": 0, "newest_in_order": 0, "faults": []}


def seed(builder, state, sites, pages, seconds, wait, clock=time.monotonic, make_sites=Sites, pause=time.sleep):
    return {"asked": {"sites": sites, "pages": pages}, "icon": None, "visits_seen": 0, "state_reads": 0, "requests": None,
            "before_the_close": None, "after_the_close": None, "seconds": None, "invalid": [], "limits": list(LIMITS)}
