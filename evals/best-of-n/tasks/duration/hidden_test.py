from duration import parse_duration as p
import pytest_shim as t

def test_simple():
    assert p("1h30m") == 5400 and p("2.5s") == 2.5 and p("250ms") == 0.25
def test_days_space():
    assert p("1d 2h") == 93600 and p("  3m  ") == 180
def test_m_vs_ms():
    assert p("1m500ms") == 60.5 and p("5ms") == 0.005
def test_fraction():
    assert p("1.5h") == 5400
def test_all_units():
    assert abs(p("1d1h1m1s1ms") - 90061.001) < 1e-9
def test_invalid():
    for bad in ["", "   ", "10", "1h1h", "1m1h", "-1s", "1x", "h", "1.s.", "1s 2"]:
        t.raises(ValueError, p, bad)
