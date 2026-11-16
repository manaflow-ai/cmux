"""A loopback feed for the update harness whose appcast answers after a delay.

Usage: python3 slow_feed.py PORT DIRECTORY LATENCY_MS READS_PATH

Every file in DIRECTORY is served as `http.server` would. A GET of an appcast (`*.xml`)
first waits LATENCY_MS, as a feed on a real network can, and appends one JSON line
{"path", "start_ms", "end_ms"} (unix ms) to READS_PATH. The harness reads those lines to
see whether the install click read the feed (a read that starts after the click) or
decided from a read made before it.
"""
import functools
import http.server
import json
import sys
import threading
import time

port, directory, latency_ms, reads_path = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]
lock = threading.Lock()


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if not self.path.split("?")[0].endswith(".xml"):
            return super().do_GET()
        start = time.time() * 1000
        time.sleep(latency_ms / 1000)
        super().do_GET()
        with lock, open(reads_path, "a") as f:
            f.write(json.dumps({"path": self.path, "start_ms": start, "end_ms": time.time() * 1000}) + "\n")


server = http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Handler, directory=directory))
server.serve_forever()
