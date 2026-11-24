from scrollback import Scrollback

LOG = "compiling cmux-tui crate."  # 25 characters


def test_reported_line_count_counts_logical_lines():
    sb = Scrollback(10, 100)
    for line in ("hello", LOG, "done"):
        sb.append(line)
    assert sb.lines() == ["hello", LOG, "done"]
    assert sb.line_count() == 3
    assert sb.row_count() == 5


def test_rows_wrap_at_width():
    sb = Scrollback(10, 100)
    sb.append(LOG)
    assert sb.rows() == ["compiling ", "cmux-tui c", "rate."]
    assert sb.row_count() == 3


def test_empty_lines_take_a_row():
    sb = Scrollback(4, 100)
    sb.write("a\n\nbbbbbb\n\n")
    assert sb.lines() == ["a", "", "bbbbbb", ""]
    assert sb.line_count() == 4
    assert sb.rows() == ["a", "", "bbbb", "bb", ""]
    sb.resize(3)
    assert sb.lines() == ["a", "", "bbbbbb", ""]
    assert sb.row_count() == 5


def test_eviction_is_by_whole_logical_lines():
    sb = Scrollback(5, 3)
    for line in ("one", "a" * 12, "two", "three"):
        sb.append(line)
    assert sb.lines() == ["a" * 12, "two", "three"]
    assert sb.line_count() == 3
    sb.append("x" * 11)
    assert sb.lines() == ["two", "three", "x" * 11]
    assert sb.rows() == ["two", "three", "xxxxx", "xxxxx", "x"]


def test_capacity_one_keeps_long_line_whole():
    sb = Scrollback(2, 1)
    sb.append("abc")
    sb.append("abcdefg")
    assert sb.lines() == ["abcdefg"]
    assert sb.row_count() == 4


def test_search_across_soft_wraps():
    sb = Scrollback(10, 100)
    sb.append("hello")
    sb.append(LOG)
    assert sb.search("cmux") == [(1, 10)]
    assert sb.search("g c") == [(1, 8)]
    assert sb.search("tui crate") == [(1, 15)]
    assert sb.search("o") == [(0, 4), (1, 1)]
    assert sb.search("zzz") == [] and sb.search("") == []


def test_search_overlapping_and_after_eviction():
    sb = Scrollback(3, 2)
    sb.append("aaaa")
    sb.append("xx")
    sb.append("baaab")
    assert sb.search("aa") == [(1, 1), (1, 2)]
    assert sb.search("x") == [(0, 0), (0, 1)]


def test_search_and_lines_survive_resize():
    sb = Scrollback(10, 100)
    sb.write("hello\n" + LOG + "\ndone\n")
    before = sb.lines()
    sb.resize(4)
    assert sb.lines() == before
    assert sb.search("cmux-tui") == [(1, 10)]
    assert sb.row_count() == 2 + 7 + 1
    sb.resize(80)
    assert sb.rows() == before


def test_write_splits_lines():
    sb = Scrollback(80, 10)
    sb.write("a\nb\n")
    sb.write("c")
    assert sb.lines() == ["a", "b", "c"]
    try:
        sb.append("x\ny")
    except ValueError:
        pass
    else:
        raise AssertionError("append takes one line")


def test_long_session_stays_fast():
    import time
    start = time.perf_counter()
    sb = Scrollback(40, 3000)
    for i in range(60000):
        sb.append(("line %d " % i) * (i % 13))
        assert sb.line_count() == min(i + 1, 3000)
        if i % 1000 == 0:
            assert time.perf_counter() - start < 1.0, f"too slow at line {i}"
    assert sb.lines()[0] == ("line %d " % 57000) * (57000 % 13)
    assert time.perf_counter() - start < 1.0
