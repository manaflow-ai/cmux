"""The store's client. `Offline` is no answer (no network, a timeout, a proxy's error page);
`Refused` is the store's own answer."""

import http.client
import json
import os
import socket
import sys
import threading
import time
import urllib.parse


class Offline(Exception):
    pass


class Refused(Exception):
    def __init__(self, status, code, message, body):
        Exception.__init__(self, "%s: %s" % (code, message))
        self.status, self.code, self.message, self.body = status, code, message, body


class Client:
    def __init__(self, url, token, headers=None):
        self.url = url.rstrip("/")
        self.token = token
        self.headers = headers or {}
        # Set by the holder loop to act out a laptop with no network.
        self.cut = False
        parts = urllib.parse.urlsplit(self.url)
        self.secure = parts.scheme == "https"
        self.host, self.port = parts.hostname, parts.port or (443 if self.secure else 80)
        self.prefix = parts.path.rstrip("/")
        # One kept connection per thread. A new connection per call costs a round trip more,
        # and through an ssh forward each one is a channel: thousands of them in an hour.
        self.local = threading.local()

    def _connection(self, timeout):
        conn = getattr(self.local, "conn", None)
        if conn is not None:
            if conn.sock is not None:
                conn.sock.settimeout(timeout)
                return conn, True
            conn.close()
        kind = http.client.HTTPSConnection if self.secure else http.client.HTTPConnection
        conn = self.local.conn = kind(self.host, self.port, timeout=timeout)
        return conn, False

    def _drop(self):
        conn, self.local.conn = getattr(self.local, "conn", None), None
        if conn is not None:
            conn.close()

    def _request(self, method, path, body=None, raw=None, timeout=10.0):
        if self.cut:
            raise Offline("offline")
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        headers = {"authorization": "Bearer " + self.token}
        if data is not None:
            headers["content-type"] = "application/octet-stream" if raw is not None else "application/json"
        elif method in ("POST", "PUT"):
            headers["content-length"] = "0"
        headers.update(self.headers)
        began = time.monotonic()
        where = None
        try:
            for attempt in (1, 2):
                conn, kept = self._connection(timeout)
                try:
                    conn.request(method, self.prefix + path, body=data, headers=headers)
                    reply = conn.getresponse()
                    text = reply.read()
                    break
                except (http.client.RemoteDisconnected, ConnectionResetError, BrokenPipeError) as error:
                    # The other end closed a kept connection while it was idle: once more on a
                    # new one. Anything else (a timeout, a refused connection) is no answer.
                    self._drop()
                    if not kept or attempt == 2:
                        raise Offline(str(error) or type(error).__name__)
                except (http.client.HTTPException, socket.timeout, OSError) as error:
                    self._drop()
                    raise Offline(str(error) or type(error).__name__)
            where = reply.getheader("x-auto-ms")
            if reply.getheader("connection", "").lower() == "close":
                self._drop()
            if 200 <= reply.status < 300:
                return text
            try:
                parsed = json.loads(text)
                err = parsed["error"]
                refused = Refused(reply.status, err["code"], err["message"], parsed)
            except (ValueError, KeyError, TypeError):
                # Not the store's answer: a proxy, a wrong URL. Read as no answer.
                raise Offline("HTTP %s from something that is not the store" % reply.status)
            raise refused
        finally:
            took = time.monotonic() - began
            if os.environ.get("AUTO_DEBUG") and took > 1.0 and "wait" not in path:
                sys.stderr.write("slow call %.1fs %s %s (store: %s)\n" % (took, method, path.split("?")[0], where))

    def call(self, method, path, body=None, timeout=10.0):
        return json.loads(self._request(method, path, body=body, timeout=timeout))

    # ---- routes ----

    def status(self):
        return self.call("GET", "/status", timeout=5)

    def chats(self):
        return self.call("GET", "/chats")["chats"]

    def chat(self, chat_id):
        return self.call("GET", "/chats/%s" % chat_id)["chat"]

    def put(self, chat_id, body):
        return self.call("PUT", "/chats/%s" % chat_id, body)

    def create(self, body):
        return self.call("POST", "/chats", body)["chat"]

    def wait(self, chat_id, after, timeout_ms=20000):
        return self.call("GET", "/chats/%s/wait?after=%d&timeout_ms=%d" % (chat_id, after, timeout_ms),
                         timeout=timeout_ms / 1000.0 + 10)["chat"]

    def lease(self, chat_id, holder, epoch, needs_run, standby=False, timeout=5.0):
        return self.call("POST", "/chats/%s/lease" % chat_id,
                         {"holder": holder, "epoch": epoch, "needs_run": needs_run, "standby": standby},
                         timeout=timeout)

    def keep(self, chat_id, keep):
        return self.call("POST", "/chats/%s/keep" % chat_id, {"keep": keep})["chat"]

    def move(self, chat_id, to):
        return self.call("POST", "/chats/%s/move" % chat_id, {"to": to})["chat"]

    def give(self, chat_id, holder, epoch, to):
        return self.call("POST", "/chats/%s/give" % chat_id,
                         {"holder": holder, "epoch": epoch, "to": to}, timeout=20)

    def append_events(self, chat_id, holder, epoch, events):
        return self.call("POST", "/chats/%s/events" % chat_id,
                         {"holder": holder, "epoch": epoch, "events": events}, timeout=20)

    def events(self, chat_id, after, wait_ms=0):
        return self.call("GET", "/chats/%s/events?after=%d&wait_ms=%d" % (chat_id, after, wait_ms),
                         timeout=wait_ms / 1000.0 + 10)

    def missing_blobs(self, shas):
        return self.call("POST", "/blobs/missing", {"shas": shas}, timeout=30)["missing"]

    def put_blob(self, sha, data):
        self._request("PUT", "/blobs/%s" % sha, raw=data, timeout=120)

    def blob(self, sha):
        return self._request("GET", "/blobs/%s" % sha, timeout=120)

    def post_snapshot(self, chat_id, holder, epoch, manifest):
        return self.call("POST", "/chats/%s/snapshot" % chat_id,
                         {"holder": holder, "epoch": epoch, "manifest": manifest}, timeout=30)

    def snapshot(self, chat_id):
        return self.call("GET", "/chats/%s/snapshot" % chat_id, timeout=30)

    def post_inbox(self, chat_id, message_id, text, sender):
        return self.call("POST", "/chats/%s/inbox" % chat_id,
                         {"id": message_id, "text": text, "from": sender})

    def inbox(self, chat_id, after):
        return self.call("GET", "/chats/%s/inbox?after=%d" % (chat_id, after))["messages"]

    def ack_inbox(self, chat_id, holder, epoch, n):
        return self.call("POST", "/chats/%s/inbox/ack" % chat_id,
                         {"holder": holder, "epoch": epoch, "n": n})

    def assignments(self, machine, wait_ms=20000):
        return self.call("GET", "/assignments?machine=%s&wait_ms=%d" % (machine, wait_ms),
                         timeout=wait_ms / 1000.0 + 10)

    def ack_assignment(self, chat_id, holder, epoch):
        return self.call("POST", "/chats/%s/assignment/ack" % chat_id, {"holder": holder, "epoch": epoch})
