from csvsplit import split_csv_line as s
import pytest_shim as t

def test_plain():
    assert s("a,b,c") == ["a", "b", "c"] and s(" a , b") == [" a ", " b"]
def test_empty():
    assert s("") == [""] and s(",") == ["", ""] and s("a,") == ["a", ""] and s(",,") == ["", "", ""]
def test_quoted():
    assert s('"a,b",c') == ["a,b", "c"] and s('"he said ""hi""",x') == ['he said "hi"', "x"]
def test_quoted_empty():
    assert s('"",a') == ["", "a"] and s('a,""') == ["a", ""]
def test_errors():
    for bad in ['"abc', '"a"b,c', 'a"b,c', '"a""', 'x,"y']:
        t.raises(ValueError, s, bad)
