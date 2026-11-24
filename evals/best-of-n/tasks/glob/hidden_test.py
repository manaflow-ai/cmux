import time
from glob import match as m

def test_star():
    assert m("*.py", "a.py") and not m("*.py", "d/a.py") and m("a*b", "ab")
def test_double_star():
    assert m("**/*.py", "x/y/z.py") and m("src/**", "src/a/b") and m("**", "a/b/c")
def test_question():
    assert m("a?c", "abc") and not m("a?c", "a/c") and not m("a?c", "ac")
def test_class():
    assert m("[abc]x", "bx") and m("[a-c]x", "cx") and not m("[!a-c]x", "bx") and m("[!a-c]x", "dx") and not m("[!a]", "/")
def test_escape():
    assert m(r"\*", "*") and not m(r"\*", "a") and m(r"a\?", "a?")
def test_unclosed_bracket():
    assert m("[ab", "[ab") and not m("[ab", "a")
def test_whole():
    assert not m("abc", "abcd") and not m("bc", "abc")
def test_perf():
    start = time.time()
    assert not m("a*" * 30 + "b", "a" * 60)
    assert time.time() - start < 1.0
