import re
from fractions import Fraction

_DEC = re.compile(r"\s*[+-]?(\d+(\.\d*)?|\.\d+)\s*$")


def _ratio(r):
    if isinstance(r, bool) or isinstance(r, float):
        raise ValueError("bad ratio type")
    if isinstance(r, str):
        if not _DEC.match(r):
            raise ValueError("bad ratio %r" % r)
        r = Fraction(r.strip())
    elif isinstance(r, (int, Fraction)):
        r = Fraction(r)
    else:
        raise ValueError("bad ratio type")
    if r < 0:
        raise ValueError("negative ratio")
    return r


def allocate(total_cents, ratios):
    if isinstance(total_cents, bool) or not isinstance(total_cents, int):
        raise TypeError("total must be int")
    if not ratios:
        raise ValueError("empty")
    rs = [_ratio(r) for r in ratios]
    s = sum(rs)
    if s == 0:
        raise ValueError("all zero")
    if total_cents < 0:
        return [-x for x in allocate(-total_cents, ratios)]
    shares = [total_cents * r / s for r in rs]
    parts = [x.numerator // x.denominator for x in shares]
    left = total_cents - sum(parts)
    order = sorted(range(len(rs)), key=lambda i: (-(shares[i] - parts[i]), -rs[i], i))
    for i in order[:left]:
        parts[i] += 1
    return parts
