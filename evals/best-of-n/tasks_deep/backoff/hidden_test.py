from backoff import GaveUp, RetryableError, RetryPolicy, call_with_retries
from pytest_shim import raises


def fixed(x):
    return lambda: x


def close(a, b):
    return a is not None and abs(a - b) < 1e-9


def test_retry_after_is_obeyed_exactly():
    p = RetryPolicy(base=1, max_delay=30, max_attempts=5, rng=fixed(0.1))
    assert close(p.next_delay(1, 0.0, retry_after=120), 120.0)
    assert close(p.next_delay(2, 3.0, retry_after=2.5), 2.5)


def test_nominal_without_jitter():
    p = RetryPolicy(base=0.5, factor=2, max_delay=10, max_attempts=10, jitter=False)
    got = [p.next_delay(n, 0.0) for n in range(1, 8)]
    assert got == [0.5, 1.0, 2.0, 4.0, 8.0, 10.0, 10.0]


def test_jitter_scales_the_capped_delay():
    p = RetryPolicy(base=1, factor=2, max_delay=30, max_attempts=20, rng=fixed(0.5))
    assert close(p.next_delay(1, 0.0), 0.5)
    assert close(p.next_delay(3, 0.0), 2.0)
    assert close(p.next_delay(10, 0.0), 15.0)  # 0.5 * min(30, 512)


def test_jitter_stays_below_nominal():
    p = RetryPolicy(base=1, factor=3, max_delay=20, max_attempts=50, rng=fixed(0.999))
    for n in range(1, 40):
        d = p.next_delay(n, 0.0)
        assert 0 <= d < p.nominal(n), (n, d)


def test_max_attempts_counts_every_call():
    calls = []

    def fn():
        calls.append(1)
        raise RetryableError("nope")

    p = RetryPolicy(base=1, max_attempts=3, jitter=False)
    clock = [0.0]
    err = None
    try:
        call_with_retries(fn, p, clock=lambda: clock[0], sleep=lambda d: clock.__setitem__(0, clock[0] + d))
    except GaveUp as e:
        err = e
    assert err is not None
    assert len(calls) == 3
    assert p.next_delay(2, 0.0) is not None
    assert p.next_delay(3, 0.0) is None


def test_single_attempt_policy_never_retries():
    p = RetryPolicy(max_attempts=1)
    assert p.next_delay(1, 0.0) is None
    assert p.next_delay(1, 0.0, retry_after=1) is None


def test_deadline_shortens_computed_delay():
    p = RetryPolicy(base=4, factor=2, max_delay=60, max_attempts=10, deadline=10, jitter=False)
    assert close(p.next_delay(1, 0.0), 4.0)
    assert close(p.next_delay(2, 5.0), 5.0)  # 8 s wanted, 5 s remain
    assert close(p.next_delay(3, 9.5), 0.5)
    assert p.next_delay(3, 10.0) is None
    assert p.next_delay(3, 11.0) is None


def test_deadline_with_retry_after():
    p = RetryPolicy(base=1, max_attempts=10, deadline=60, rng=fixed(0.3))
    assert close(p.next_delay(1, 10.0, retry_after=50), 50.0)
    assert p.next_delay(1, 10.0, retry_after=51) is None


def test_call_with_retries_end_to_end():
    clock = [0.0]
    slept = []
    script = [RetryableError("busy", retry_after=7), RetryableError("again"), "ok"]

    def fn():
        item = script.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    def sleep(d):
        slept.append(d)
        clock[0] += d

    p = RetryPolicy(base=1, factor=2, max_delay=30, max_attempts=4, jitter=False)
    assert call_with_retries(fn, p, clock=lambda: clock[0], sleep=sleep) == "ok"
    assert slept == [7.0, 2.0]


def test_other_errors_propagate():
    def fn():
        raise KeyError("x")

    raises(KeyError, call_with_retries, fn, RetryPolicy(), lambda: 0.0, lambda d: None)
