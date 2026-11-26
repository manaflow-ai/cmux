from semver import compare
import pytest_shim as t

def test_basic():
    assert compare("1.0.0", "2.0.0") == -1 and compare("2.1.0", "2.0.9") == 1 and compare("1.2.3", "1.2.3") == 0
def test_numeric_not_lexical():
    assert compare("1.10.0", "1.9.0") == 1
def test_prerelease_lower():
    assert compare("1.0.0-alpha", "1.0.0") == -1
def test_spec_chain():
    chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
    for x, y in zip(chain, chain[1:]):
        assert compare(x, y) == -1, (x, y)
        assert compare(y, x) == 1, (y, x)
def test_build_ignored():
    assert compare("1.0.0+build.1", "1.0.0+build.2") == 0 and compare("1.0.0-rc.1+x", "1.0.0-rc.1") == 0
def test_ascii_order():
    assert compare("1.0.0-Alpha", "1.0.0-alpha") == -1
def test_invalid():
    for bad in ["01.0.0", "1.0", "v1.0.0", "1.0.0-", "1.0.0-alpha..1", "1.0.0-01", "1.0.0+"]:
        t.raises(ValueError, compare, bad, "1.0.0")
def test_alnum_with_digits():
    assert compare("1.0.0-alpha1", "1.0.0-alpha10") == -1 and compare("1.0.0-0a", "1.0.0-1") == 1
