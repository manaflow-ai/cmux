from urlresolve import resolve
import pytest_shim as t

B = "http://a/b/c/d;p?q"


def r(x):
    return resolve(B, x)


def test_normal():
    cases = {"g:h": "g:h", "g": "http://a/b/c/g", "./g": "http://a/b/c/g", "g/": "http://a/b/c/g/",
             "/g": "http://a/g", "//g": "http://g", "?y": "http://a/b/c/d;p?y", "g?y": "http://a/b/c/g?y",
             "#s": "http://a/b/c/d;p?q#s", "g#s": "http://a/b/c/g#s", "g?y#s": "http://a/b/c/g?y#s",
             ";x": "http://a/b/c/;x", "g;x": "http://a/b/c/g;x", "": "http://a/b/c/d;p?q", ".": "http://a/b/c/",
             "./": "http://a/b/c/", "..": "http://a/b/", "../": "http://a/b/", "../g": "http://a/b/g",
             "../..": "http://a/", "../../g": "http://a/g"}
    for k, v in cases.items():
        assert r(k) == v, (k, r(k), v)


def test_abnormal():
    cases = {"../../../g": "http://a/g", "../../../../g": "http://a/g", "/./g": "http://a/g",
             "/../g": "http://a/g", "g.": "http://a/b/c/g.", ".g": "http://a/b/c/.g", "g..": "http://a/b/c/g..",
             "..g": "http://a/b/c/..g", "./../g": "http://a/b/g", "./g/.": "http://a/b/c/g/",
             "g/./h": "http://a/b/c/g/h", "g/../h": "http://a/b/c/h", "g;x=1/./y": "http://a/b/c/g;x=1/y",
             "g;x=1/../y": "http://a/b/c/y", "g?y/./x": "http://a/b/c/g?y/./x", "g?y/../x": "http://a/b/c/g?y/../x",
             "g#s/./x": "http://a/b/c/g#s/./x", "g#s/../x": "http://a/b/c/g#s/../x", "http:g": "http:g"}
    for k, v in cases.items():
        assert r(k) == v, (k, r(k), v)


def test_empty_parts():
    assert resolve("http://a", "g") == "http://a/g" and resolve("http://a?x", "") == "http://a?x"
    assert resolve("http://a/b?q", "?") == "http://a/b?" and resolve("http://a/b?q#f", "#") == "http://a/b?q#"
    assert resolve("http://a/b", "//c") == "http://c" and resolve("http://a/b", "//") == "http://"
    assert resolve("mailto:x@y", "#f") == "mailto:x@y#f" and resolve("foo:a/b", "c") == "foo:a/c"


def test_scheme_ref_dots():
    assert resolve(B, "ftp://x/a/../b/./c") == "ftp://x/b/c" and resolve(B, "HTTP://A/%7e") == "HTTP://A/%7e"


def test_bad_base():
    t.raises(ValueError, resolve, "/just/a/path", "g")
