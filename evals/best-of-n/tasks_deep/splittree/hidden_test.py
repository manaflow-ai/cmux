from splittree import SplitTree


def approx(a, b):
    return abs(a - b) < 1e-9


def same(snap, want):
    """Compare snapshots with ratios approximately equal."""
    if isinstance(want, str):
        return snap == want
    if not isinstance(snap, tuple) or snap[0] != want[0] or len(snap[1]) != len(want[1]):
        return False
    return all(approx(r, wr) and same(c, wc) for (r, c), (wr, wc) in zip(snap[1], want[1]))


def three_in_a_row():
    t = SplitTree("a")
    t.split("a", "h", "b")
    t.split("b", "h", "c")
    return t


def test_reported_resize_after_two_splits_in_a_row():
    t = three_in_a_row()
    assert same(t.snapshot(), ("h", [(0.5, "a"), (0.25, "b"), (0.25, "c")]))
    t.resize("c", 0.5)
    assert same(t.snapshot(), ("h", [(1 / 3, "a"), (1 / 6, "b"), (0.5, "c")]))
    rects = t.layout(600, 40)
    assert rects["c"] == (300, 0, 300, 40)


def test_split_in_the_other_orientation_nests():
    t = SplitTree("a")
    t.split("a", "h", "b")
    t.split("a", "v", "c")
    assert same(t.snapshot(), ("h", [(0.5, ("v", [(0.5, "a"), (0.5, "c")])), (0.5, "b")]))
    assert t.focus == "c"
    assert t.leaves() == ["a", "c", "b"]


def test_close_gives_share_to_the_next_sibling():
    t = three_in_a_row()
    t.close("b")
    assert same(t.snapshot(), ("h", [(0.5, "a"), (0.5, "c")]))
    t2 = SplitTree("a")
    t2.split("a", "h", "b")
    t2.split("b", "h", "c")
    t2.resize("b", 0.5)  # a 1/3, b 1/2, c 1/6
    t2.close("a")
    assert same(t2.snapshot(), ("h", [(5 / 6, "b"), (1 / 6, "c")]))
    t2.split("b", "h", "d")  # b 5/12, d 5/12, c 1/6
    t2.close("c")            # last child: the one before it inherits
    assert same(t2.snapshot(), ("h", [(5 / 12, "b"), (7 / 12, "d")]))


def test_layout_tiles_after_close():
    t = three_in_a_row()
    t.split("a", "h", "d")  # a, d, b, c
    t.close("d")
    rects = t.layout(120, 30)
    assert rects["a"][2] == 30 and rects["b"][2] == 60 and rects["c"][2] == 30
    assert sum(r[2] for r in rects.values()) == 120


def test_close_collapses_into_same_orientation_grandparent():
    t = SplitTree("a")
    t.split("a", "h", "b")      # h[a, b]
    t.split("b", "v", "c")      # h[a, v[b, c]]
    t.split("c", "h", "d")      # h[a, v[b, h[c, d]]]
    t.close("b")                # v left with one child h[c, d], which joins the outer h
    assert same(t.snapshot(), ("h", [(0.5, "a"), (0.25, "c"), (0.25, "d")]))
    rects = t.layout(100, 10)
    assert rects["c"] == (50, 0, 25, 10) and rects["d"] == (75, 0, 25, 10)


def test_close_down_to_one_pane_and_root_collapse():
    t = SplitTree("a")
    t.split("a", "v", "b")
    t.close("a")
    assert t.snapshot() == "b" and t.focus == "b"
    try:
        t.close("b")
    except ValueError:
        pass
    else:
        raise AssertionError("closing the last pane must be refused")


def test_focus_moves_only_when_focused_pane_closes():
    t = three_in_a_row()        # focus c
    t.close("a")
    assert t.focus == "c"
    t.split("b", "h", "x")      # b, x, c ; focus x
    t.close("x")
    assert t.focus == "c"
    t.close("c")
    assert t.focus == "b"


def test_swap_keeps_sizes_and_focus_follows_id():
    t = three_in_a_row()
    t.swap("a", "c")
    assert t.leaves() == ["c", "b", "a"]
    assert same(t.snapshot(), ("h", [(0.5, "c"), (0.25, "b"), (0.25, "a")]))
    assert t.focus == "c"


def test_split_errors():
    t = SplitTree("a")
    for args in (("a", "x", "b"), ("a", "h", "a"), ("zz", "h", "b")):
        try:
            t.split(*args)
        except (ValueError, KeyError):
            pass
        else:
            raise AssertionError(args)
    assert t.snapshot() == "a"


def test_heir_can_be_a_split():
    t = SplitTree("a")
    t.split("a", "h", "b")
    t.split("b", "v", "c")      # h[a .5, v .5[b, c]]
    t.split("a", "h", "x")      # h[a .25, x .25, v .5]
    t.close("x")
    assert same(t.snapshot(), ("h", [(0.25, "a"), (0.75, ("v", [(0.5, "b"), (0.5, "c")]))]))
    t.close("a")                # a's share goes to the v split, which is now the root's only child
    assert same(t.snapshot(), ("v", [(0.5, "b"), (0.5, "c")]))


def _shares(snap, scale=1.0, out=None):
    out = {} if out is None else out
    if isinstance(snap, str):
        out[snap] = scale
    else:
        for r, c in snap[1]:
            _shares(c, scale * r, out)
    return out


def _normalized(snap, parent=None):
    if isinstance(snap, str):
        return True
    o, kids = snap
    return (len(kids) >= 2 and o != parent and approx(sum(r for r, _ in kids), 1)
            and all(r > 0 for r, _ in kids) and all(_normalized(c, o) for _, c in kids))


def test_random_ops_keep_the_contract():
    import random
    rng = random.Random(5)
    for trial in range(60):
        t = SplitTree("p0")
        order, focus, n = ["p0"], "p0", 1
        for _ in range(40):
            before = _shares(t.snapshot())
            roll = rng.random()
            if roll < 0.55 or len(order) == 1:
                pane, o, new = rng.choice(order), rng.choice("hv"), f"p{n}"
                n += 1
                t.split(pane, o, new)
                order.insert(order.index(pane) + 1, new)
                focus = new
                after = _shares(t.snapshot())
                assert approx(after[pane], before[pane] / 2) and approx(after[new], before[pane] / 2)
                assert all(approx(after[p], before[p]) for p in before if p != pane)
            elif roll < 0.85:
                pane = rng.choice(order)
                i = order.index(pane)
                t.close(pane)
                order.pop(i)
                if focus == pane:
                    focus = order[min(i, len(order) - 1)]
                after = _shares(t.snapshot())
                changed = [k for k, p in enumerate(order) if not approx(after[p], before[p])]
                assert changed and changed == list(range(changed[0], changed[-1] + 1))
                assert changed[0] == i or changed[-1] == i - 1
            else:
                a, b = rng.choice(order), rng.choice(order)
                t.swap(a, b)
                ia, ib = order.index(a), order.index(b)
                order[ia], order[ib] = b, a
                after = _shares(t.snapshot())
                assert approx(after[a], before[b]) and approx(after[b], before[a])
            snap = t.snapshot()
            assert _normalized(snap)
            assert t.leaves() == order and t.focus == focus
            assert approx(sum(_shares(snap).values()), 1)
            rects = t.layout(997, 613)
            assert sum(w * h for _, _, w, h in rects.values()) == 997 * 613
