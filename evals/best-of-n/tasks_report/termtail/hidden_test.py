# Ported from cmux-tui-core terminal_tail_tests.rs (cmux 8c14cae03c5, CMUX-283), plus spec cases.
from termtail import TailLine, clean_line, MAX_LINE_BYTES, MAX_TAIL_CHARS, MAX_TAIL_BYTES


def test_the_tail_is_the_last_non_empty_line_without_escapes():
    line = TailLine()
    assert line.feed(b"\x1b[1;32m   Compiling\x1b[0m cmux v0.1.0\r\n\r\n   \r\n")
    assert line.tail == "Compiling cmux v0.1.0"
    line.feed(b"\x1b[2K\x1b]0;title\x07\n\t \n")
    assert line.tail == "Compiling cmux v0.1.0"


def test_osc_titles_links_and_control_bytes_never_reach_the_tail():
    line = TailLine()
    line.feed(b"\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\ done\x07\x08\n")
    assert line.tail == "link done"
    line.feed(b"ready\x1bP$qm\x1b\\\n\x1b_Gf=100;AAAA\x1b\\\n")
    assert line.tail == "ready"
    line.feed(b"a\tb    c\n")
    assert line.tail == "a b c"


def test_a_progress_bar_shows_its_newest_frame():
    line = TailLine()
    line.feed(b"[==>   ] 10%\r[====> ] 50%\r[======] 100%")
    assert line.tail == "[====> ] 50%"
    line.feed(b"\n")
    assert line.tail == "[======] 100%"


def test_a_line_split_across_chunks_and_escapes_is_one_line():
    line = TailLine()
    assert not line.feed(b"Deployed web@a1b2\x1b[")
    assert not line.feed(b"1mc3\x1b[0")
    assert line.feed(b"m to staging\n")
    assert line.tail == "Deployed web@a1b2c3 to staging"


def test_a_newline_inside_an_osc_string_ends_no_line():
    line = TailLine()
    line.feed(b"build ok\n\x1b]0;one\ntwo\x07\n")
    assert line.tail == "build ok"
    line.feed(b"done\n\x1b]633;E;echo a\r")
    line.feed(b"b\x1b\\\n")
    assert line.tail == "done"
    line.feed(b"\x1bPq#0;2;0;0;0\n#1~~\r\n-\x1b\\\n")
    assert line.tail == "done"


def test_a_long_escape_never_takes_the_text_after_it():
    line = TailLine()
    data = b"ok \x1b]8;;https://example.com/" + b"u" * (MAX_LINE_BYTES * 2) + b"\x1b\\link\x1b]8;;\x1b\\\n"
    line.feed(data)
    assert line.tail == "ok link"
    assert len(line.pending) == 0


def test_take_change_reports_each_new_tail_once():
    line = TailLine()
    line.feed(b"one\n")
    assert line.take_change() == "one"
    assert line.take_change() is None
    assert not line.feed(b"one\n")
    assert line.take_change() is None
    line.feed(b"two\nthree\n")
    assert line.take_change() == "three"


def test_a_long_line_is_bounded():
    line = TailLine()
    long = b"x" * (MAX_LINE_BYTES * 8)
    line.feed(long)
    line.feed(long)
    assert len(line.pending) <= MAX_LINE_BYTES
    line.feed(b"\n")
    assert len(line.tail) == MAX_TAIL_CHARS
    assert len(clean_line("é" * (MAX_TAIL_CHARS * 2))) == MAX_TAIL_CHARS
    emoji = clean_line("🚀" * MAX_TAIL_CHARS)
    assert MAX_TAIL_BYTES - 4 < len(emoji.encode()) <= MAX_TAIL_BYTES



def test_invalid_utf8_and_controls():
    line = TailLine()
    line.feed(b"caf\xc3\xa9 \xff ok\x7f\x01\n")
    assert line.tail == "café � ok"
    assert clean_line("  a \t\t b  ") == "a b"
