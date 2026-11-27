import datetime

_MON = {n: i + 1 for i, n in enumerate("JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC".split())}
_DOW = {n: i for i, n in enumerate("SUN MON TUE WED THU FRI SAT".split())}
_RANGES = [(0, 59, {}), (0, 23, {}), (1, 31, {}), (1, 12, _MON), (0, 7, _DOW)]


def _num(tok, lo, hi, names):
    up = tok.upper()
    if up in names:
        return names[up]
    if not tok.isdigit():
        raise ValueError(tok)
    v = int(tok)
    if not lo <= v <= hi:
        raise ValueError(tok)
    return v


def _field(text, lo, hi, names):
    out = set()
    for item in text.split(","):
        if not item:
            raise ValueError("empty item")
        base, _, step = item.partition("/")
        if _ and (not step.isdigit() or int(step) == 0):
            raise ValueError(item)
        st = int(step) if _ else 1
        if base == "*":
            a, b = lo, hi
        elif "-" in base:
            x, _, y = base.partition("-")
            a, b = _num(x, lo, hi, names), _num(y, lo, hi, names)
            if a > b:
                raise ValueError(item)
        else:
            a = _num(base, lo, hi, names)
            b = hi if _ else a
        out.update(range(a, b + 1, st))
    return out


def next_fire(expr: str, after: datetime.datetime) -> datetime.datetime:
    fields = expr.split()
    if len(fields) != 5:
        raise ValueError("five fields")
    mins, hours, doms, mons, dows = (_field(f, *r) for f, r in zip(fields, _RANGES))
    if 7 in dows:
        dows = (dows - {7}) | {0}
    dom_r, dow_r = fields[2] != "*", fields[4] != "*"
    start = after.replace(second=0, microsecond=0) + datetime.timedelta(minutes=1)
    day = start.date()
    for _ in range(8 * 366 + 2):
        if day.month in mons:
            dm = day.day in doms
            dw = (day.isoweekday() % 7) in dows
            ok = (dm or dw) if (dom_r and dow_r) else (dm if dom_r else (dw if dow_r else True))
            if ok:
                for h in sorted(hours):
                    for m in sorted(mins):
                        cand = datetime.datetime(day.year, day.month, day.day, h, m)
                        if cand >= start:
                            return cand
        day += datetime.timedelta(days=1)
    raise ValueError("never fires")
