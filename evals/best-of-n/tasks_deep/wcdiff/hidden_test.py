import os
import random
import subprocess
import sys
import textwrap

import wcdiff
from wcdiff import diff_lines, diff_text, hunks, stats


def bounded(code, limit):
    """Run `code` in a fresh python beside the module; it prints its own elapsed seconds, which must be < limit."""
    pre = "import resource, time\nresource.setrlimit(resource.RLIMIT_AS, (3 << 30, 3 << 30))\n"
    try:
        out = subprocess.run([sys.executable, "-c", pre + textwrap.dedent(code)], capture_output=True, text=True,
                             cwd=os.path.dirname(os.path.abspath(wcdiff.__file__)), timeout=limit * 4 + 2)
    except subprocess.TimeoutExpired:
        raise AssertionError(f"did not finish in {limit * 4 + 2} s")
    assert out.returncode == 0, out.stderr[-400:]
    elapsed = float(out.stdout.split()[-1])
    assert elapsed < limit, f"{elapsed:.2f} s"


def lcs_len(a, b):
    a = [x.rstrip("\r") if x.endswith("\r") else x for x in a]
    b = [x[:-1] if x.endswith("\r") else x for x in b]
    prev = [0] * (len(b) + 1)
    for x in a:
        cur = [0]
        for j, y in enumerate(b):
            cur.append(prev[j] + 1 if x == y else max(prev[j + 1], cur[j]))
        prev = cur
    return prev[-1]


def norm(x):
    return x[:-1] if x.endswith("\r") else x


def check_script(a, b, script):
    assert [norm(l) for o, l in script if o != "+"] == [norm(x) for x in a]
    assert [l for o, l in script if o != "-"] == b  # "=" lines come from b, exactly
    keep = sum(o == "=" for o, _ in script)
    assert keep == lcs_len(a, b), (a, b, script)
    run = []
    for o, _ in script + [("=", None)]:
        if o == "=":
            assert run == sorted(run, key=lambda c: c != "-"), script
            run = []
        else:
            run.append(o)


def test_small_scripts_are_minimal_and_grouped():
    rnd = random.Random(7)
    for _ in range(400):
        a = [rnd.choice("abcde") for _ in range(rnd.randint(0, 10))]
        b = [rnd.choice("abcde") for _ in range(rnd.randint(0, 10))]
        check_script(a, b, diff_lines(a, b))


def test_crlf_lines_equal_and_taken_from_b():
    a = ["one\r", "two\r", "three\r"]
    b = ["one", "TWO", "three"]
    s = diff_lines(a, b)
    check_script(a, b, s)
    assert s == [("=", "one"), ("-", "two\r"), ("+", "TWO"), ("=", "three")]
    assert diff_lines(["x"], ["x\r"]) == [("=", "x\r")]


def test_replaced_block_reads_old_then_new():
    s = diff_lines(["k", "a1", "a2", "k2"], ["k", "b1", "b2", "b3", "k2"])
    assert s == [("=", "k"), ("-", "a1"), ("-", "a2"), ("+", "b1"), ("+", "b2"), ("+", "b3"), ("=", "k2")]
    s = diff_lines(["x", "y"], ["p", "x", "q"])
    check_script(["x", "y"], ["p", "x", "q"], s)


def test_big_file_changed_near_both_ends_is_fast():
    bounded("""
        import wcdiff
        a = ["line %d" % i for i in range(4000)]
        b = list(a)
        for i in (3, 5, 3990, 3996):
            b[i] = "changed %d" % i
        b.insert(2000, "inserted")
        del b[10]
        t = time.perf_counter()
        s = wcdiff.diff_lines(a, b)
        el = time.perf_counter() - t
        assert sum(o == "=" for o, _ in s) == 3995, sum(o == "=" for o, _ in s)
        print(el)
    """, 0.5)


def test_big_file_scattered_changes_is_fast():
    bounded("""
        import random, wcdiff
        rnd = random.Random(3)
        a = ["row %d" % rnd.randrange(50) for i in range(4000)]
        b = list(a)
        for i in sorted(rnd.sample(range(4000), 8)):
            b[i] = "new %d" % i
        t = time.perf_counter()
        s = wcdiff.diff_lines(a, b)
        el = time.perf_counter() - t
        assert [l for o, l in s if o != "-"] == b and [l for o, l in s if o != "+"] == a
        assert sum(o != "=" for o, _ in s) <= 16
        print(el)
    """, 0.5)


def test_diff_text_stats_hunks_regressions():
    old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"
    new = "a\nB\nc\nd\ne\nf\ng\nh\ni\nJ\nk\n"
    s = diff_text(old, new)
    assert stats(s) == (3, 2)
    assert hunks(s, context=1) == [(0, 3, 0, 3), (8, 2, 8, 3)]
    assert hunks(s, context=3) == [(0, 5, 0, 5), (6, 4, 6, 5)]
    assert hunks(s, context=4) == [(0, 10, 0, 11)]
    assert diff_text("", "") == [] and diff_lines([], ["x"]) == [("+", "x")]
    assert diff_text("x", "x\n") == [("=", "x")]
