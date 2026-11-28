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


def test_non_positive_retry_after_means_now():
    p = RetryPolicy(base=1, max_attempts=5, rng=fixed(0.5))
    assert p.next_delay(1, 0.0, retry_after=0) == 0.0
    assert p.next_delay(1, 0.0, retry_after=-30) == 0.0
    q = RetryPolicy(base=1, max_attempts=5, deadline=10, rng=fixed(0.5))
    assert q.next_delay(2, 9.0, retry_after=-1) == 0.0


def _model(p, failures, elapsed, retry_after, draw):
    if failures >= p.max_attempts:
        return None
    remaining = None if p.deadline is None else p.deadline - elapsed
    if remaining is not None and remaining <= 0:
        return None
    if retry_after is not None:
        d = max(0.0, float(retry_after))
        return None if remaining is not None and d > remaining else d
    d = min(p.max_delay, p.base * p.factor ** (failures - 1))
    if p.jitter:
        d *= draw
    return d if remaining is None else min(d, remaining)


def test_random_policies_match_the_contract():
    import random
    rng = random.Random(11)
    for trial in range(3000):
        draw = rng.random()
        p = RetryPolicy(base=rng.choice((0.1, 0.5, 1, 3)), factor=rng.choice((1, 1.5, 2, 3)),
                        max_delay=rng.choice((1, 5, 30)), max_attempts=rng.randint(1, 6),
                        deadline=rng.choice((None, None, 5, 20, 60)), jitter=rng.random() < 0.5,
                        rng=fixed(draw))
        failures = rng.randint(1, 7)
        elapsed = rng.choice((0.0, 1.0, 4.5, 19.0, 30.0, 70.0))
        ra = rng.choice((None, None, None, -2, 0, 3, 45))
        want = _model(p, failures, elapsed, ra, draw)
        got = p.next_delay(failures, elapsed, ra)
        assert (got is None) == (want is None), (trial, failures, elapsed, ra, got, want)
        if want is not None:
            assert abs(got - want) < 1e-9, (trial, got, want)
