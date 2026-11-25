Implement `parse_duration(text: str) -> float` in `duration.py`: parse a duration like `1h30m`, `2.5s`, `1d 2h`,
`250ms` into seconds. Units: `d`, `h`, `m`, `s`, `ms` (so `m` is minutes and `ms` milliseconds). A number may have a
fractional part (`1.5h`). Components may be separated by whitespace or nothing, each unit at most once, and in
descending order (d, h, m, s, ms). Leading/trailing whitespace is allowed. Raise ValueError for an empty string, a bare
number with no unit, a repeated unit, units out of order, a negative number, or any other text.
