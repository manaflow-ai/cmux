def split(s: str) -> list:
    words, cur, in_word = [], [], False
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c in " \t\n":
            if in_word:
                words.append("".join(cur))
                cur, in_word = [], False
            i += 1
        elif c == "#" and not in_word:
            while i < n and s[i] != "\n":
                i += 1
        elif c == "\\":
            if i + 1 >= n:
                raise ValueError("trailing backslash")
            if s[i + 1] == "\n":
                i += 2
                continue
            cur.append(s[i + 1])
            in_word = True
            i += 2
        elif c == "'":
            j = s.find("'", i + 1)
            if j < 0:
                raise ValueError("unterminated '")
            cur.append(s[i + 1 : j])
            in_word = True
            i = j + 1
        elif c == '"':
            i += 1
            in_word = True
            while True:
                if i >= n:
                    raise ValueError('unterminated "')
                c = s[i]
                if c == '"':
                    i += 1
                    break
                if c == "\\" and i + 1 < n and s[i + 1] in '$`"\\\n':
                    if s[i + 1] != "\n":
                        cur.append(s[i + 1])
                    i += 2
                    continue
                cur.append(c)
                i += 1
        else:
            cur.append(c)
            in_word = True
            i += 1
    if in_word:
        words.append("".join(cur))
    return words
