import functools
import os
import random
import subprocess
import sys
import textwrap

import sortkeys
from sortkeys import natural_key, natural_sort

ASCII = "0123456789"


def model_runs(s):
    runs = []
    for ch in s:
        d = ch in ASCII
        if runs and runs[-1][0] == d:
            runs[-1][1] += ch
        else:
            runs.append([d, ch])
    return runs


def model_cmp(a, b):
    ra, rb = model_runs(a), model_runs(b)
    for (da, xa), (db, xb) in zip(ra, rb):
        if da != db:
            return -1 if da else 1
        if da:
            va, vb = xa.lstrip("0"), xb.lstrip("0")
            if len(va) != len(vb):
                return -1 if len(va) < len(vb) else 1
            if va != vb:
                return -1 if va < vb else 1
        else:
            fa, fb = xa.casefold(), xb.casefold()
            if fa != fb:
                return -1 if fa < fb else 1
    if len(ra) != len(rb):
        return -1 if len(ra) < len(rb) else 1
    la = [len(x) for d, x in ra if d]
    lb = [len(x) for d, x in rb if d]
    if la != lb:
        return -1 if la < lb else 1
    return (a > b) - (a < b)


def test_reported_orderings():
    names = ["img10.png", "IMG2.png", "img2.png", "img02.png", "img1.png", "img", "1img", "_img", "Img1.png"]
    assert natural_sort(names) == ["1img", "_img", "img", "Img1.png", "img1.png", "IMG2.png", "img2.png",
                                   "img02.png", "img10.png"]
    assert natural_sort(["v1.10", "v1.9", "v1.09", "v01.9", "V1.9"]) == ["V1.9", "v1.9", "v1.09", "v01.9", "v1.10"]
    assert natural_sort(["x", "1x", "x0", "x00", "x 1"]) == ["1x", "x", "x0", "x00", "x 1"]


def test_only_ascii_digits_are_numbers():
    assert natural_sort(["p٣", "p10", "p2"]) == ["p2", "p10", "p٣"]
    assert natural_sort(["s²", "s3", "s"]) == ["s", "s3", "s²"]
    assert natural_sort(["١٠", "٩", "5"]) == ["5", "١٠", "٩"]


def test_long_digit_runs():
    big = "run-" + "1" + "0" * 6000 + ".log"
    less = "run-" + "9" * 5999 + ".log"
    padded = "run-" + "0" * 3000 + "9" * 5999 + ".log"
    assert natural_sort([big, padded, less, "run-7.log"]) == ["run-7.log", less, padded, big]
    assert natural_key(less) < natural_key(padded) < natural_key(big)


def test_stable_with_key_and_reverse():
    items = [("b", 1), ("a10", 2), ("b", 3), ("A2", 4), ("b", 5)]
    assert natural_sort(items, key=lambda t: t[0]) == [("A2", 4), ("a10", 2), ("b", 1), ("b", 3), ("b", 5)]
    assert natural_sort(items, key=lambda t: t[0], reverse=True) == [("b", 1), ("b", 3), ("b", 5), ("a10", 2),
                                                                     ("A2", 4)]
    src = ["b2", "B2", "b02"]
    out = natural_sort(src)
    assert out == ["B2", "b2", "b02"] and src == ["b2", "B2", "b02"]


def test_random_names_match_model():
    rnd = random.Random(11)
    alphabet = ["a", "A", "b", "0", "1", "2", "9", "00", " ", ".", "٣", "ß", "SS"]
    for _ in range(300):
        names = ["".join(rnd.choice(alphabet) for _ in range(rnd.randint(0, 5))) for _ in range(12)]
        want = sorted(names, key=functools.cmp_to_key(model_cmp))
        assert natural_sort(names) == want, names
        assert natural_sort(names, reverse=True) == sorted(names, key=functools.cmp_to_key(model_cmp),
                                                           reverse=True)
        for a in names:
            for b in names:
                c = model_cmp(a, b)
                ka, kb = natural_key(a), natural_key(b)
                assert (ka < kb, ka == kb, ka > kb) == (c < 0, c == 0, c > 0), (a, b)


def test_big_listing_sorts_fast():
    code = textwrap.dedent("""
        import random, time
        from sortkeys import natural_sort
        rnd = random.Random(3)
        names = ["build-%d/part%03d_%s.tar.%d" % (rnd.randrange(500), rnd.randrange(1000),
                 rnd.choice(["A", "b", "c"]), rnd.randrange(9)) for _ in range(50000)]
        t = time.perf_counter()
        out = natural_sort(names)
        el = time.perf_counter() - t
        assert len(out) == 50000
        print(el)
    """)
    try:
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=8,
                             cwd=os.path.dirname(os.path.abspath(sortkeys.__file__)))
    except subprocess.TimeoutExpired:
        raise AssertionError("too slow")
    assert out.returncode == 0, out.stderr[-400:]
    assert float(out.stdout.split()[-1]) < 1.0, out.stdout
