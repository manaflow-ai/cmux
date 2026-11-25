import math

from pytest_shim import raises
from tokenbucket import Limiter, TokenBucket


class Clock:
    def __init__(self, t=50.0):
        self.t = t

    def __call__(self):
        return self.t


def close(a, b):
    return abs(a - b) < 1e-9


def test_wait_time_follows_the_clock():
    c = Clock()
    b = TokenBucket(1, 3, clock=c)
    for _ in range(3):
        assert b.try_acquire()
    assert close(b.wait_time(), 1.0)
    c.t += 0.25
    assert close(b.wait_time(), 0.75)
    c.t += 10
    assert b.wait_time() == 0.0
    assert b.try_acquire()


def test_tokens_reflect_the_clock():
    c = Clock()
    b = TokenBucket(2, 10, clock=c)
    assert b.try_acquire(10)
    assert close(b.tokens, 0.0)
    c.t += 1.5
    assert close(b.tokens, 3.0)
    c.t += 100
    assert close(b.tokens, 10.0)


def test_idle_time_while_full_is_not_banked():
    c = Clock()
    b = TokenBucket(1, 5, clock=c)
    c.t += 100  # idle while full
    assert b.try_acquire(5)
    assert not b.try_acquire(1)
    assert close(b.wait_time(1), 1.0)
    c.t += 1
    assert b.try_acquire(1)
    assert not b.try_acquire(1)


def test_refund_is_capped_at_burst():
    c = Clock()
    b = TokenBucket(1, 4, clock=c)
    assert b.try_acquire(1)
    b.refund(3)
    assert close(b.tokens, 4.0)
    assert b.try_acquire(4)
    assert not b.try_acquire(1)


def test_refund_restores_taken_tokens():
    c = Clock()
    b = TokenBucket(1, 4, clock=c)
    assert b.try_acquire(4)
    b.refund(2)
    assert close(b.tokens, 2.0)
    assert b.try_acquire(2)
    assert not b.try_acquire(1)


def test_cost_above_burst_is_never_possible():
    c = Clock()
    b = TokenBucket(1, 3, clock=c)
    assert not b.try_acquire(4)
    assert b.wait_time(4) == math.inf
    calls = []

    def sleep(d):
        calls.append(d)
        c.t += d
        if len(calls) > 50:
            raise RuntimeError("acquire never gave up")

    raises(ValueError, b.acquire, 4, sleep)
    assert b.try_acquire(3)  # nothing was taken by the refusals


def test_wait_time_is_exact_for_partial_cost():
    c = Clock()
    b = TokenBucket(4, 8, clock=c)
    assert b.try_acquire(7)
    assert close(b.wait_time(3), 0.5)
    c.t += 0.5
    assert b.try_acquire(3)


def test_acquire_sleeps_the_wait_time():
    c = Clock()
    b = TokenBucket(2, 2, clock=c)
    assert b.try_acquire(2)
    c.t += 0.25

    def sleep(d):
        c.t += d

    slept = b.acquire(2, sleep)
    assert close(slept, 0.75)


def test_limiter_keys_are_independent():
    c = Clock()
    lim = Limiter(1, 1, clock=c)
    assert lim.allow("a")
    assert not lim.allow("a")
    assert lim.allow("b")
    c.t += 1
    assert lim.allow("a")


def test_rejects_bad_cost():
    b = TokenBucket(1, 1, clock=Clock())
    raises(ValueError, b.try_acquire, 0)
    raises(ValueError, b.wait_time, -1)


def test_random_sequences_match_a_model():
    import random
    rng = random.Random(42)
    for trial in range(100):
        c = Clock()
        rate = rng.choice((0.5, 1, 2, 4))
        burst = rng.choice((1, 2, 3, 8))
        b = TokenBucket(rate, burst, clock=c)
        tokens = float(burst)
        for step in range(40):
            dt = rng.choice((0, 0, 0.25, 0.5, 1, 4))
            c.t += dt
            tokens = min(float(burst), tokens + dt * rate)
            kind = rng.choice(("take", "take", "refund", "wait", "peek"))
            cost = rng.choice((1, 1, 2, 3, 9))
            where = (trial, step, kind, cost)
            if kind == "take":
                ok = cost <= burst and tokens >= cost - 1e-9
                assert b.try_acquire(cost) == ok, where
                if ok:
                    tokens -= cost
            elif kind == "refund":
                b.refund(cost)
                tokens = min(float(burst), tokens + cost)
            elif kind == "wait":
                if cost > burst:
                    want = math.inf
                else:
                    want = max(0.0, (cost - tokens) / rate)
                got = b.wait_time(cost)
                assert got == want or abs(got - want) < 1e-9, where
            else:
                assert abs(b.tokens - tokens) < 1e-9, where


def test_clock_stepping_back_resumes_from_new_reading():
    c = Clock(50.0)
    b = TokenBucket(1, 5, clock=c)
    assert b.try_acquire(5)
    c.t = 40.0  # NTP stepped the clock back
    assert close(b.tokens, 0.0)
    assert close(b.wait_time(1), 1.0)
    c.t = 43.0
    assert close(b.tokens, 3.0)
    assert b.try_acquire(3)
    assert not b.try_acquire(1)


def test_prune_drops_only_buckets_full_now():
    c = Clock()
    lim = Limiter(1, 2, clock=c)
    assert lim.allow("a", 2)
    assert lim.allow("b", 1)
    lim.bucket("idle")
    assert lim.prune() == 1  # only "idle" is full
    c.t += 1
    assert lim.prune() == 1  # "b" refilled
    assert lim.allow("a", 1)
    assert not lim.allow("a", 1)
    c.t += 10
    assert lim.prune() == 1
    assert lim.allow("a", 2)
