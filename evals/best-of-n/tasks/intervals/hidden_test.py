from intervals import merge, subtract
import pytest_shim as t

def test_merge():
    assert merge([(5, 7), (1, 3), (2, 4)]) == [(1, 4), (5, 7)] and merge([]) == []
def test_touching():
    assert merge([(1, 3), (3, 5)]) == [(1, 5)]
def test_contained():
    assert merge([(1, 10), (2, 3)]) == [(1, 10)]
def test_invalid():
    t.raises(ValueError, merge, [(3, 3)]) ; t.raises(ValueError, merge, [(4, 2)]) ; t.raises(ValueError, subtract, [(1, 2)], [(5, 5)])
def test_subtract():
    assert subtract([(0, 10)], [(2, 3), (5, 7)]) == [(0, 2), (3, 5), (7, 10)]
    assert subtract([(0, 5)], [(0, 5)]) == [] and subtract([(0, 5)], [(-3, 1), (4, 9)]) == [(1, 4)]
def test_subtract_merges_a():
    assert subtract([(0, 3), (3, 6)], [(10, 11)]) == [(0, 6)]
def test_no_mutation():
    x = [(3, 4), (1, 2)]
    merge(x); subtract(x, [(1, 2)])
    assert x == [(3, 4), (1, 2)]
