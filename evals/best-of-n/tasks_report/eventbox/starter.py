COALESCED = {"title", "scroll", "output", "agent", "status"}


class Mailbox:
    def __init__(self, capacity):
        self.capacity = capacity
        self.closed = False
        self.overflowed = False
        self._seq = 0
        self._plain = []  # [(seq, event)] in sequence order
        self._coalesced = {}  # key -> (seq, event)

    def _next(self):
        self._seq += 1
        return self._seq

    def _key(self, event):
        if event[0] == "config_reload":
            return ("config_reload",)
        if event[0] in COALESCED:
            return (event[0], event[1])
        return None

    def _slot(self):
        if len(self._plain) + len(self._coalesced) >= self.capacity:
            self.closed = self.overflowed = True
            return False
        return True

    def push(self, event):
        if self.closed:
            return False
        kind = event[0]
        key = self._key(event)
        if key is not None:
            if key not in self._coalesced and not self._slot():
                return False
            self._coalesced[key] = (self._next(), event)
            return True
        if kind == "empty":
            keep = [p for p in self._plain if p[1][0] in ("exited", "workspace_closed")]
            self._plain = keep[-(self.capacity - 1):] if self.capacity > 1 else []
            self._coalesced.clear()
            self._plain.append((self._next(), event))
            return True
        if kind == "tree_changed" and self._plain and self._plain[-1][1][0] == "tree_changed":
            last = self._plain[-1][0]
            if all(s < last for s, _ in self._coalesced.values()):
                return True
        if kind == "exited":
            self._coalesced = {k: v for k, v in self._coalesced.items()
                               if not (len(k) == 2 and k[1] == event[1])}
        if not self._slot():
            return False
        self._plain.append((self._next(), event))
        return True

    def pop(self):
        best = None
        if self._plain:
            best = ("p", self._plain[0][0])
        for k, (s, _) in self._coalesced.items():
            if best is None or s < best[1]:
                best = (k, s)
        if best is None:
            return None
        if best[0] == "p":
            return self._plain.pop(0)[1]
        return self._coalesced.pop(best[0])[1]
