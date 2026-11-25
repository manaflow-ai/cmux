import re


def _strip_comment(v):
    m = re.search(r"[ \t][;#]", v)
    return (v[: m.start()] if m else v).strip()


def parse(text):
    raw = {}
    sec = "default"
    last = None
    for line in text.split("\n"):
        line = line[:-1] if line.endswith("\r") else line
        st = line.strip()
        if not st:
            last = None
            continue
        if st[0] in ";#":
            continue
        if line[0] in " \t":
            if last is None:
                raise ValueError("stray continuation")
            raw[sec][last] += "\n" + _strip_comment(st)
            continue
        if st.startswith("[") and st.endswith("]"):
            name = st[1:-1].strip().lower()
            if not name:
                raise ValueError("empty section")
            sec = name
            raw.setdefault(sec, {})
            last = None
            continue
        m = re.search(r"[=:]", line)
        if not m:
            raise ValueError("bad line %r" % line)
        key = line[: m.start()].strip().lower()
        if not key:
            raise ValueError("empty key")
        raw.setdefault(sec, {})[key] = _strip_comment(" " + line[m.end():])
        last = key
    defaults = raw.get("default", {})
    merged = {}
    for s, kv in raw.items():
        if s == "default":
            continue
        d = dict(defaults)
        d.update(kv)
        merged[s] = d
    if defaults:
        merged["default"] = dict(defaults)

    done = {}

    def get(s, k, stack):
        if (s, k) in done:
            return done[(s, k)]
        if (s, k) in stack:
            raise ValueError("cycle")
        if s not in merged or k not in merged[s]:
            raise ValueError("missing ${%s:%s}" % (s, k))
        v = merged[s][k]
        out, i = [], 0
        while i < len(v):
            c = v[i]
            if c != "$":
                out.append(c)
                i += 1
                continue
            if v[i + 1 : i + 2] == "$":
                out.append("$")
                i += 2
                continue
            if v[i + 1 : i + 2] != "{":
                raise ValueError("lone $")
            j = v.find("}", i)
            if j < 0:
                raise ValueError("unclosed ${")
            ref = v[i + 2 : j]
            rs, _, rk = ref.rpartition(":")
            rs = rs.strip().lower() if _ else s
            out.append(get(rs, rk.strip().lower(), stack | {(s, k)}))
            i = j + 1
        done[(s, k)] = "".join(out)
        return done[(s, k)]

    return {s: {k: get(s, k, frozenset()) for k in kv} for s, kv in merged.items()}
