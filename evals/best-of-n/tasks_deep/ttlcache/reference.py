"""An in-process LRU cache whose entries also expire after a time-to-live.

Used by the session layer to hold decoded auth sessions and by the metadata
service to hold per-repo settings. The clock is injectable so tests (and the
replay tool) can drive time by hand.
"""

from collections import OrderedDict
import heapq
import itertools
import time

_MISSING = object()


class _Entry:
    __slots__ = ("value", "expires_at", "token")

    def __init__(self, value, expires_at, token=0):
        self.value = value
        self.expires_at = expires_at
        self.token = token


class TTLCache:
    """A mapping of at most `maxsize` live entries, each living `ttl` seconds.

    `set` takes an optional per-entry `ttl` that overrides the cache default.
    """

    def __init__(self, maxsize, ttl, clock=time.monotonic):
        if maxsize < 1:
            raise ValueError("maxsize must be at least 1")
        if ttl <= 0:
            raise ValueError("ttl must be positive")
        self.maxsize = maxsize
        self.ttl = ttl
        self._clock = clock
        # Oldest (least recently used) first.
        self._data = OrderedDict()
        # (expires_at, token, key) for every entry; stale tokens are skipped.
        self._heap = []
        self._tokens = itertools.count()
        self.hits = 0
        self.misses = 0

    # -- internals ---------------------------------------------------------

    def _expired(self, entry, now):
        return now >= entry.expires_at

    def _purge(self, now):
        heap = self._heap
        while heap and heap[0][0] <= now:
            _, token, key = heapq.heappop(heap)
            entry = self._data.get(key)
            if entry is not None and entry.token == token:
                del self._data[key]
        if len(heap) > 4 * len(self._data) + 64:
            self._heap = [(e.expires_at, e.token, k) for k, e in self._data.items()]
            heapq.heapify(self._heap)

    def _evict_one(self):
        self._data.popitem(last=False)

    # -- writes ------------------------------------------------------------

    def set(self, key, value, ttl=None):
        now = self._clock()
        life = self.ttl if ttl is None else ttl
        if life <= 0:
            raise ValueError("ttl must be positive")
        self._purge(now)
        if key in self._data:
            del self._data[key]
        elif len(self._data) >= self.maxsize:
            self._evict_one()
        token = next(self._tokens)
        self._data[key] = _Entry(value, now + life, token)
        heapq.heappush(self._heap, (now + life, token, key))

    def delete(self, key):
        """Remove `key`; True if a live entry was removed."""
        entry = self._data.pop(key, None)
        if entry is None:
            return False
        return not self._expired(entry, self._clock())

    def clear(self):
        self._data.clear()
        self._heap = []

    # -- reads -------------------------------------------------------------

    def get(self, key, default=None):
        """The live value for `key` (and mark it most recently used), or `default`."""
        entry = self._data.get(key)
        if entry is None:
            self.misses += 1
            return default
        if self._expired(entry, self._clock()):
            del self._data[key]
            self.misses += 1
            return default
        self._data.move_to_end(key)
        self.hits += 1
        return entry.value

    def peek(self, key, default=None):
        """Like get, but does not change recency or the hit counters."""
        entry = self._data.get(key)
        if entry is None or self._expired(entry, self._clock()):
            return default
        return entry.value

    def __contains__(self, key):
        entry = self._data.get(key)
        return entry is not None and not self._expired(entry, self._clock())

    def __len__(self):
        self._purge(self._clock())
        return len(self._data)

    def keys(self):
        """Live keys, least recently used first."""
        return [k for k, _ in self.items()]

    def items(self):
        """Live (key, value) pairs, least recently used first."""
        now = self._clock()
        return [(k, e.value) for k, e in self._data.items() if not self._expired(e, now)]

    def pop(self, key, default=_MISSING):
        """Remove `key` and return its live value; without a default, a missing key raises KeyError."""
        entry = self._data.pop(key, None)
        if entry is None or self._expired(entry, self._clock()):
            if default is _MISSING:
                raise KeyError(key)
            return default
        return entry.value

    def get_or_load(self, key, loader, ttl=None):
        """The live value for `key`; on a miss, call loader(key), cache what it returns (with `ttl`) and return it.

        Counts one hit or one miss exactly like get(). A cached value of None is a hit like any other. If
        loader raises, nothing is cached and the error propagates.
        """
        value = self.get(key, _MISSING)
        if value is not _MISSING:
            return value
        value = loader(key)
        self.set(key, value, ttl)
        return value

    def ttl_remaining(self, key):
        """Seconds until `key` expires, or None if it is not live."""
        entry = self._data.get(key)
        if entry is None:
            return None
        now = self._clock()
        if self._expired(entry, now):
            return None
        return entry.expires_at - now

    def stats(self):
        total = self.hits + self.misses
        return {
            "hits": self.hits,
            "misses": self.misses,
            "hit_rate": (self.hits / total) if total else 0.0,
            "size": len(self),
        }
