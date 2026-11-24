import re

_NUMBER = re.compile(r"[+-]?[0-9]+(\.[0-9]+)?\Z")


def _risky(first, cell, quoted):
    if first in "=@\t":
        return True
    if first == "\r":
        return quoted
    if first in "+-":
        return not _NUMBER.match(cell)
    return False


def defuse_formulas(body: str) -> str:
    out = []
    at_start, quoted = True, False
    i, n = 0, len(body)
    while i < n:
        ch = body[i]
        if at_start:
            at_start = False
            if ch == '"':
                quoted = True
                out.append('"')
                end = body.find('"', i + 1)
                cell = body[i + 1:] if end < 0 else body[i + 1:end]
                if cell and _risky(cell[0], cell, True):
                    out.append("'")
                i += 1
                continue
            m = re.compile(r"[,\r\n]").search(body, i)
            cell = body[i:m.start() if m else n]
            if _risky(ch, cell, False):
                out.append("'")
        if quoted:
            if ch == '"':
                if i + 1 < n and body[i + 1] == '"':
                    out.append('""')
                    i += 2
                    continue
                quoted = False
        elif ch in ",\r\n":
            at_start = True
        out.append(ch)
        i += 1
    return "".join(out)
