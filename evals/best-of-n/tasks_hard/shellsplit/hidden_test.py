from shellsplit import split as s
import pytest_shim as t


def test_plain():
    assert s("a b  c") == ["a", "b", "c"] and s("  \t a\n b ") == ["a", "b"] and s("") == [] and s("   ") == []


def test_quotes_join():
    assert s("a '' b") == ["a", "", "b"] and s("a'b'\"c\"") == ["abc"] and s('""') == [""]
    assert s("'a b'c d") == ["a bc", "d"] and s("x=\"1 2\"") == ["x=1 2"]


def test_single_literal():
    assert s(r"'a\b'") == ["a\\b"] and s("'a\"b'") == ['a"b'] and s("'#x'") == ["#x"]


def test_double_escapes():
    assert s(r'"a\b"') == ["a\\b"] and s(r'"a\"b"') == ['a"b'] and s(r'"a\\b"') == ["a\\b"]
    assert s(r'"\$x \`y\`"') == ["$x `y`"] and s('"ab\\\ncd"') == ["abcd"] and s(r'"it'"'"'s"') == ["it's"]


def test_unquoted_backslash():
    assert s(r"a\ b") == ["a b"] and s(r"\'x") == ["'x"] and s("ab\\\ncd") == ["abcd"]
    assert s(r"a\\b") == ["a\\b"] and s("a \\\n b") == ["a", "b"] and s(r"\#x") == ["#x"]


def test_comments():
    assert s("a # b c\nd") == ["a", "d"] and s("a#b") == ["a#b"] and s("# all\n") == []
    assert s("a '#' #c") == ["a", "#"] and s("a\t#c") == ["a"] and s("a b#c #d") == ["a", "b#c"]


def test_errors():
    for bad in ["'abc", '"abc', "abc\\", '"a\\"', "a 'b\"c"]:
        t.raises(ValueError, s, bad)
