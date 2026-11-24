import copy
import re


class PatchError(Exception):
    pass


def _tokens(path):
    if path == "":
        return []
    if not isinstance(path, str) or not path.startswith("/"):
        raise PatchError("bad path %r" % (path,))
    out = []
    for raw in path[1:].split("/"):
        if re.search(r"~(?![01])", raw):
            raise PatchError("bad escape")
        out.append(raw.replace("~1", "/").replace("~0", "~"))
    return out


def _index(tok, n, allow_end):
    if tok == "-" and allow_end:
        return n
    if not re.fullmatch(r"0|[1-9][0-9]*", tok):
        raise PatchError("bad index %r" % tok)
    i = int(tok)
    if i > n or (i == n and not allow_end):
        raise PatchError("index out of range")
    return i


def _parent(doc, toks):
    cur = doc
    for t in toks[:-1]:
        if isinstance(cur, dict):
            if t not in cur:
                raise PatchError("missing %r" % t)
            cur = cur[t]
        elif isinstance(cur, list):
            cur = cur[_index(t, len(cur), False)]
        else:
            raise PatchError("through scalar")
    return cur


def _get(doc, toks):
    if not toks:
        return doc
    par = _parent(doc, toks)
    t = toks[-1]
    if isinstance(par, dict):
        if t not in par:
            raise PatchError("missing")
        return par[t]
    if isinstance(par, list):
        return par[_index(t, len(par), False)]
    raise PatchError("through scalar")


def _add(doc, toks, val):
    if not toks:
        return val
    par = _parent(doc, toks)
    t = toks[-1]
    if isinstance(par, dict):
        par[t] = val
    elif isinstance(par, list):
        par.insert(_index(t, len(par), True), val)
    else:
        raise PatchError("through scalar")
    return doc


def _remove(doc, toks):
    if not toks:
        raise PatchError("remove root")
    par = _parent(doc, toks)
    t = toks[-1]
    if isinstance(par, dict):
        if t not in par:
            raise PatchError("missing")
        return par.pop(t)
    if isinstance(par, list):
        return par.pop(_index(t, len(par), False))
    raise PatchError("through scalar")


def _eq(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_eq(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_eq(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def _need(op, key):
    if key not in op:
        raise PatchError("missing %s" % key)
    return op[key]


def apply_patch(doc, patch):
    doc = copy.deepcopy(doc)
    for op in patch:
        if not isinstance(op, dict):
            raise PatchError("op not object")
        kind = _need(op, "op")
        path = _tokens(_need(op, "path"))
        if kind == "add":
            doc = _add(doc, path, copy.deepcopy(_need(op, "value")))
        elif kind == "remove":
            _remove(doc, path)
        elif kind == "replace":
            val = copy.deepcopy(_need(op, "value"))
            if not path:
                doc = val
            else:
                _get(doc, path)
                _remove(doc, path)
                doc = _add(doc, path, val) if not isinstance(_parent(doc, path), list) else _ins(doc, path, val)
        elif kind == "move":
            frm = _tokens(_need(op, "from"))
            if frm == path:
                _get(doc, frm)
                continue
            if path[: len(frm)] == frm:
                raise PatchError("move into own child")
            val = _remove(doc, frm)
            doc = _add(doc, path, val)
        elif kind == "copy":
            frm = _tokens(_need(op, "from"))
            doc = _add(doc, path, copy.deepcopy(_get(doc, frm)))
        elif kind == "test":
            if not _eq(_get(doc, path), _need(op, "value")):
                raise PatchError("test failed")
        else:
            raise PatchError("unknown op %r" % kind)
    return doc


def _ins(doc, toks, val):
    par = _parent(doc, toks)
    par.insert(_index(toks[-1], len(par), True), val)
    return doc
