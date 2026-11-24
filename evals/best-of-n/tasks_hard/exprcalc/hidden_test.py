from fractions import Fraction as F
from exprcalc import evaluate as e
import pytest_shim as t


def test_precedence():
    assert e("1 + 2 * 3") == 7 and e("(1+2)*3") == 9 and e("10 - 4 - 3") == 3 and e("2*3%4") == 2


def test_power():
    assert e("2**3**2") == 512 and e("-2**2") == -4 and e("(-2)**2") == 4 and e("2**-1") == F(1, 2)
    assert e("2**-2**2") == F(1, 16) and e("--3") == 3 and e("-+-3") == 3 and e("2 ** - 1") == F(1, 2)


def test_exact_types():
    r = e("6/3")
    assert r == 2 and type(r) is int
    assert e("1/3 + 1/6") == F(1, 2) and type(e("1/3 + 2/3")) is int
    assert e("(1/2) ** 2") == F(1, 4) and e("(4/2)**3") == 8 and type(e("(4/2)**3")) is int


def test_floor_ops():
    assert e("-7 // 2") == -4 and e("-7 % 3") == 2 and e("7 % -3") == -2
    assert e("(7/2) // 1") == 3 and e("(7/2) % 1") == F(1, 2) and e("-(7/2) // 1") == -4


def test_literals():
    assert e("1_000 + 2") == 1002 and e("  ( 3 ) ") == 3
    for bad in ["1__0", "_1", "1_", "1 * * 2", "", "(1", "1)", "1 2", "2 ** (1/2)", "2 ** 20000", "a", "1.5"]:
        t.raises(ValueError, e, bad)


def test_zero():
    for bad in ["1/0", "1//0", "1%0", "0**-1", "1/(2-2)"]:
        t.raises(ZeroDivisionError, e, bad)
    assert e("0**0") == 1
