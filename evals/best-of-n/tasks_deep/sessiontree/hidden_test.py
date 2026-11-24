from sessiontree import SessionTree, SessionError


def raises(fn, *args):
    try:
        fn(*args)
    except SessionError:
        return True
    return False


def work_tree():
    t = SessionTree()
    work = t.create("work")
    tests = t.create("Tests", work)
    build = t.create("build", work)
    return t, work, tests, build


def test_reported_rename_to_sibling_name_in_other_case():
    t, work, tests, build = work_tree()
    assert raises(t.rename, build, "tests")
    assert t.name(build) == "build"
    assert raises(t.create, "TESTS", work)


def test_rename_to_own_name_other_case_and_free_name():
    t, work, tests, build = work_tree()
    t.rename(tests, "tests")
    assert t.name(tests) == "tests"
    t.rename(build, "deploy")
    assert t.path(build) == "work/deploy"


def test_roots_are_siblings():
    t = SessionTree()
    t.create("Main")
    assert raises(t.create, "main")
    other = t.create("other")
    assert raises(t.rename, other, "MAIN")


def test_find_matches_like_uniqueness():
    t, work, tests, build = work_tree()
    api = t.create("API", build)
    assert t.find("work/build/API") == api
    assert t.find("Work/BUILD/api") == api
    assert t.find("work/tests") == tests
    assert t.find("work/nope") is None
    assert t.find("work/build/API/x") is None


def test_move_into_own_descendant_is_refused():
    t, work, tests, build = work_tree()
    api = t.create("api", build)
    leaf = t.create("leaf", api)
    assert raises(t.move, build, leaf)
    assert raises(t.move, work, api)
    assert raises(t.move, api, api)
    assert t.parent(build) == work and t.parent(api) == build
    assert t.children(work) == [tests, build]
    assert t.path(leaf) == "work/build/api/leaf"


def test_move_into_parent_with_same_name_is_refused():
    t, work, tests, build = work_tree()
    other = t.create("other")
    dup = t.create("TESTS", other)
    assert raises(t.move, dup, work)
    assert t.parent(dup) == other and t.children(work) == [tests, build]
    assert raises(t.move, other, None) is False  # already a root: a no-op
    assert raises(t.move, t.create("work", other), None)


def test_move_works_and_appends():
    t, work, tests, build = work_tree()
    other = t.create("other")
    x = t.create("x", other)
    t.move(x, work)
    assert t.children(work) == [tests, build, x]
    assert t.path(x) == "work/x" and t.children(other) == []
    t.move(tests, None)
    assert t.children(None) == [work, other, tests]
    assert t.find("Tests") == tests


def test_close_removes_every_descendant():
    t = SessionTree()
    root = t.create("root")
    kids = [t.create(f"k{i}", root) for i in range(4)]
    grand = [t.create("g", k) for k in kids]
    keep = t.create("keep")
    closed = t.close(root)
    assert sorted(closed) == sorted([root] + kids + grand)
    assert len(t) == 1 and keep in t
    assert all(s not in t for s in closed)
    assert t.children(None) == [keep]
    assert t.find("root") is None


def test_close_subtree_keeps_siblings():
    t, work, tests, build = work_tree()
    a = t.create("a", build)
    b = t.create("b", build)
    assert sorted(t.close(build)) == sorted([build, a, b])
    assert t.children(work) == [tests]
    t.create("build", work)


def test_bad_names_and_ids():
    t, work, tests, build = work_tree()
    assert raises(t.create, "a/b", work)
    assert raises(t.create, "", work)
    assert raises(t.rename, 999, "x")
    assert raises(t.move, tests, 999)
    assert t.children(work) == [tests, build]


def test_cost_does_not_grow_with_sibling_count():
    import time
    t = SessionTree()
    top = t.create("top")
    n = 5000
    start = time.perf_counter()
    ids = [t.create(f"s{i}", top) for i in range(n)]
    for i in range(0, n, 2):
        t.rename(ids[i], f"R{i}")
    assert t.find("top/r0") == ids[0] and t.find("top/s1") == ids[1]
    assert raises(t.rename, ids[1], "r2") and raises(t.create, "S3", top)
    assert time.perf_counter() - start < 0.6
    for i in range(n):
        assert t.find(f"top/{'r' if i % 2 == 0 else 's'}{i}") == ids[i]
    other = t.create("other")
    t.move(ids[-1], other)
    assert t.find("other/s4999") == ids[-1]
    t.create("s4999", top)
    assert len(t.close(top)) == n + 1
    assert time.perf_counter() - start < 0.6
