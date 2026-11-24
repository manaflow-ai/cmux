import base64

from oscparse import OscParser, Text, Cwd, Hyperlink, Clipboard, Prompt

ST = b"\x1b\\"


def norm(events):
    """Merge adjacent Text events; drop empty ones."""
    out = []
    for e in events:
        if isinstance(e, Text):
            if not e.text:
                continue
            if out and isinstance(out[-1], Text):
                out[-1] = Text(out[-1].text + e.text)
                continue
        out.append(e)
    return out


def run(*chunks):
    p = OscParser()
    events = []
    for c in chunks:
        events.extend(p.feed(c))
    return norm(events)


STREAM = (
    "héllo ✓ ".encode()
    + b"\x1b]7;file://mac/Users/leo/my%20src" + ST
    + b"\x1b[1;32m$\x1b[0m "
    + b"\x1b]8;id=42:x=y;https://cmux.dev/a\x07link\x1b]8;;\x07"
    + b"\x1b]133;D;2" + ST
    + b"\x1b]52;c;" + base64.b64encode("copié".encode()) + b"\x07"
    + b"\x1b\x1b]133;A\x07"
    + b"\x1b]999;ignored\x07"
    + "日本語 done\n".encode()
)


def test_reported_st_split_after_esc():
    assert run(b"\x1b]7;file://mac/Users/leo/src/cmux\x1b", b"\\$ ") == [
        Cwd("mac", "/Users/leo/src/cmux"), Text("$ ")]


def test_osc_start_split_between_esc_and_bracket():
    assert run(b"ls\x1b", b"]133;A\x07ok") == [Text("ls"), Prompt("A"), Text("ok")]


def test_utf8_character_split_across_reads():
    data = "✓ héllo".encode()
    assert run(data[:1], data[1:2], data[2:5], data[5:]) == [Text("✓ héllo")]
    assert run(data[:2], data[2:]) == [Text("✓ héllo")]
    assert run(data[:4], data[4:]) == [Text("✓ héllo")]


def test_whole_stream_events():
    assert run(STREAM) == [
        Text("héllo ✓ "),
        Cwd("mac", "/Users/leo/my src"),
        Text("\x1b[1;32m$\x1b[0m "),
        Hyperlink("https://cmux.dev/a", {"id": "42", "x": "y"}),
        Text("link"),
        Hyperlink("", {}),
        Prompt("D", 2),
        Clipboard("c", "copié".encode()),
        Text("\x1b"),
        Prompt("A"),
        Text("日本語 done\n"),
    ]


def test_every_single_cut_matches_whole():
    whole = run(STREAM)
    for i in range(1, len(STREAM)):
        assert run(STREAM[:i], STREAM[i:]) == whole, i


def test_byte_by_byte_matches_whole():
    whole = run(STREAM)
    assert run(*[STREAM[i:i + 1] for i in range(len(STREAM))]) == whole


def test_empty_chunks_change_nothing():
    whole = run(STREAM)
    mid = len(STREAM) // 2
    assert run(b"", STREAM[:mid], b"", STREAM[mid:], b"") == whole


def test_clipboard_query_and_bad_base64():
    assert run(b"\x1b]52;p;?\x07") == [Clipboard("p", None)]
    assert run(b"\x1b]52;c;@@@\x07x") == [Text("x")]


def test_other_escapes_pass_through_as_text():
    assert run(b"a\x1b[2Jb\x1bMc") == [Text("a\x1b[2Jb\x1bMc")]
    assert run(b"a\x1b", b"[2Jb") == [Text("a\x1b[2Jb")]
