from fractions import Fraction as F
from moneyalloc import allocate as a
import pytest_shim as t


def test_basic():
    assert a(100, [1, 1, 1]) == [34, 33, 33] and a(5, [1, 1]) == [3, 2] and a(0, [1, 2]) == [0, 0]
    assert a(1000, [3, 7]) == [300, 700]


def test_remainder_order():
    assert a(10, [1, 2, 3]) == [2, 3, 5]  # 1.667 3.333 5.0 -> remainder .667 goes first
    assert a(7, [2, 1, 1, 2]) == [3, 1, 1, 2]  # .333 tie, same ratio: lower index


def test_ties_prefer_larger_ratio():
    assert a(2, [1, 1, 2]) == [1, 0, 1]
    assert a(5, [1, 3]) == [1, 4]
    assert a(3, [1, 5]) == [0, 3]
    assert a(3, [5, 1]) == [3, 0]


def test_negative_total():
    assert a(-5, [1, 1]) == [-3, -2] and a(-100, [1, 1, 1]) == [-34, -33, -33]


def test_ratio_forms():
    assert a(100, ["0.5", "0.25", "0.25"]) == [50, 25, 25]
    assert a(10, [F(1, 3), F(2, 3)]) == [3, 7]
    assert a(3, ["0.333", "0.333", "0.334"]) == [1, 1, 1]
    assert a(7, [0, 1, 0]) == [0, 7, 0]


def test_sum_invariant():
    import random
    rnd = random.Random(7)
    for _ in range(300):
        rs = [rnd.randint(0, 9) for _ in range(rnd.randint(1, 6))]
        if not any(rs):
            continue
        tot = rnd.randint(-10_000, 10_000)
        p = a(tot, rs)
        assert sum(p) == tot and all(x == 0 for x, r in zip(p, rs) if r == 0)


def test_errors():
    for bad in [[], [-1, 2], [0, 0], [1.5, 1], [True, 1], ["abc", 1], ["1e3", 1]]:
        t.raises(ValueError, a, 10, bad)
    t.raises(TypeError, a, 10.0, [1])
    t.raises(TypeError, a, True, [1])
