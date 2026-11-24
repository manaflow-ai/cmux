from wrap import wrap
import pytest_shim as t

def test_basic():
    assert wrap("the quick brown fox", 10) == ["the quick", "brown fox"]
def test_exact():
    assert wrap("abc def", 7) == ["abc def"] and wrap("abc def", 6) == ["abc", "def"]
def test_whitespace():
    assert wrap("a\t\tb\n\nc", 80) == ["a b c"] and wrap("   ", 5) == [] and wrap("", 5) == []
def test_long_word():
    assert wrap("abcdefghij", 4) == ["abcd", "efgh", "ij"]
def test_long_word_then_join():
    assert wrap("abcdefghij k", 4) == ["abcd", "efgh", "ij k"]
def test_long_word_after():
    assert wrap("a bcdefgh", 3) == ["a", "bcd", "efg", "h"]
def test_width():
    t.raises(ValueError, wrap, "a", 0)
