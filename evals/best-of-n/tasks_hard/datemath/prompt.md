Implement three functions in `datemath.py` (stdlib `datetime.date` only):

1. `add_months(d: date, n: int) -> date`: move `n` months (n may be negative). If the day does not exist in the
   target month, clamp to that month's last day. One extra rule: if `d` is the last day of its month, the result is
   the last day of the target month (`add_months(date(2024, 2, 29), 1)` is 2024-03-31, and
   `add_months(date(2023, 4, 30), 1)` is 2023-05-31).
2. `add_business_days(d: date, n: int, holidays=()) -> date`: business days are Mon-Fri not in `holidays`. For
   n > 0 step forward n business days; for n < 0 step back. For n == 0: return `d` if it is a business day, else the
   next business day after it. When `d` is not a business day and n > 0, counting starts from `d` as if it were the
   previous business day's close (so Saturday + 1 business day is Monday, Saturday - 1 is Friday).
3. `months_between(a: date, b: date) -> int`: the number of whole months from `a` to `b` (negative if b < a,
   computed as `-months_between(b, a)`). A month is complete when `add_months(a, k) <= b`, using the add_months rules
   above (so from Jan 31 to Feb 29 2024 is 1 month, and Jan 30 to Feb 28 2023 is 1, and Jan 30 to Feb 27 2023 is 0).
