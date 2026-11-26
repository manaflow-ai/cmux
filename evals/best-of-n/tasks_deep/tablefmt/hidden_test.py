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


CW = {"a": 1, "b": 1, " ": 1, "-": 1, "漢": 2, "Ａ": 2, "́": 0, "…": 1, "h": 1, "=": 1, "|": 1, **{d: 1 for d in "0123456789"}}


def m_width(s):
    return sum(CW[c] for c in s)


def m_cell(v):
    return "" if v is None else str(v).replace("\r\n", " ").replace("\n", " ")


def m_clip(s, w):
    if m_width(s) <= w:
        return s
    if w <= 0:
        return ""
    out, used = "", 0
    for c in s:
        if used + CW[c] > w - 1:
            break
        out, used = out + c, used + CW[c]
    return out + "…"


def m_pad(s, w, a):
    gap = max(0, w - m_width(s))
    if a == "r":
        return " " * gap + s
    if a == "c":
        return " " * (gap // 2) + s + " " * (gap - gap // 2)
    return s + " " * gap


def m_render(headers, rows, aligns, max_width, sep, rule):
    n = len(headers)
    rows = [list(r)[:n] + [None] * (n - len(r)) for r in rows]
    aligns = (list(aligns) if aligns else []) + ["l"] * n
    widths = [max(m_width(m_cell(r[i])) for r in [headers] + rows) for i in range(n)]
    if max_width is not None:
        widths = [min(w, max_width) for w in widths]
    lines = [sep.join(m_pad(m_clip(m_cell(v), w), w, a) for v, w, a in zip(r, widths, aligns)).rstrip()
             for r in [headers] + rows]
    if rule:
        lines.insert(1, sep.join(rule * w for w in widths).rstrip())
    return "\n".join(lines)


def test_random_tables_match_model():
    import random
    rnd = random.Random(4)
    alphabet = ["a", "b", " ", "漢", "Ａ", "́", "-"]

    def value():
        roll = rnd.random()
        if roll < 0.1:
            return None
        if roll < 0.2:
            return rnd.randint(-50, 5000)
        s = "".join(rnd.choice(alphabet) for _ in range(rnd.randint(0, 8)))
        if rnd.random() < 0.1:
            s += rnd.choice(["\n", "\r\n"]) + "a"
        return s

    for _ in range(1500):
        n = rnd.randint(1, 4)
        headers = [value() or "h" for _ in range(n)]
        rows = [[value() for _ in range(rnd.randint(0, n + 1))] for _ in range(rnd.randint(0, 5))]
        aligns = "".join(rnd.choice("lrc") for _ in range(rnd.randint(0, n))) or None
        max_width = rnd.choice([None, None, 1, 2, 3, 5])
        sep = rnd.choice(["  ", " | ", ""])
        rule = rnd.choice(["-", "", "="])
        got = render(headers, rows, align=aligns, max_width=max_width, sep=sep, rule=rule)
        assert got == m_render(headers, rows, aligns, max_width, sep, rule), (headers, rows, aligns, max_width)


def test_big_listing_renders_fast():
    import os
    import subprocess
    import sys
    import textwrap
    import tablefmt
    code = textwrap.dedent("""
        import time
        from tablefmt import render
        rows = [["agent-%d" % i, "\\u65e5\\u672c\\u8a9e" * (i % 5), "running" if i % 3 else None, i * 7]
                for i in range(30000)]
        rows.append(["x" * 200000, "y", "z", 0])
        t = time.perf_counter()
        out = render(["NAME", "WORKSPACE", "STATUS", "AGE"], rows, align="lllr", max_width=24)
        el = time.perf_counter() - t
        assert out.count("\\n") == 30002
        print(el)
    """)
    try:
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=8,
                             cwd=os.path.dirname(os.path.abspath(tablefmt.__file__)))
    except subprocess.TimeoutExpired:
        raise AssertionError("too slow")
    assert out.returncode == 0, out.stderr[-400:]
    assert float(out.stdout.split()[-1]) < 2.5, out.stdout
