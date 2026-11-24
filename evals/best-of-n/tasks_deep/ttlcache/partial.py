"""An in-process LRU cache whose entries also expire after a time-to-live.

Used by the session layer to hold decoded auth sessions and by the metadata
service to hold per-repo settings. The clock is injectable so tests (and the
replay tool) can drive time by hand.
"""

from collections import OrderedDict
import time

_MISSING = object()


class _Entry:
    __slots__ = ("value", "expires_at")

    def __init__(self, value, expires_at):
        self.value = value
        self.expires_at = expires_at


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
        self.hits = 0
        self.misses = 0

    # -- internals ---------------------------------------------------------

    def _expired(self, entry, now):
        return now >= entry.expires_at

    def _evict_one(self):
        self._data.popitem(last=False)

    # -- writes ------------------------------------------------------------

    def set(self, key, value, ttl=None):
        now = self._clock()
        life = self.ttl if ttl is None else ttl
        if life <= 0:
            raise ValueError("ttl must be positive")
        if key in self._data:
            del self._data[key]
        elif len(self._data) >= self.maxsize:
            self._evict_one()
        self._data[key] = _Entry(value, now + life)

    def delete(self, key):
        """Remove `key`; True if a live entry was removed."""
        entry = self._data.pop(key, None)
        if entry is None:
            return False
        return not self._expired(entry, self._clock())

    def clear(self):
        self._data.clear()

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
        if entry is None:
            return default
        return entry.value

    def __contains__(self, key):
        entry = self._data.get(key)
        return entry is not None and not self._expired(entry, self._clock())

    def __len__(self):
        return len(self._data)

    def keys(self):
        """Live keys, least recently used first."""
        return [k for k, _ in self.items()]

    def items(self):
        """Live (key, value) pairs, least recently used first."""
        return [(k, e.value) for k, e in self._data.items()]

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
