import calendar
import datetime


def _last(y, m):
    return calendar.monthrange(y, m)[1]


def add_months(d, n):
    idx = d.year * 12 + (d.month - 1) + n
    y, m = divmod(idx, 12)
    m += 1
    last = _last(y, m)
    if d.day == _last(d.year, d.month):
        return datetime.date(y, m, last)
    return datetime.date(y, m, min(d.day, last))


def add_business_days(d, n, holidays=()):
    hol = set(holidays)

    def biz(x):
        return x.weekday() < 5 and x not in hol

    step = datetime.timedelta(days=1)
    if n == 0:
        while not biz(d):
            d += step
        return d
    sign = 1 if n > 0 else -1
    left = abs(n)
    while left:
        d += step * sign
        if biz(d):
            left -= 1
    return d


def months_between(a, b):
    if b < a:
        return -months_between(b, a)
    k = (b.year - a.year) * 12 + (b.month - a.month) + 1
    while k > 0 and add_months(a, k) > b:
        k -= 1
    return k
