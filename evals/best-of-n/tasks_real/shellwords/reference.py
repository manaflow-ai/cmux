import re

_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def _words(line):
    """Each word as a list of (char, quoted) pairs, quoted meaning it came from quotes or a backslash."""
    words, cur, in_word = [], [], False
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if c in " \t\n":
            if in_word:
                words.append(cur)
                cur, in_word = [], False
            i += 1
        elif c == "\\":
            if i + 1 >= n:
                raise ValueError("trailing backslash")
            if line[i + 1] != "\n":
                cur.append((line[i + 1], True))
                in_word = True
            i += 2
        elif c == "'":
            close = line.find("'", i + 1)
            if close < 0:
                raise ValueError("unclosed single quote")
            cur.append(("", True))  # an empty quote still counts as quoting
            cur.extend((ch, True) for ch in line[i + 1:close])
            in_word = True
            i = close + 1
        elif c == '"':
            cur.append(("", True))
            in_word = True
            i += 1
            while True:
                if i >= n:
                    raise ValueError("unclosed double quote")
                d = line[i]
                if d == '"':
                    i += 1
                    break
                if d == "\\" and i + 1 < n and line[i + 1] in '"\\$`\n':
                    if line[i + 1] != "\n":
                        cur.append((line[i + 1], True))
                    i += 2
                    continue
                cur.append((d, True))
                i += 1
        else:
            cur.append((c, False))
            in_word = True
            i += 1
    if in_word:
        words.append(cur)
    return words


def _is_assignment(chars):
    i = 0
    while i < len(chars) and not chars[i][1] and chars[i][0].isascii() and (chars[i][0].isalnum() or chars[i][0] == "_"):
        i += 1
    if not _NAME.fullmatch("".join(c for c, _ in chars[:i])):
        return False
    if i < len(chars) and chars[i] == ("[", False):
        j = i + 1
        while j < len(chars) and chars[j] != ("]", False):
            j += 1
        if j >= len(chars) or j == i + 1:
            return False
        i = j + 1
    if i < len(chars) and chars[i] == ("=", False):
        return True
    return i + 1 < len(chars) and chars[i] == ("+", False) and chars[i + 1] == ("=", False)


def split_command(line):
    words = _words(line)
    k = 0
    while k < len(words) and _is_assignment(words[k]):
        k += 1
    text = lambda w: "".join(c for c, _ in w)  # noqa: E731
    return [text(w) for w in words[:k]], [text(w) for w in words[k:]]
