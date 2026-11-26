import os
import random
import subprocess
import sys
import textwrap

import rangemerge
from rangemerge import SpanMap

N = 24


def runs_of(cells):
    out = []
    for i, v in enumerate(cells):
        if v is None:
            continue
        if out and out[-1][1] == i and out[-1][2] == v:
            out[-1] = (out[-1][0], i + 1, v)
        else:
            out.append((i, i + 1, v))
    return out


def test_reported_get_and_set_fast():
    code = textwrap.dedent("""
        import time
        from rangemerge import SpanMap
        m = SpanMap()
        t = time.perf_counter()
        for i in range(100000):
            m.set(3 * i, 3 * i + 2, i % 7)
        acc = 0
        for i in range(100000):
            acc += m.get(3 * i + 1) == i % 7
        el = time.perf_counter() - t
        assert acc == 100000 and m.get(2) is None and len(m.spans()) == 100000
        print(el)
    """)
    try:
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=8,
                             cwd=os.path.dirname(os.path.abspath(rangemerge.__file__)))
    except subprocess.TimeoutExpired:
        raise AssertionError("too slow")
    assert out.returncode == 0, out.stderr[-400:]
    assert float(out.stdout.split()[-1]) < 1.0, out.stdout


def test_touching_runs_with_equal_values_merge():
    m = SpanMap()
    m.set(0, 3, "b")
    m.set(3, 5, "b")
    assert m.spans() == [(0, 5, "b")]
    m.set(7, 9, "b")
    m.set(5, 7, "b")
    assert m.spans() == [(0, 9, "b")]
    m.set(2, 4, "i")
    m.set(2, 4, "b")
    assert m.spans() == [(0, 9, "b")]
    assert SpanMap([(0, 2, 1), (2, 4, 1), (4, 6, 2)]).spans() == [(0, 4, 1), (4, 6, 2)]


def test_delete_joins_equal_neighbours():
    m = SpanMap([(0, 3, "x"), (3, 5, "y"), (5, 8, "x")])
    m.delete(3, 2)
    assert m.spans() == [(0, 6, "x")]
    m = SpanMap([(0, 2, "x"), (4, 6, "x")])
    m.delete(2, 2)
    assert m.spans() == [(0, 4, "x")]


def test_documented_regressions():
    m = SpanMap([(2, 5, "a")])
    assert [m.get(i) for i in (1, 2, 4, 5)] == [None, "a", "a", None]
    m.insert(5, 2)  # typing at the end of the run grows it
    assert m.spans() == [(2, 7, "a")]
    m.insert(2, 1)  # at its start: the cell before is unset
    assert m.spans() == [(3, 8, "a")]
    m.set(5, 5, "z")
    m.set(6, 4, "z")
    m.set(4, 6, None)
    assert m.spans() == [(3, 4, "a"), (6, 8, "a")]
    assert m.values_in(0, 10) == ["a"]
    m.set(0, 1, [1])
    assert m.get(0) == [1] and m.values_in(0, 4) == [[1], "a"]


def test_long_random_sequences_match_cell_model():
    rnd = random.Random(99)
    for _ in range(300):
        m = SpanMap()
        cells = [None] * N
        for _ in range(30):
            roll = rnd.random()
            a, b = sorted(rnd.randrange(N + 1) for _ in range(2))
            if roll < 0.6:
                v = rnd.choice(["r", "g", None])
                m.set(a, b, v)
                for i in range(a, b):
                    cells[i] = v
            elif roll < 0.8:
                k = rnd.randint(0, 3)
                m.insert(a, k)
                fill = cells[a - 1] if a > 0 else None
                cells[a:a] = [fill] * k
                del cells[N:]
                m.delete(N, 10)
            else:
                m.delete(a, b - a)
                del cells[a:b]
                cells += [None] * (N - len(cells))
            assert m.spans() == runs_of(cells), (m.spans(), cells)
            assert [m.get(i) for i in range(-1, N + 1)] == [None] + cells + [None]
