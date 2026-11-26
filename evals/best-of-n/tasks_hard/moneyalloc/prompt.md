Implement `allocate(total_cents: int, ratios: list) -> list[int]` in `moneyalloc.py`: split an integer amount of
cents into parts proportional to `ratios`, exactly, with the largest remainder method.

- Ratios are non-negative ints, `fractions.Fraction`s or decimal strings like `"0.333"` (convert strings with
  `fractions.Fraction(str)`, never through float). Each part's exact share is `total * r / sum(ratios)`.
- Every part starts at the floor of its share (floor toward negative infinity). The leftover cents go one each to the
  parts with the largest fractional remainder. Ties go first to the part with the larger ratio, then to the lower
  index.
- A negative total is allocated as the negation of allocating its absolute value (so `allocate(-5, [1, 1])` is
  `[-3, -2]`, the mirror of `[3, 2]`).
- A part whose ratio is 0 always gets 0. The parts always sum to `total_cents`.
- A decimal string is an optional sign, then digits with an optional fractional part (`"3"`, `"0.333"`, `".5"`,
  `"2."`), with optional surrounding whitespace. Exponent forms such as `"1e3"`, and `"inf"` or `"nan"`, are not
  decimal numbers.
- Raise ValueError for an empty list, a negative ratio, all ratios zero, a bool or float ratio, or a string that is
  not a decimal number. Raise TypeError if `total_cents` is not an int (bools are not ints here).
