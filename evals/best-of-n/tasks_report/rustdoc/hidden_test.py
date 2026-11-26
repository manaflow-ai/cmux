from rustdoc import doc

# Any escaping that makes rustdoc (CommonMark) show the text exactly as written passes: a backslash before ASCII
# punctuation escapes that character, a backslash before anything else is a literal backslash.
PUNCT = set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")


def shown(line, indent=""):
    """The text CommonMark shows for one generated doc line; AssertionError when a `[`, `]`, `<` or backquote is left
    unescaped (a link, HTML or a code span could start there)."""
    assert line.startswith(indent + "/// "), line
    body, out, i = line[len(indent) + 4:], [], 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body) and body[i + 1] in PUNCT:
            out.append(body[i + 1])
            i += 2
            continue
        assert c not in "[]<`", f"unescaped {c!r} in {line!r}"
        out.append(c)
        i += 1
    return "".join(out)


def one(text, indent=""):
    lines = doc(text, indent)
    assert len(lines) == 1, lines
    return shown(lines[0], indent)


def test_brackets_escaped():
    # 98570c7fbad: the [::1] in a host list became an intra-doc link.
    text = "hosts: localhost, [::1], <hex> and `code`"
    assert one(text, "    ") == text


def test_backslashes_show_as_written():
    for text in [r"a \[::1\] path C:\x", "\\", "\\`", "\\\\[x]", "ends with \\\\", r"\<b>"]:
        assert one(text) == text, text


def test_existing_behavior():
    assert doc("") == [] and doc(None) == []
    assert one("  one\n\ttwo   three ") == "one two three"
    assert one("a > b") == "a > b"
    assert one(42) == "42"
