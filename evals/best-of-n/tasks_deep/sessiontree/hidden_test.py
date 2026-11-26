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


def test_random_ops_match_a_simple_model():
    import random
    rng = random.Random(11)
    names = ["a", "A", "b", "B", "c", "x"]
    for trial in range(30):
        t = SessionTree()
        model = {}  # sid -> [name, parent]

        def kids(p):
            return [s for s, (n, q) in model.items() if q == p]

        def clash(p, name, ignore=None):
            return any(model[s][0].casefold() == name.casefold() for s in kids(p) if s != ignore)

        def ancestors_or_self(s):
            out = set()
            while s is not None:
                out.add(s)
                s = model[s][1]
            return out

        def path(s):
            parts = []
            while s is not None:
                parts.append(model[s][0])
                s = model[s][1]
            return "/".join(reversed(parts))

        for _ in range(80):
            ids = list(model)
            roll = rng.random()
            name = rng.choice(names)
            if roll < 0.4 or not ids:
                p = rng.choice(ids + [None])
                if clash(p, name):
                    assert raises(t.create, name, p)
                else:
                    model[t.create(name, p)] = [name, p]
            elif roll < 0.6:
                s = rng.choice(ids)
                if clash(model[s][1], name, ignore=s):
                    assert raises(t.rename, s, name)
                else:
                    t.rename(s, name)
                    model[s][0] = name
            elif roll < 0.85:
                s, p = rng.choice(ids), rng.choice(ids + [None])
                if p == model[s][1]:
                    t.move(s, p)
                elif (p is not None and s in ancestors_or_self(p)) or clash(p, model[s][0]):
                    assert raises(t.move, s, p)
                else:
                    t.move(s, p)
                    model[s][1] = p
            else:
                s = rng.choice(ids)
                gone = {x for x in model if s in ancestors_or_self(x)}
                assert set(t.close(s)) == gone
                for x in gone:
                    del model[x]
            assert len(t) == len(model)
            for s in model:
                assert t.path(s) == path(s)
                assert t.find(path(s).swapcase()) == s
                assert sorted(t.children(s)) == sorted(kids(s))


def test_casefold_not_lower_and_name_rules():
    t = SessionTree()
    top = t.create("top")
    s = t.create("STRASSE", top)
    assert raises(t.create, "straße", top)
    other = t.create("straße")
    assert raises(t.move, other, top)
    assert t.find("TOP/Straße") == s
    for bad in (" x", "x ", "a/b", ""):
        assert raises(t.rename, s, bad)
        assert raises(t.create, bad, top)
    assert t.name(s) == "STRASSE"
