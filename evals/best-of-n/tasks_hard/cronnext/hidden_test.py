import datetime as d
from cronnext import next_fire as n
import pytest_shim as t

D = d.datetime


def test_every_minute_and_seconds():
    assert n("* * * * *", D(2024, 1, 1, 10, 0, 30)) == D(2024, 1, 1, 10, 1)
    assert n("* * * * *", D(2024, 1, 1, 10, 0)) == D(2024, 1, 1, 10, 1)
    assert n("* * * * *", D(2024, 12, 31, 23, 59, 59, 999)) == D(2025, 1, 1, 0, 0)


def test_steps_and_ranges():
    assert n("*/15 * * * *", D(2024, 1, 1, 10, 46)) == D(2024, 1, 1, 11, 0)
    assert n("5/20 * * * *", D(2024, 1, 1, 10, 46)) == D(2024, 1, 1, 11, 5)
    assert n("10-20/5 9-17 * * *", D(2024, 1, 1, 17, 20)) == D(2024, 1, 2, 9, 10)
    assert n("0 0 */10 * *", D(2024, 1, 21, 1, 0)) == D(2024, 1, 31, 0, 0)


def test_names():
    assert n("0 9 * * mon-fri", D(2024, 6, 7, 9, 0)) == D(2024, 6, 10, 9, 0)  # Fri 9:00 -> Mon
    assert n("0 0 1 JAN,jul *", D(2024, 1, 1, 0, 0)) == D(2024, 7, 1, 0, 0)
    assert n("30 6 * * SAT,SUN", D(2024, 6, 3, 0, 0)) == D(2024, 6, 8, 6, 30)


def test_sunday_7():
    assert n("0 0 * * 7", D(2024, 6, 3)) == D(2024, 6, 9) and n("0 0 * * 0", D(2024, 6, 3)) == D(2024, 6, 9)
    assert n("0 0 * * 5-7", D(2024, 6, 3)) == D(2024, 6, 7)


def test_dom_dow_or():
    assert n("0 0 13 * FRI", D(2024, 9, 1)) == D(2024, 9, 6)  # a Friday before the 13th
    assert n("0 0 13 * FRI", D(2024, 9, 7)) == D(2024, 9, 13)
    assert n("0 0 */10 * MON", D(2024, 6, 3, 1)) == D(2024, 6, 10)  # step on dom is restricted: OR
    assert n("0 0 1 * *", D(2024, 6, 3)) == D(2024, 7, 1) and n("0 0 * * TUE", D(2024, 6, 3)) == D(2024, 6, 4)


def test_month_lengths():
    assert n("0 0 31 * *", D(2024, 4, 1)) == D(2024, 5, 31)
    assert n("0 12 29 2 *", D(2025, 3, 1)) == D(2028, 2, 29, 12)


def test_invalid():
    for e in ["* * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8", "5-1 * * * *",
              "*/0 * * * *", "1,,2 * * * *", "* * * * SAT-SUN", "* * * FOO *", "0 0 30 2 *", "a * * * *"]:
        t.raises(ValueError, n, e, D(2024, 1, 1))
