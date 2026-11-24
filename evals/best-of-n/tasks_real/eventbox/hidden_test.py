from eventbox import Mailbox


def drain(m):
    out = []
    while (e := m.pop()) is not None:
        out.append(e)
    return out


def test_bells_coalesce():
    # 43375208c90: a bell loop must not overflow the subscriber.
    m = Mailbox(4)
    for _ in range(1000):
        assert m.push(("bell", 1))
    assert not m.closed and not m.overflowed
    assert drain(m) == [("bell", 1)]


def test_plain_overflow():
    m = Mailbox(3)
    assert m.push(("x", 1)) and m.push(("y", 2)) and m.push(("z", 3))
    assert m.push(("w", 4)) is False
    assert m.closed and m.overflowed
    assert m.push(("bell", 1)) is False
    assert drain(m) == [("x", 1), ("y", 2), ("z", 3)]
    assert m.push(("x", 1)) is False


def test_coalesced_moves_to_newest():
    m = Mailbox(8)
    m.push(("title", 1, "a"))
    m.push(("x",))
    m.push(("title", 1, "b"))
    m.push(("title", 2, "c"))
    m.push(("config_reload", 1))
    m.push(("config_reload", 2))
    assert drain(m) == [("x",), ("title", 1, "b"), ("title", 2, "c"), ("config_reload", 2)]
    assert m.pop() is None


def test_new_key_needs_slot():
    m = Mailbox(2)
    assert m.push(("bell", 1)) and m.push(("bell", 2))
    assert m.push(("bell", 1)) and m.push(("scroll", 2, 5)) is False
    assert m.overflowed


def test_exited_discards_surface():
    m = Mailbox(3)
    m.push(("title", 1, "t"))
    m.push(("output", 1))
    m.push(("bell", 2))
    assert m.push(("exited", 1))
    assert drain(m) == [("bell", 2), ("exited", 1)]


def test_empty_keeps_closures():
    m = Mailbox(4)
    for e in [("exited", 1), ("x",), ("workspace_closed", 9), ("bell", 1)]:
        m.push(e)
    assert m.push(("empty",))
    assert drain(m) == [("exited", 1), ("workspace_closed", 9), ("empty",)]
    m = Mailbox(3)
    for e in [("exited", 1), ("exited", 2), ("exited", 3)]:
        m.push(e)
    assert m.push(("empty",)) and not m.closed
    assert drain(m) == [("exited", 2), ("exited", 3), ("empty",)]
    m = Mailbox(1)
    m.push(("exited", 1))
    assert m.push(("empty",))
    assert drain(m) == [("empty",)]


def test_tree_changed_dedup():
    m = Mailbox(4)
    assert m.push(("tree_changed",)) and m.push(("tree_changed",))
    assert drain(m) == [("tree_changed",)]
    m.push(("tree_changed",))
    m.push(("bell", 1))
    m.push(("tree_changed",))
    assert drain(m) == [("tree_changed",), ("bell", 1), ("tree_changed",)]
    m.push(("bell", 1))
    m.push(("tree_changed",))
    m.push(("tree_changed",))
    assert drain(m) == [("bell", 1), ("tree_changed",)]
    m = Mailbox(1)
    m.push(("tree_changed",))
    assert m.push(("tree_changed",)) and not m.closed


def test_all_coalesced_kinds():
    m = Mailbox(16)
    for k in ["title", "scroll", "bell", "output", "agent", "status"]:
        for i in range(5):
            assert m.push((k, 7, i))
    assert len(drain(m)) == 6
