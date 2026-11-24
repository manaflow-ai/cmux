import unicodedata

from tablefmt import clip, column_widths, pad, render, render_records, text_width


def cells(s):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def last_col_offset(line):
    """Cell offset where the line's last space-free field starts."""
    return cells(line[:line.rindex(" ") + 1])


def test_reported_wide_row_lines_up():
    out = render(["NAME", "STATUS", "AGE"], [["build-mac", "running", "3m"], ["日本語の作業", "idle", "12h"]])
    lines = out.split("\n")
    assert lines[0] == "NAME          STATUS   AGE"
    assert lines[1] == "------------  -------  ---"
    assert lines[2] == "build-mac     running  3m"
    assert lines[3] == "日本語の作業  idle     12h"


def test_widths_are_cells():
    assert column_widths(["A"], [["日本"], ["abc"]]) == [4]
    assert column_widths(["A"], [["été"]]) == [3]
    assert column_widths(["NAME"], [["日本語の作業"]], max_width=8) == [8]
    assert pad("日本", 6) == "日本  "
    assert pad("日本", 6, "r") == "  日本"
    assert pad("日本", 7, "c") == " 日本  "


def test_clip_wide_text():
    assert clip("日本語の作業", 8) == "日本語…"
    assert clip("日本語の作業", 7) == "日本語…"
    assert clip("日本語の作業", 12) == "日本語の作業"
    assert cells(clip("日本語の作業", 6)) <= 6 and clip("日本語の作業", 6) == "日本…"


def test_clip_combining_marks_fit():
    assert clip("café", 4) == "café"
    assert clip("cafés", 4) == "caf…"


def test_capped_wide_column_keeps_offsets():
    out = render(["NAME", "ST"], [["日本語の作業です", "ok"], ["abc", "no"], ["日本語x", "ok"]], max_width=7)
    lines = out.split("\n")
    offs = {last_col_offset(l) for l in lines if l != "-------  --"}
    assert offs == {9}, lines
    assert lines[2].startswith("日本語…") and lines[2].endswith("ok")
    assert lines[4].startswith("日本語x")


def test_right_aligned_clipped_wide_cell():
    out = render(["N", "NAME"], [[1, "日本語の作業"], [22, "ab"]], align="rr", max_width=5)
    lines = out.split("\n")
    assert lines[0] == " N   NAME"
    assert lines[2] == " 1  日本…"
    assert lines[3] == "22     ab"


def test_ascii_regressions():
    out = render(["ID", "NAME", "NOTE"], [[7, "alpha", None], [12, "beta-long-name", "x\ny"]], align="rlc",
                 max_width=8)
    assert out.split("\n") == [
        "ID  NAME      NOTE",
        "--  --------  ----",
        " 7  alpha",
        "12  beta-lo…  x y",
    ]
    assert clip("abcdef", 4) == "abc…"
    assert render(["A", "B"], [["x"]], rule="") == "A  B\nx"


def test_render_records_wide():
    out = render_records([{"name": "日本", "state": "idle"}, {"name": "ab"}], [("NAME", "name"), ("STATE", "state")])
    assert out.split("\n") == ["NAME  STATE", "----  -----", "日本  idle", "ab"]
