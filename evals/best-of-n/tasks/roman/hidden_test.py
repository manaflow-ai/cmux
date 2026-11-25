from roman import to_int, to_roman
import pytest_shim as t

def test_known():
    assert to_roman(1994) == "MCMXCIV" and to_int("MCMXCIV") == 1994 and to_roman(3999) == "MMMCMXCIX"
def test_roundtrip_all():
    for n in range(1, 4000):
        assert to_int(to_roman(n)) == n
def test_roman_range():
    for bad in [0, 4000, -1, True, 1.0]:
        t.raises(ValueError, to_roman, bad)
def test_noncanonical():
    for bad in ["IIII", "VV", "IC", "IL", "XM", "VX", "MMMM", "iv", "", "IIV", "XXC", "DD", "CMM", "IXI"]:
        t.raises(ValueError, to_int, bad)
