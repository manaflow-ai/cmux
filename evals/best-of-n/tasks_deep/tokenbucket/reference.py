"""Token-bucket rate limiting for the outbound API client.

Each upstream gets a bucket: `rate` tokens per second, holding at most `burst`.
A request takes `cost` tokens; a request that was rejected upstream before doing
any work gives its tokens back with `refund`. The clock is injectable.
"""

import math
import time


class TokenBucket:
    def __init__(self, rate, burst, clock=time.monotonic):
        if rate <= 0:
            raise ValueError("rate must be positive")
        if burst <= 0:
            raise ValueError("burst must be positive")
        self.rate = float(rate)
        self.burst = float(burst)
        self._clock = clock
        self._tokens = float(burst)
        self._last = clock()
        self.granted = 0
        self.denied = 0

    def _refill(self):
        now = self._clock()
        elapsed = now - self._last
        if elapsed > 0:
            self._tokens = min(self.burst, self._tokens + elapsed * self.rate)
        self._last = now

    @property
    def tokens(self):
        """Tokens available right now."""
        self._refill()
        return self._tokens

    def try_acquire(self, cost=1):
        """Take `cost` tokens if they are all available now; True if taken."""
        if cost <= 0:
            raise ValueError("cost must be positive")
        self._refill()
        if self._tokens >= cost:
            self._tokens -= cost
            self.granted += 1
            return True
        self.denied += 1
        return False

    def wait_time(self, cost=1):
        """Seconds from now until `cost` tokens will be available (0.0 if they are now)."""
        if cost <= 0:
            raise ValueError("cost must be positive")
        if cost > self.burst:
            return math.inf
        self._refill()
        missing = cost - self._tokens
        if missing <= 0:
            return 0.0
        return missing / self.rate

    def refund(self, cost=1):
        """Give back tokens taken for a request that did no work upstream."""
        if cost <= 0:
            raise ValueError("cost must be positive")
        self._refill()
        self._tokens = min(self.burst, self._tokens + cost)

    def acquire(self, cost=1, sleep=time.sleep):
        """Block (via `sleep`) until `cost` tokens are taken. Returns seconds slept."""
        slept = 0.0
        while not self.try_acquire(cost):
            delay = self.wait_time(cost)
            if math.isinf(delay):
                raise ValueError("cost %r exceeds burst %r" % (cost, self.burst))
            sleep(delay)
            slept += delay
        return slept


class Limiter:
    """A bucket per key, created on first use."""

    def __init__(self, rate, burst, clock=time.monotonic):
        self.rate = rate
        self.burst = burst
        self._clock = clock
        self._buckets = {}

    def bucket(self, key):
        b = self._buckets.get(key)
        if b is None:
            b = self._buckets[key] = TokenBucket(self.rate, self.burst, self._clock)
        return b

    def allow(self, key, cost=1):
        return self.bucket(key).try_acquire(cost)

    def prune(self):
        """Drop the buckets that are full right now and return how many were dropped.

        A full bucket is what a new key gets, so a dropped key behaves exactly as if its bucket had stayed.
        """
        full = [k for k, b in self._buckets.items() if b.tokens >= b.burst]
        for k in full:
            del self._buckets[k]
        return len(full)
