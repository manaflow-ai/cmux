Implement `evaluate(src: str) -> int | fractions.Fraction` in `exprcalc.py`: an exact arithmetic evaluator (no
`eval`, no floats). Grammar, loosest to tightest:

- `+` and `-` (left-assoc), then `*`, `/`, `//`, `%` (left-assoc), then unary `+`/`-` (prefix, may repeat: `--3`
  is 3), then `**` (RIGHT-assoc, and it binds tighter than unary minus on its left but its right operand may itself
  start with unary minus: `-2**2` is -4, `2**-1` is 1/2, `2**3**2` is 512), then atoms: non-negative integer
  literals (digits, `_` allowed between digits: `1_000`), parenthesised expressions.
- Whitespace anywhere between tokens.

Values are exact: integers stay `int`; `/` gives a `Fraction`, and any result whose denominator is 1 is returned as
`int` (`6/3` returns `2` of type int, also for intermediate values). `//` and `%` follow Python's floor semantics,
also for Fractions. `**` with a negative integer exponent gives a Fraction; a non-integer exponent raises ValueError.

Raise ZeroDivisionError for division, `//` or `%` by zero and for `0 ** -n`. Raise ValueError for any syntax error
(empty input, unbalanced parens, trailing tokens, `1__0`, `_1`, `1_`, two operators like `1 * * 2`, an exponent
whose absolute value exceeds 10000).
