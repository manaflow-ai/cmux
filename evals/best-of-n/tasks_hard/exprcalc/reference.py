import re
from fractions import Fraction

_TOK = re.compile(r"\s*(?:(\d(?:_?\d)*)(?![\d_])|(\*\*|//|[-+*/%()]))")


def _norm(v):
    if isinstance(v, Fraction) and v.denominator == 1:
        return int(v)
    return v


def _lex(src):
    pos, out = 0, []
    while True:
        m = re.compile(r"\s*").match(src, pos)
        pos = m.end()
        if pos == len(src):
            return out
        m = _TOK.match(src, pos)
        if not m:
            raise ValueError("bad token at %d" % pos)
        out.append(("n", int(m.group(1).replace("_", ""))) if m.group(1) else ("op", m.group(2)))
        pos = m.end()


def evaluate(src: str):
    toks = _lex(src)
    i = 0

    def peek():
        return toks[i][1] if i < len(toks) and toks[i][0] == "op" else None

    def take():
        nonlocal i
        i += 1
        return toks[i - 1]

    def expr():
        v = term()
        while peek() in ("+", "-"):
            op = take()[1]
            r = term()
            v = _norm(v + r if op == "+" else v - r)
        return v

    def term():
        v = unary()
        while peek() in ("*", "/", "//", "%"):
            op = take()[1]
            r = unary()
            if op == "*":
                v = v * r
            elif op == "/":
                if r == 0:
                    raise ZeroDivisionError
                v = Fraction(v) / r
            elif op == "//":
                v = v // r
            else:
                v = v % r
            v = _norm(v)
        return v

    def unary():
        if peek() in ("+", "-"):
            op = take()[1]
            v = unary()
            return -v if op == "-" else v
        return power()

    def power():
        b = atom()
        if peek() == "**":
            take()
            e = unary()
            if not isinstance(e, int):
                raise ValueError("non-integer exponent")
            if abs(e) > 10000:
                raise ValueError("exponent too large")
            if e < 0:
                if b == 0:
                    raise ZeroDivisionError
                return _norm(Fraction(1) / Fraction(b) ** -e)
            return _norm(b ** e)
        return b

    def atom():
        if i >= len(toks):
            raise ValueError("unexpected end")
        t = take()
        if t[0] == "n":
            return t[1]
        if t[1] == "(":
            v = expr()
            if peek() != ")":
                raise ValueError("missing )")
            take()
            return v
        raise ValueError("unexpected %s" % t[1])

    v = expr()
    if i != len(toks):
        raise ValueError("trailing tokens")
    return _norm(v)
