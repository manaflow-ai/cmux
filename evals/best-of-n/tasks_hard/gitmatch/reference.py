import re


def _strip_trailing(line):
    while line.endswith(" ") and not line.endswith("\\ "):
        line = line[:-1]
    return line


def _glob_to_re(pat):
    out, i, n = [], 0, len(pat)
    while i < n:
        c = pat[i]
        if pat.startswith("**/", i) and (i == 0 or pat[i - 1] == "/"):
            out.append("(?:.*/)?")
            i += 3
        elif pat.startswith("/**", i) and i + 3 == n:
            out.append("/.*")
            i += 3
        elif c == "*":
            while i < n and pat[i] == "*":
                i += 1
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
            i += 1
        elif c == "\\" and i + 1 < n:
            out.append(re.escape(pat[i + 1]))
            i += 2
        elif c == "[":
            j = i + 1
            if j < n and pat[j] in "!^":
                j += 1
            if j < n and pat[j] == "]":
                j += 1
            while j < n and pat[j] != "]":
                j += 1
            if j >= n:
                out.append(re.escape(c))
                i += 1
                continue
            body = pat[i + 1 : j]
            neg = body[:1] in ("!", "^")
            if neg:
                body = body[1:]
            body = body.replace("\\", "\\\\")
            out.append("[" + ("^/" if neg else "") + body + "]" if not neg else "[^/" + body + "]")
            i = j + 1
        else:
            out.append(re.escape(c))
            i += 1
    return "".join(out)


def _compile(lines):
    rules = []
    for raw in lines:
        line = _strip_trailing(raw)
        if not line or line.startswith("#"):
            continue
        neg = False
        if line.startswith("!"):
            neg, line = True, line[1:]
        elif line.startswith("\\!") or line.startswith("\\#"):
            line = line[1:]
        dir_only = line.endswith("/") and not line.endswith("\\/")
        if dir_only:
            line = line.rstrip("/")
        if not line:
            continue
        anchored = "/" in line
        line = line.lstrip("/") if line.startswith("/") else line
        rx = re.compile(_glob_to_re(line) + r"\Z", re.S)
        rules.append((rx, neg, dir_only, anchored))
    return rules


def _match(rules, path, is_dir):
    result = False
    base = path.rsplit("/", 1)[-1]
    for rx, neg, dir_only, anchored in rules:
        if dir_only and not is_dir:
            continue
        if rx.match(path if anchored else base):
            result = not neg
    return result


def is_ignored(patterns, path, is_dir=False):
    rules = _compile(patterns)
    parts = path.split("/")
    for k in range(1, len(parts)):
        if _match(rules, "/".join(parts[:k]), True):
            return True
    return _match(rules, path, is_dir)
