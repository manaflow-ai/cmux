"""The store's client. `Offline` is no answer (no network, a timeout, a proxy's error page);
`Refused` is the store's own answer."""

import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request


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
        # One opener for every call: the system's proxy settings are read once, not per request.
        self.opener = urllib.request.build_opener()

    def _request(self, method, path, body=None, raw=None, timeout=10.0):
        if self.cut:
            raise Offline("offline")
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        request = urllib.request.Request(self.url + path, data=data, method=method)
        request.add_header("authorization", "Bearer " + self.token)
        if data is not None:
            request.add_header("content-type", "application/octet-stream" if raw is not None else "application/json")
        for name, value in self.headers.items():
            request.add_header(name, value)
        began = time.monotonic()
        where = None
        try:
            with self.opener.open(request, timeout=timeout) as reply:
                where = reply.headers.get("x-auto-ms")
                return reply.read()
        except urllib.error.HTTPError as error:
            text = error.read()
            try:
                parsed = json.loads(text)
                err = parsed["error"]
                raise Refused(error.code, err["code"], err["message"], parsed)
            except (ValueError, KeyError, TypeError):
                # Not the store's answer: a proxy, a wrong URL. Read as no answer.
                raise Offline("HTTP %s from something that is not the store" % error.code)
        except (urllib.error.URLError, socket.timeout, ConnectionError, OSError) as error:
            raise Offline(str(error))
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
