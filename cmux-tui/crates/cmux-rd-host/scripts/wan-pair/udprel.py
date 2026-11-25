"""A tiny reliable JSON-message channel over UDP (seq, ack, retransmit), with a shared token.
Used to carry the device hub's signaling between a lane VM and a fleet Mac, which share no
tailnet port; UDP to the VM's public address gets through."""
import json, os, socket, time, threading, queue


class Chan:
    def __init__(self, sock, token, peer=None):
        self.s, self.token, self.peer = sock, token, peer
        self.seq, self.unacked, self.buf, self.next = 0, {}, {}, 1
        self.inbox = queue.Queue()
        self.epoch, self.peer_epoch = os.urandom(4).hex(), None
        self.lock = threading.Lock()
        self.last_heard = 0.0
        self.synced = False
        self.partial = ""  # a restarted receiver takes up the sender's seq where it is
        threading.Thread(target=self._rx, daemon=True).start()
        threading.Thread(target=self._tx, daemon=True).start()

    def _raw(self, obj):
        if self.peer:
            self.s.sendto(json.dumps({**obj, "tok": self.token, "ep": self.epoch}).encode(), self.peer)

    FRAG = 6000  # macOS caps a UDP datagram near 9 KB

    def send(self, msg):
        body = json.dumps(msg)
        parts = [body[i:i + self.FRAG] for i in range(0, len(body), self.FRAG)] if len(body) > self.FRAG else None
        with self.lock:
            for i, piece in enumerate(parts or [None]):
                self.seq += 1
                m = msg if parts is None else {"_frag": piece, "_last": i == len(parts) - 1}
                self.unacked[self.seq] = (m, 0.0)

    def _tx(self):
        while True:
            now = time.time()
            with self.lock:
                for n, (m, at) in list(self.unacked.items()):
                    if now - at > 0.2:
                        try:
                            self._raw({"seq": n, "msg": m})
                        except OSError:
                            pass
                        self.unacked[n] = (m, now)
                if not self.unacked:
                    self._raw({"ping": 1})
            time.sleep(0.02 if self.unacked else 0.5)

    def _rx(self):
        while True:
            try:
                data, addr = self.s.recvfrom(65535)
                d = json.loads(data)
            except (OSError, ValueError):
                continue
            if d.get("tok") != self.token:
                continue
            self.peer, self.last_heard = addr, time.time()
            if d.get("ep") != self.peer_epoch:
                self.peer_epoch, self.buf, self.next, self.synced = d.get("ep"), {}, 1, False
                self.partial = ""
            if "ack" in d:
                with self.lock:
                    self.unacked.pop(d["ack"], None)
            elif "seq" in d:
                self._raw({"ack": d["seq"]})
                if not self.synced:
                    self.next, self.synced = d["seq"], True
                if d["seq"] >= self.next:
                    self.buf[d["seq"]] = d["msg"]
                while self.next in self.buf:
                    m = self.buf.pop(self.next)
                    self.next += 1
                    if isinstance(m, dict) and "_frag" in m:
                        self.partial += m["_frag"]
                        if m["_last"]:
                            self.inbox.put(json.loads(self.partial))
                            self.partial = ""
                        continue
                    self.inbox.put(m)

    def drain(self, settle=1.0):
        """Drop what a sender left queued for an earlier receiver."""
        time.sleep(settle)
        n = 0
        while self.recv(0) is not None:
            n += 1
        return n

    def recv(self, timeout=None):
        try:
            return self.inbox.get(timeout=timeout)
        except queue.Empty:
            return None
