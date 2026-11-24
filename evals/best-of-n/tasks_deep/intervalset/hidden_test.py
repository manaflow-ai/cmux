from intervalset import IntervalSet


def ivs(s):
    return list(s)


def test_back_to_back_does_not_overlap():
    busy = IntervalSet([(540, 600)])
    assert not busy.overlaps(600, 660)
    assert not busy.overlaps(480, 540)
    assert busy.overlaps(599, 660)
    assert busy.overlaps(500, 541)
    assert busy.overlaps(550, 560)
    assert not busy.overlaps(560, 560)


def test_contains_excludes_end():
    s = IntervalSet([(0, 10), (20, 30)])
    assert s.contains(0) and s.contains(9)
    assert not s.contains(10)
    assert not s.contains(19)
    assert s.contains(20) and s.contains(29)
    assert not s.contains(30)
    assert not s.contains(-1)


def test_remove_leaves_exact_remainder():
    s = IntervalSet([(0, 10)])
    s.remove(3, 5)
    assert ivs(s) == [(0, 3), (5, 10)]
    assert s.total() == 8
    assert s.contains(2) and not s.contains(3) and not s.contains(4) and s.contains(5)


def test_remove_at_edges():
    s = IntervalSet([(0, 10)])
    s.remove(0, 4)
    assert ivs(s) == [(4, 10)]
    s.remove(8, 100)
    assert ivs(s) == [(4, 8)]
    s.remove(4, 8)
    assert ivs(s) == []


def test_remove_then_add_back_is_identity():
    s = IntervalSet([(0, 10), (20, 25)])
    s.remove(5, 22)
    s.add(5, 22)
    assert ivs(s) == [(0, 25)]


def test_adjacent_adds_merge():
    s = IntervalSet()
    s.add(5, 9)
    s.add(0, 5)
    s.add(9, 12)
    s.add(14, 15)
    assert ivs(s) == [(0, 12), (14, 15)]
    s.add(3, 3)
    assert ivs(s) == [(0, 12), (14, 15)]


def test_complement_has_no_empty_gaps():
    s = IntervalSet([(0, 5), (8, 10)])
    assert ivs(s.complement(0, 10)) == [(5, 8)]
    assert ivs(s.complement(-3, 12)) == [(-3, 0), (5, 8), (10, 12)]
    assert ivs(s.complement(2, 9)) == [(5, 8)]
    assert ivs(s.complement(0, 5)) == []


def test_complement_partitions_range():
    s = IntervalSet([(3, 6), (10, 14), (15, 20)])
    lo, hi = 0, 18
    gaps = s.complement(lo, hi)
    for x in range(lo, hi):
        assert gaps.contains(x) != s.contains(x), x
    assert all(a < b for a, b in gaps)


def test_covers_and_union_unchanged():
    s = IntervalSet([(0, 10)])
    assert s.covers(2, 10)
    assert not s.covers(2, 11)
    assert s.covers(7, 7)
    u = s.union(IntervalSet([(10, 12), (20, 21)]))
    assert ivs(u) == [(0, 12), (20, 21)]
    assert ivs(s) == [(0, 10)]


def _model_ivs(cover):
    out = []
    for x in sorted(cover):
        if out and out[-1][1] == x:
            out[-1][1] = x + 1
        else:
            out.append([x, x + 1])
    return [tuple(p) for p in out]


def test_random_ops_match_a_plain_set():
    import random
    rng = random.Random(99)
    for trial in range(150):
        s = IntervalSet()
        cover = set()
        for step in range(25):
            a = rng.randint(0, 40)
            b = a + rng.randint(-2, 8)
            kind = rng.choice(("add", "add", "remove", "query"))
            if kind == "add":
                s.add(a, b)
                cover |= set(range(a, b))
            elif kind == "remove":
                s.remove(a, b)
                cover -= set(range(a, b))
            else:
                span = set(range(a, b))
                assert s.overlaps(a, b) == bool(span & cover), (trial, step, a, b)
                assert s.covers(a, b) == span.issubset(cover), (trial, step, a, b)
                lo, hi = sorted((a, b))
                assert list(s.complement(lo, hi)) == _model_ivs(set(range(lo, hi)) - cover)
            assert list(s) == _model_ivs(cover), (trial, step, kind, a, b)
            assert s.total() == len(cover)
            x = rng.randint(-1, 50)
            assert s.contains(x) == (x in cover)


def test_large_set_is_fast():
    import random
    import time as _t
    rng = random.Random(5)
    starts = list(range(0, 50000 * 10, 10))
    rng.shuffle(starts)
    t0 = _t.perf_counter()

    def check_budget():
        assert _t.perf_counter() - t0 < 1.5, "too slow"

    s = IntervalSet()
    for n, a in enumerate(starts):
        s.add(a, a + 4)
        if n % 1000 == 0:
            check_budget()
    for i in range(12500):
        x = rng.randrange(0, 500000)
        s.contains(x)
        s.overlaps(x, x + 3)
        s.covers(x, x + 2)
        s.remove(x, x + 1)
        if i % 500 == 0:
            check_budget()
    check_budget()
    assert len(s) >= 50000


def test_intersection_drops_touching_pairs():
    a = IntervalSet([(0, 5), (10, 15)])
    b = IntervalSet([(5, 10), (14, 20)])
    assert list(a.intersection(b)) == [(14, 15)]
    assert list(a.intersection(IntervalSet())) == []
    assert list(a.intersection(a)) == [(0, 5), (10, 15)]


def test_first_fit_takes_an_exact_gap():
    busy = IntervalSet([(540, 600), (630, 700)])
    assert busy.first_fit(30, 540, 720) == 600
    assert busy.first_fit(31, 540, 720) is None
    assert busy.first_fit(20, 540, 720) == 600
    assert busy.first_fit(20, 690, 720) == 700
    assert busy.first_fit(60, 480, 720) == 480
    assert busy.first_fit(10, 595, 605) is None


def test_random_intersection_and_first_fit_match_sets():
    import random
    rng = random.Random(3)
    for trial in range(200):
        a, b = IntervalSet(), IntervalSet()
        ca, cb = set(), set()
        for _ in range(rng.randint(0, 6)):
            x = rng.randint(0, 30)
            y = x + rng.randint(1, 6)
            a.add(x, y); ca |= set(range(x, y))
            x = rng.randint(0, 30)
            y = x + rng.randint(1, 6)
            b.add(x, y); cb |= set(range(x, y))
        assert list(a.intersection(b)) == _model_ivs(ca & cb), trial
        length = rng.randint(1, 6)
        lo = rng.randint(0, 20)
        hi = lo + rng.randint(0, 20)
        want = next((x for x in range(lo, hi - length + 1)
                     if not (set(range(x, x + length)) & ca)), None)
        assert a.first_fit(length, lo, hi) == want, (trial, length, lo, hi)


def test_large_intersection_is_fast():
    import time as _t
    n = 3000
    a = IntervalSet()
    b = IntervalSet()
    for i in range(n):
        a.add(i * 10, i * 10 + 6)
        b.add(i * 10 + 3, i * 10 + 9)
    small = a.intersection(IntervalSet([(0, 50)]))
    assert list(small) == [(0, 6), (10, 16), (20, 26), (30, 36), (40, 46)]
    t0 = _t.perf_counter()
    big = a.intersection(b)
    assert _t.perf_counter() - t0 < 1.0
    assert len(big) == n
    assert list(big)[:2] == [(3, 6), (13, 16)]
