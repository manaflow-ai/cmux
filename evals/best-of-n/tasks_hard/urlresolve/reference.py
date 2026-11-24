import re

_RE = re.compile(r"^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?")


def _parse(u):
    m = _RE.match(u)
    return (m.group(2), m.group(4) if m.group(3) is not None else None, m.group(5),
            m.group(7) if m.group(6) is not None else None, m.group(9) if m.group(8) is not None else None)


def _remove_dots(path):
    inp, out = path, []
    while inp:
        if inp.startswith("../"):
            inp = inp[3:]
        elif inp.startswith("./"):
            inp = inp[2:]
        elif inp.startswith("/./"):
            inp = inp[2:]
        elif inp == "/.":
            inp = "/"
        elif inp.startswith("/../"):
            inp = inp[3:]
            if out:
                out.pop()
        elif inp == "/..":
            inp = "/"
            if out:
                out.pop()
        elif inp in (".", ".."):
            inp = ""
        else:
            start = 1 if inp.startswith("/") else 0
            j = inp.find("/", start)
            if j < 0:
                j = len(inp)
            out.append(inp[:j])
            inp = inp[j:]
    return "".join(out)


def resolve(base, ref):
    bs, ba, bp, bq, _ = _parse(base)
    if bs is None:
        raise ValueError("base not absolute")
    rs, ra, rp, rq, rf = _parse(ref)
    if rs is not None:
        ts, ta, tp, tq = rs, ra, _remove_dots(rp), rq
    else:
        ts = bs
        if ra is not None:
            ta, tp, tq = ra, _remove_dots(rp), rq
        else:
            ta = ba
            if rp == "":
                tp, tq = bp, (rq if rq is not None else bq)
            else:
                if rp.startswith("/"):
                    tp = _remove_dots(rp)
                else:
                    if ba is not None and bp == "":
                        merged = "/" + rp
                    else:
                        merged = bp[: bp.rfind("/") + 1] + rp
                    tp = _remove_dots(merged)
                tq = rq
    out = ts + ":"
    if ta is not None:
        out += "//" + ta
    out += tp
    if tq is not None:
        out += "?" + tq
    if rf is not None:
        out += "#" + rf
    return out
