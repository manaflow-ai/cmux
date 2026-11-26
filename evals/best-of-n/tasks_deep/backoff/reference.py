"""Retry scheduling for calls to flaky upstreams (webhooks, the object store).

`RetryPolicy.next_delay` decides how long to wait before the next attempt, or
that we give up; `call_with_retries` drives a callable with it. Randomness, the
clock and sleeping are all injectable.
"""

import random
import time


class RetryableError(Exception):
    """Raised by a callable for a failure worth retrying.

    `retry_after` is the server's Retry-After, in seconds, when it sent one.
    """

    def __init__(self, message="", retry_after=None):
        super().__init__(message)
        self.retry_after = retry_after


class GaveUp(Exception):
    """Raised by call_with_retries when the policy says stop; `last` is the final error."""

    def __init__(self, attempts, last):
        super().__init__("gave up after %d attempts: %s" % (attempts, last))
        self.attempts = attempts
        self.last = last


class RetryPolicy:
    """Capped exponential backoff with optional full jitter.

    base, factor, max_delay: the nominal delay after the n-th failed attempt is
        base * factor ** (n - 1), never more than max_delay.
    max_attempts: total attempts allowed, the first one included.
    deadline: seconds since the first attempt started by which every attempt
        must have started, or None for no deadline.
    jitter: True for full jitter (a uniform draw from [0, nominal)), False for
        the nominal delay exactly.
    rng: a callable returning floats in [0, 1).
    """

    def __init__(self, base=0.5, factor=2.0, max_delay=30.0, max_attempts=5,
                 deadline=None, jitter=True, rng=random.random):
        if base <= 0 or factor < 1 or max_delay <= 0:
            raise ValueError("bad backoff parameters")
        if max_attempts < 1:
            raise ValueError("max_attempts must be at least 1")
        self.base = base
        self.factor = factor
        self.max_delay = max_delay
        self.max_attempts = max_attempts
        self.deadline = deadline
        self.jitter = jitter
        self.rng = rng

    def nominal(self, failures):
        """The un-jittered delay after `failures` failed attempts (failures >= 1)."""
        return min(self.max_delay, self.base * self.factor ** (failures - 1))

    def next_delay(self, failures, elapsed, retry_after=None):
        """Seconds to wait before the next attempt, or None to give up.

        failures: attempts made so far, all failed (>= 1).
        elapsed: seconds since the first attempt started.
        retry_after: the server's Retry-After for the last failure, if any.
        """
        if failures >= self.max_attempts:
            return None
        remaining = None if self.deadline is None else self.deadline - elapsed
        if remaining is not None and remaining <= 0:
            return None
        if retry_after is not None:
            delay = max(0.0, float(retry_after))
            if remaining is not None and delay > remaining:
                return None
            return delay
        delay = self.nominal(failures)
        if self.jitter:
            delay *= self.rng()
        if remaining is not None:
            delay = min(delay, remaining)
        return delay


def call_with_retries(fn, policy, clock=time.monotonic, sleep=time.sleep):
    """Call fn() until it returns, retrying RetryableError as `policy` allows.

    Returns fn's result. Raises GaveUp when the policy stops; any other
    exception from fn propagates at once.
    """
    start = clock()
    failures = 0
    while True:
        try:
            return fn()
        except RetryableError as err:
            failures += 1
            delay = policy.next_delay(failures, clock() - start, err.retry_after)
            if delay is None:
                raise GaveUp(failures, err) from err
            sleep(delay)
