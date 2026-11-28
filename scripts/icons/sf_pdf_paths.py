#!/usr/bin/env python3
"""Reads the vector paths out of the SF Symbol PDFs export_sf_symbols.swift writes (CGContext PDF pages), as
absolute SVG path data in the page's top-left coordinates. Usage: pdf2path.py DIR > paths.json"""
import json, re, sys, zlib, os

def objects(data):
    objs = {}
    for m in re.finditer(rb"(\d+) 0 obj(.*?)endobj", data, re.S):
        objs[int(m.group(1))] = m.group(2)
    return objs

def stream_of(body):
    m = re.search(rb"stream\r?\n(.*)\r?\nendstream", body, re.S)
    if not m:
        return None
    raw = m.group(1)
    if b"/FlateDecode" in body[: body.find(b"stream")]:
        return zlib.decompress(raw)
    return raw

def dict_part(body):
    i = body.find(b"stream")
    return body if i < 0 else body[:i]

def resolve_xobjects(objs, dict_bytes):
    out = {}
    m = re.search(rb"/XObject\s*(\d+) 0 R", dict_bytes)
    if m:
        dict_bytes = objs[int(m.group(1))]
    m = re.search(rb"/XObject\s*<<(.*?)>>", dict_bytes, re.S)
    if m:
        for name, num in re.findall(rb"/(\S+?)\s+(\d+) 0 R", m.group(1)):
            out[name.decode()] = int(num)
    return out

def resources_of(objs, dict_bytes):
    m = re.search(rb"/Resources\s*(\d+) 0 R", dict_bytes)
    if m:
        return objs[int(m.group(1))]
    m = re.search(rb"/Resources\s*(<<.*>>)", dict_bytes, re.S)
    return m.group(1) if m else b""

def mul(a, b):
    a0, a1, a2, a3, a4, a5 = a
    b0, b1, b2, b3, b4, b5 = b
    return (a0 * b0 + a1 * b2, a0 * b1 + a1 * b3, a2 * b0 + a3 * b2, a2 * b1 + a3 * b3,
            a4 * b0 + a5 * b2 + b4, a4 * b1 + a5 * b3 + b5)

def apply(m, x, y):
    return (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])

TOK = re.compile(rb"/[^\s/\[\]()<>]+|-?\d*\.?\d+(?:[eE]-?\d+)?|[A-Za-z'\"*]+|\[|\]|<<|>>|\([^)]*\)")

def run(objs, content, resources, ctm, fills, depth=0):
    xobjs = resolve_xobjects(objs, resources)
    stack = []
    path = []
    cur = None
    gs = [ctm]
    m = ctm
    for t in TOK.findall(content):
        try:
            stack.append(float(t))
            continue
        except ValueError:
            pass
        op = t.decode(errors="replace")
        if op.startswith("/"):
            stack.append(op[1:])
            continue
        n = stack
        if op == "q":
            gs.append(m)
        elif op == "Q":
            m = gs.pop() if len(gs) > 1 else ctm
        elif op == "cm":
            m = mul(tuple(n[-6:]), m)
        elif op == "m":
            cur = apply(m, n[-2], n[-1]); path.append(("M", cur))
        elif op == "l":
            cur = apply(m, n[-2], n[-1]); path.append(("L", cur))
        elif op == "c":
            p = [apply(m, n[-6], n[-5]), apply(m, n[-4], n[-3]), apply(m, n[-2], n[-1])]
            path.append(("C", *p)); cur = p[2]
        elif op == "v":
            p = [cur, apply(m, n[-4], n[-3]), apply(m, n[-2], n[-1])]
            path.append(("C", *p)); cur = p[2]
        elif op == "y":
            p = [apply(m, n[-4], n[-3]), apply(m, n[-2], n[-1]), apply(m, n[-2], n[-1])]
            path.append(("C", *p)); cur = p[2]
        elif op == "h":
            path.append(("Z",))
        elif op == "re":
            x, y, w, h = n[-4:]
            path += [("M", apply(m, x, y)), ("L", apply(m, x + w, y)), ("L", apply(m, x + w, y + h)),
                     ("L", apply(m, x, y + h)), ("Z",)]
        elif op in ("f", "F", "f*", "B", "B*", "b", "b*"):
            if path:
                fills.append({"rule": "evenodd" if op.endswith("*") else "nonzero", "path": path})
            path = []
        elif op in ("n", "S", "s"):
            if op != "n" and path:
                fills.append({"rule": "stroke", "path": path})
            path = []
        elif op == "Do":
            name = n[-1]
            num = xobjs.get(name)
            if num is not None and depth < 8:
                body = objs[num]
                d = dict_part(body)
                if b"/Form" in d:
                    fm = re.search(rb"/Matrix\s*\[([^\]]*)\]", d)
                    fmat = tuple(float(v) for v in fm.group(1).split()) if fm else (1, 0, 0, 1, 0, 0)
                    run(objs, stream_of(body) or b"", resources_of(objs, d) or d, mul(fmat, m), fills, depth + 1)
                elif b"/Image" in d:
                    fills.append({"rule": "image"})
        if op.isalpha() or op in ("f*", "B*", "b*", "'", '"'):
            stack = []
    return fills

def page(path):
    data = open(path, "rb").read()
    objs = objects(data)
    for num, body in objs.items():
        d = dict_part(body)
        if re.search(rb"/Type\s*/Page[^s]", d):
            # A page may inherit its MediaBox from its /Pages parent (CoreGraphics writes it there).
            mb = re.search(rb"/MediaBox\s*\[([^\]]*)\]", d) or re.search(rb"/MediaBox\s*\[([^\]]*)\]", data)
            box = [float(v) for v in mb.group(1).split()]
            cm = re.search(rb"/Contents\s*(\d+) 0 R", d)
            content = stream_of(objs[int(cm.group(1))])
            res = resources_of(objs, d)
            fills = run(objs, content, res, (1, 0, 0, 1, 0, 0), [])
            return box, fills
    raise SystemExit(f"no page in {path}")

def svg(path_ops, height):
    out = []
    f = lambda p: f"{p[0]:.3f} {height - p[1]:.3f}"
    for op in path_ops:
        if op[0] == "Z":
            out.append("Z")
        elif op[0] in "ML":
            out.append(f"{op[0]}{f(op[1])}")
        else:
            out.append("C" + " ".join(f(p) for p in op[1:]))
    return " ".join(out)

result = {}
d = sys.argv[1]
for name in sorted(os.listdir(d)):
    if not name.endswith(".pdf"):
        continue
    box, fills = page(os.path.join(d, name))
    h = box[3]
    result[name[:-4]] = {
        "width": box[2], "height": h,
        "layers": [{"rule": x["rule"], "d": svg(x["path"], h) if "path" in x else ""} for x in fills],
    }
json.dump(result, sys.stdout, indent=1)
