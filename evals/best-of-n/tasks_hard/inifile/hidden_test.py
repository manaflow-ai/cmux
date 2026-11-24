from inifile import parse as p
import pytest_shim as t


def test_basic():
    assert p("[A]\nX = 1\ny: two words\n") == {"a": {"x": "1", "y": "two words"}}
    assert p("[s]\nk=a=b\nm = c:d\nn=\n") == {"s": {"k": "a=b", "m": "c:d", "n": ""}}
    assert p("[s]\nk: a=b\n") == {"s": {"k": "a=b"}} and p("[s]\r\nk=1\r\n") == {"s": {"k": "1"}}


def test_comments():
    assert p("; c\n# c\n[s]\n  ; indented comment\nk = v ; note\nj = x;y\nh = a #b\n") == \
        {"s": {"k": "v", "j": "x;y", "h": "a"}}


def test_defaults_and_repeats():
    r = p("k = 0\nz = 9\n[a]\nk = 1\n[b]\n[A]\nm = 2\nk = 3\n")
    assert r == {"default": {"k": "0", "z": "9"}, "a": {"k": "3", "z": "9", "m": "2"}, "b": {"k": "0", "z": "9"}}
    assert "default" not in p("[a]\nx=1\n")


def test_continuation():
    assert p("[s]\nk = a\n  b ; c\n\tc\nj = 1\n") == {"s": {"k": "a\nb\nc", "j": "1"}}
    assert p("[s]\nk = a\n\nj=2\n") == {"s": {"k": "a", "j": "2"}}
    t.raises(ValueError, p, "[s]\n  orphan\n")
    t.raises(ValueError, p, "[s]\nk=a\n\n  after-blank\n")
    t.raises(ValueError, p, "[s]\nk=1\n[t]\n  x\n")


def test_interpolation():
    r = p("home = /h\n[paths]\nbin = ${home}/bin\nlib = ${bin}/../lib\n[x]\nu = ${paths:lib}!\nc = $$5 ${PATHS:Bin}\n")
    assert r["paths"] == {"home": "/h", "bin": "/h/bin", "lib": "/h/bin/../lib"}
    assert r["x"]["u"] == "/h/bin/../lib!" and r["x"]["c"] == "$5 /h/bin"
    assert p("[s]\nk = $${k}\n")["s"]["k"] == "${k}"


def test_interp_errors():
    for bad in ["[s]\na=${b}\nb=${a}\n", "[s]\na=${a}\n", "[s]\na=${nope}\n", "[s]\na=${t:x}\n", "[s]\na=5$\n",
                "[s]\na=$x\n"]:
        t.raises(ValueError, p, bad)


def test_syntax_errors():
    for bad in ["[s]\njunk\n", "[]\n", "[s]\n= v\n"]:
        t.raises(ValueError, p, bad)
