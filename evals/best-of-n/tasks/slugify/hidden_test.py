from slugify import slugify as s
import pytest_shim as t

def test_basic():
    assert s("Hello, World!") == "hello-world" and s("  --a  b--  ") == "a-b"
def test_accents():
    assert s("Crème Brûlée") == "creme-brulee" and s("ﬁx") == "fix"
def test_nonlatin():
    assert s("日本語") == "n-a" and s("!!!") == "n-a" and s("") == "n-a"
def test_cut_word():
    assert s("alpha beta gamma", 12) == "alpha-beta" and s("alpha beta gamma", 10) == "alpha-beta"
def test_cut_no_dash():
    assert s("abcdefghij", 4) == "abcd"
def test_cut_at_dash_boundary():
    assert s("ab cd", 3) == "ab"
def test_maxlen():
    t.raises(ValueError, s, "a", 0)
