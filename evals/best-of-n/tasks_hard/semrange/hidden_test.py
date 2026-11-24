from semrange import satisfies as s
import pytest_shim as t


def test_exact_and_build():
    assert s("1.2.3", "1.2.3") and s("1.2.3+b5", "=1.2.3") and s("v1.2.3", "1.2.3") and not s("1.2.4", "1.2.3")


def test_partials():
    assert s("1.2.9", "1.2") and not s("1.3.0", "1.2.x") and s("1.9.9", "1") and not s("2.0.0", "1.*")
    assert s("0.0.1", "*") and s("5.0.0", "") and s("3.1.4", ">=*")


def test_operators_with_partials():
    assert not s("1.2.9", ">1.2") and s("1.3.0", ">1.2") and s("2.0.0", ">1") and not s("1.9.0", ">1")
    assert s("1.2.9", "<=1.2") and not s("1.3.0", "<=1.2") and not s("1.2.0", "<1.2") and s("1.1.9", "<1.2")
    assert s("1.9.9", "<=1") and not s("2.0.0", "<=1") and s("1.2.0", ">=1.2")


def test_space_after_operator_and_and_sets():
    assert s("1.5.0", ">= 1.2.3 < 2") and not s("2.0.0", ">= 1.2.3 < 2") and s("1.2.3", ">=1.2.3 <=1.2.3")


def test_tilde():
    assert s("1.2.9", "~1.2.3") and not s("1.3.0", "~1.2.3") and not s("1.2.2", "~1.2.3")
    assert s("1.2.0", "~1.2") and s("1.9.0", "~1") and not s("2.0.0", "~1")


def test_caret():
    assert s("1.9.9", "^1.2.3") and not s("2.0.0", "^1.2.3") and s("0.2.9", "^0.2.3") and not s("0.3.0", "^0.2.3")
    assert s("0.0.3", "^0.0.3") and not s("0.0.4", "^0.0.3") and s("1.9.0", "^1.2") and not s("1.1.0", "^1.2")
    assert s("0.0.9", "^0.0") and not s("0.1.0", "^0.0") and s("0.9.9", "^0") and not s("1.0.0", "^0")
    assert s("1.5.0", "^1.x")


def test_hyphen():
    assert s("2.3.4", "1.2.3 - 2.3.4") and not s("2.3.5", "1.2.3 - 2.3.4") and s("1.2.0", "1.2 - 2.3.4")
    assert s("2.3.9", "1.2.3 - 2.3") and not s("2.4.0", "1.2.3 - 2.3") and s("2.9.9", "1.2.3 - 2")
    assert not s("3.0.0", "1.2.3 - 2") and not s("1.2.2", "1.2.3 - 2")


def test_or():
    assert s("3.0.0", "^1.0.0 || ^3.0.0") and not s("2.0.0", "^1.0.0 || ^3.0.0") and s("1.0.0", "<0.5.0 || 1.0.0")


def test_prerelease_order():
    order = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
             "1.0.0-rc.1", "1.0.0"]
    for lo, hi in zip(order, order[1:]):
        assert s(lo, "<" + hi + " >=1.0.0-0") and not s(hi, "<" + lo) and s(hi, ">" + lo), (lo, hi)


def test_prerelease_rule():
    assert not s("1.2.4-alpha", ">=1.2.3") and not s("2.0.0-rc.1", "^1.0.0") and not s("1.0.0-rc.1", "*")
    assert s("1.2.3-beta.4", ">=1.2.3-beta.2 <1.3.0") and not s("1.2.4-beta.4", ">=1.2.3-beta.2 <1.3.0")
    assert s("1.2.3-beta.4", "^1.2.3-beta.2") and not s("1.2.3-beta.1", "^1.2.3-beta.2")
    assert s("1.2.3-beta.4", "<1.0.0 || >=1.2.3-beta.1") and not s("1.2.3-beta.4", "")


def test_invalid():
    for v, r in [("1.2", "1.2.3"), ("01.2.3", "*"), ("1.2.3", "1.02.3"), ("1.2.3", "!1.2.3"), ("1.2.3", "1.2.3 -2.0.0"),
                 ("1.2.3", ">=a"), ("1.2.3-01", "*"), ("x.y.z", "*")]:
        t.raises(ValueError, s, v, r)
