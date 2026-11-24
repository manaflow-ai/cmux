import re

from pytest_shim import raises
from ansiwrap import display_width, fit, pad, status_line, strip_ansi, truncate, wrap

ESC_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
GREEN = "\x1b[32mmain\x1b[0m"


def escapes(s):
    return ESC_RE.findall(s)


def keeps_all(out, text):
    """Every escape sequence of `text` is in `out`, in order (extra ones, such as an added reset, are allowed)."""
    it = iter(escapes(out))
    return all(any(e == o for o in it) for e in escapes(text))


def test_pad_counts_cells_not_code_points():
    out = pad(GREEN, 20)
    assert display_width(out) == 20 and strip_ansi(out) == "main" + " " * 16
    assert pad("日本語", 8) == "日本語  "
    assert pad("日本語", 8, "right") == "  日本語"
    assert pad("日本", 7, "center") == " 日本  "


def test_pad_unchanged_regressions():
    assert pad("abc", 6) == "abc   "
    assert pad("abc", 6, "right") == "   abc"
    assert pad("abc", 6, "center") == " abc  "
    assert pad("abcdef", 3) == "abcdef"


def test_truncate_wide_characters():
    out = truncate("日本語テキスト", 7)
    assert strip_ansi(out) == "日本語…" and display_width(out) == 7
    out = truncate("日本語", 4)
    assert out == "日…"  # 日 + … is 3 cells; adding 本 would make 5
    assert truncate("日本語", 6) == "日本語"


def test_truncate_keeps_escape_sequences_whole():
    text = "\x1b[1;31mhello world\x1b[0m"
    out = truncate(text, 8)
    assert strip_ansi(out) == "hello w…"
    assert keeps_all(out, text)
    assert "\x1b" not in ESC_RE.sub("", out)
    assert truncate(text, 11) == text  # fits: 11 cells


def test_truncate_ascii_regressions():
    assert truncate("hello world", 8) == "hello w…"
    assert truncate("hello", 5) == "hello"
    assert truncate("hello", 8, ellipsis="...") == "hello"
    assert truncate("hello world", 8, ellipsis="...") == "hello..."


def test_fit_is_exactly_width_cells():
    for text in ("\x1b[33mwarn\x1b[0m", "日本語テキスト", "\x1b[7m日本語テキスト\x1b[0m", "plain text here"):
        for width in (5, 6, 9, 14):
            assert display_width(fit(text, width)) == width, (text, width)


def test_wrap_measures_cells():
    lines = wrap("日本語 テキスト です", 8)
    assert lines == ["日本語", "テキスト", "です"]
    colored = "\x1b[31mred\x1b[0m \x1b[32mgreen\x1b[0m \x1b[34mblue\x1b[0m"
    lines = wrap(colored, 9)
    assert [strip_ansi(l) for l in lines] == ["red green", "blue"]
    assert keeps_all("".join(lines), colored)


def test_wrap_breaks_long_wide_word_on_cell_boundaries():
    lines = wrap("日本語テキスト", 5)
    assert all(display_width(l) <= 5 for l in lines)
    assert "".join(lines) == "日本語テキスト"
    assert lines == ["日本", "語テ", "キス", "ト"]


def test_wrap_ascii_regressions():
    assert wrap("the quick brown fox", 10) == ["the quick", "brown fox"]
    assert wrap("abcdefghij xy", 4) == ["abcd", "efgh", "ij", "xy"]
    assert wrap("  a   b  ", 10) == ["a b"]
    raises(ValueError, wrap, "abc", 1)


def test_status_line_with_colour_and_wide_text():
    out = status_line("\x1b[32m~/src/日本語のプロジェクト\x1b[0m", "\x1b[2m12:04\x1b[0m", 20)
    assert display_width(out) == 20
    assert strip_ansi(out).endswith(" 12:04")
    assert strip_ansi(status_line("left", "right", 12)) == "left   right"
