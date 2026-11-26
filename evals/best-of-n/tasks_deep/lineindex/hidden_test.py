import os
import random
import subprocess
import sys
import textwrap

import lineindex
from pytest_shim import raises
from lineindex import LineIndex


def bounded(code, limit):
    pre = "import time\n"
    try:
        out = subprocess.run([sys.executable, "-c", pre + textwrap.dedent(code)], capture_output=True, text=True,
                             cwd=os.path.dirname(os.path.abspath(lineindex.__file__)), timeout=limit * 4 + 3)
    except subprocess.TimeoutExpired:
        raise AssertionError("too slow")
    assert out.returncode == 0, out.stderr[-400:]
    elapsed = float(out.stdout.split()[-1])
    assert elapsed < limit, f"{elapsed:.2f} s"


class Model:
    """The contract, written plainly."""

    def __init__(self, data):
        self.data = bytes(data)
        text = self.data
        self.lines = []  # (start, content_end)
        start = i = 0
        while i < len(text):
            if text[i:i + 2] == b"\r\n":
                self.lines.append((start, i)); i += 2; start = i
            elif text[i] in (10, 13):
                self.lines.append((start, i)); i += 1; start = i
            else:
                i += 1
        self.lines.append((start, len(text)))

    def line_col(self, off):
        off = max(0, min(off, len(self.data)))
        while 0 < off < len(self.data) and self.data[off] & 0xC0 == 0x80:
            off -= 1
        line = max(k for k, (s, _) in enumerate(self.lines) if s <= off)
        s, e = self.lines[line]
        off = min(off, e)
        return line, sum(2 if ord(c) > 0xFFFF else 1 for c in self.data[s:off].decode())

    def text(self, line):
        s, e = self.lines[line]
        return self.data[s:e]


ALPHA = [b"a", b"b", b"\r", b"\n", b"\r\n", "é".encode(), "😀".encode(), "語".encode()]


def rand_bytes(rnd, n):
    return b"".join(rnd.choice(ALPHA) for _ in range(n))


def agree(idx, model):
    assert idx.line_count() == len(model.lines)
    for off in range(len(model.data) + 2):
        assert idx.line_col(off) == model.line_col(off), (model.data, off)
    for line in range(len(model.lines)):
        assert idx.line_text(line) == model.text(line)
        for col in range(6):
            off = idx.offset(line, col)
            assert model.line_col(off)[0] == line and model.line_col(off)[1] <= col


def test_conventions_regressions():
    idx = LineIndex("a\r\nbé\rc😀d\n".encode())
    assert idx.line_count() == 4
    assert idx.line_col(1) == (0, 1) and idx.line_col(2) == (0, 1)  # inside the CRLF: end of line 0
    assert idx.line_col(3) == (1, 0)
    assert idx.line_col(5) == (1, 1)  # inside é: its start
    assert idx.line_col(6) == (1, 2)  # the lone \r ends line 1
    assert idx.line_col(7) == (2, 0)
    assert idx.line_col(10) == (2, 1)  # inside the emoji: its start
    assert idx.line_col(12) == (2, 3)  # after the emoji: 2 UTF-16 units
    assert idx.offset(2, 2) == 8 and idx.offset(2, 3) == 12 and idx.offset(2, 99) == 13
    assert idx.offset(9, 0) == 14 and idx.line_col(99) == (3, 0) and idx.line_col(-5) == (0, 0)
    raises(ValueError, idx.apply_edit, 3, 2, b"")


def test_fresh_index_matches_model():
    rnd = random.Random(11)
    for _ in range(150):
        data = rand_bytes(rnd, rnd.randint(0, 14))
        agree(LineIndex(data), Model(data))


def test_reported_crlf_join_and_split_by_edits():
    idx = LineIndex(b"ab\rcd")
    idx.apply_edit(3, 3, b"\n")  # "\r" + "\n" now one CRLF
    agree(idx, Model(b"ab\r\ncd"))
    idx = LineIndex(b"ab\r\ncd")
    idx.apply_edit(3, 3, b"X")  # splits the CRLF into two breaks
    agree(idx, Model(b"ab\rX\ncd"))
    idx = LineIndex(b"ab\rX\ncd")
    idx.apply_edit(3, 4, b"")  # removing X joins them again
    agree(idx, Model(b"ab\r\ncd"))
    idx = LineIndex(b"x\r\n")
    idx.apply_edit(2, 3, b"")
    agree(idx, Model(b"x\r"))


def test_long_random_edit_sequences():
    rnd = random.Random(2024)
    for _ in range(60):
        toks = [rnd.choice(ALPHA) for _ in range(rnd.randint(0, 12))]
        idx = LineIndex(b"".join(toks))
        for _ in range(25):
            i = rnd.randint(0, len(toks))
            j = rnd.randint(i, min(len(toks), i + 3))
            new = [rnd.choice(ALPHA) for _ in range(rnd.randint(0, 3))]
            s, e = len(b"".join(toks[:i])), len(b"".join(toks[:j]))
            idx.apply_edit(s, e, b"".join(new))
            toks[i:j] = new
        agree(idx, Model(b"".join(toks)))


def test_line_col_is_fast_on_big_buffer():
    bounded("""
        import random
        from lineindex import LineIndex
        rnd = random.Random(1)
        parts = []
        for i in range(40000):
            parts.append(("x" * rnd.randint(10, 80) + "é").encode() + rnd.choice([b"\\n", b"\\r\\n", b"\\r"]))
        data = b"".join(parts)
        idx = LineIndex(data)
        offs = [rnd.randrange(len(data)) for _ in range(50000)]
        t = time.perf_counter()
        res = [idx.line_col(o) for o in offs]
        el = time.perf_counter() - t
        assert res[0][0] < 40000
        print(el)
    """, 1.0)


def test_offset_is_fast_on_big_buffer():
    bounded("""
        import random
        from lineindex import LineIndex
        rnd = random.Random(2)
        data = b"".join(("y" * rnd.randint(10, 80)).encode() + b"\\n" for i in range(40000))
        idx = LineIndex(data)
        qs = [(rnd.randrange(40000), rnd.randrange(90)) for _ in range(50000)]
        t = time.perf_counter()
        res = [idx.offset(l, c) for l, c in qs]
        el = time.perf_counter() - t
        print(el)
    """, 1.0)
