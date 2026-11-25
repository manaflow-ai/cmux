import re

_NUM = r"(?:0|[1-9]\d*)"
_ID = r"[0-9A-Za-z-]+"
_FULL = re.compile(rf"^[v=]?({_NUM})\.({_NUM})\.({_NUM})(?:-({_ID}(?:\.{_ID})*))?(?:\+({_ID}(?:\.{_ID})*))?$")
_XR = r"(?:x|X|\*|" + _NUM + ")"
_PART = re.compile(rf"^[v=]?({_XR})(?:\.({_XR})(?:\.({_XR})(?:-({_ID}(?:\.{_ID})*))?(?:\+({_ID}(?:\.{_ID})*))?)?)?$")


def _pre_ok(pre):
    for p in pre:
        if p.isdigit() and len(p) > 1 and p[0] == "0":
            raise ValueError("leading zero in prerelease")


def parse(v):
    m = _FULL.match(v.strip())
    if not m:
        raise ValueError(v)
    pre = tuple(m.group(4).split(".")) if m.group(4) else ()
    _pre_ok(pre)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), pre)


def _cmp_pre(a, b):
    if a == b:
        return 0
    if not a:
        return 1
    if not b:
        return -1
    for x, y in zip(a, b):
        if x == y:
            continue
        xd, yd = x.isdigit(), y.isdigit()
        if xd and yd:
            return -1 if int(x) < int(y) else 1
        if xd != yd:
            return -1 if xd else 1
        return -1 if x < y else 1
    return -1 if len(a) < len(b) else 1


def cmp(a, b):
    if a[:3] != b[:3]:
        return -1 if a[:3] < b[:3] else 1
    return _cmp_pre(a[3], b[3])


def _partial(s):
    m = _PART.match(s)
    if not m:
        raise ValueError(s)
    parts = []
    for g in m.groups()[:3]:
        if g is None or g in ("x", "X", "*"):
            break
        parts.append(int(g))
    pre = tuple(m.group(4).split(".")) if m.group(4) and len(parts) == 3 else ()
    _pre_ok(pre)
    # a wildcard followed by numbers (1.x.3) is accepted as 1.x
    return parts, pre


def _v(parts, pre=()):
    p = list(parts) + [0] * (3 - len(parts))
    return (p[0], p[1], p[2], pre)


def _bump(parts):
    # the next version up from a partial: 1 -> 2.0.0, 1.2 -> 1.3.0
    if len(parts) == 1:
        return (parts[0] + 1, 0, 0, ())
    return (parts[0], parts[1] + 1, 0, ())


def _expand(op, s):
    parts, pre = _partial(s)
    if not parts:
        return []
    full = len(parts) == 3
    if op in ("", "="):
        if full:
            return [("=", _v(parts, pre))]
        return [(">=", _v(parts)), ("<", _bump(parts))]
    if op == ">":
        return [(">", _v(parts, pre))] if full else [(">=", _bump(parts))]
    if op == ">=":
        return [(">=", _v(parts, pre))]
    if op == "<":
        return [("<", _v(parts, pre))]
    if op == "<=":
        return [("<=", _v(parts, pre))] if full else [("<", _bump(parts))]
    if op == "~":
        lo = _v(parts, pre)
        hi = (parts[0] + 1, 0, 0, ()) if len(parts) == 1 else (parts[0], parts[1] + 1, 0, ())
        return [(">=", lo), ("<", hi)]
    if op == "^":
        lo = _v(parts, pre)
        p = list(parts)
        if p[0] != 0 or len(p) == 1:
            hi = (p[0] + 1, 0, 0, ())
        elif len(p) == 2 or p[1] != 0:
            hi = (0, p[1] + 1, 0, ())
        else:
            hi = (0, 0, p[2] + 1, ())
        return [(">=", lo), ("<", hi)]
    raise ValueError(op)


_OPS = ("<=", ">=", "<", ">", "=", "~", "^")


def _set(text):
    toks = text.split()
    out = []
    if len(toks) == 3 and toks[1] == "-":
        lo_parts, lo_pre = _partial(toks[0])
        hi_parts, hi_pre = _partial(toks[2])
        if lo_parts:
            out.append((">=", _v(lo_parts, lo_pre)))
        if len(hi_parts) == 3:
            out.append(("<=", _v(hi_parts, hi_pre)))
        elif hi_parts:
            out.append(("<", _bump(hi_parts)))
        return out
    if "-" in toks and len(toks) != 3:
        raise ValueError(text)
    i = 0
    while i < len(toks):
        t = toks[i]
        op = next((o for o in _OPS if t.startswith(o)), "")
        rest = t[len(op):]
        if op and not rest:
            i += 1
            if i >= len(toks):
                raise ValueError(text)
            rest = toks[i]
        if not rest or rest[0] in "<>=~^":
            raise ValueError(text)
        out.extend(_expand(op, rest))
        i += 1
    return out


def _holds(v, op, c):
    r = cmp(v, c)
    return {"=": r == 0, "<": r < 0, "<=": r <= 0, ">": r > 0, ">=": r >= 0}[op]


def satisfies(version: str, range_: str) -> bool:
    v = parse(version)
    sets = [_set(s) for s in range_.split("||")]
    for comps in sets:
        if not all(_holds(v, op, c) for op, c in comps):
            continue
        if v[3] and not any(c[3] and c[:3] == v[:3] for _, c in comps):
            continue
        return True
    return False
