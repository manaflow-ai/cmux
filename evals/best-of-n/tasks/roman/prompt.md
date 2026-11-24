Implement `to_int(s: str) -> int` and `to_roman(n: int) -> str` in `roman.py` for standard Roman numerals 1..3999.
`to_roman` uses the canonical subtractive form (4 = IV, 9 = IX, 40 = XL, 90 = XC, 400 = CD, 900 = CM) and raises
ValueError outside 1..3999 (and for non-int input, including bool). `to_int` accepts only canonical numerals, the
exact strings `to_roman` produces, uppercase only, and raises ValueError for anything else: `IIII`, `VV`, `IC`, `IL`,
`XM`, `VX`, `MMMM`, `iv`, the empty string.
