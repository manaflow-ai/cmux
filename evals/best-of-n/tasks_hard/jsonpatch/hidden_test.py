from jsonpatch import apply_patch as ap, PatchError
import pytest_shim as t


def test_add_remove_replace():
    assert ap({"a": 1}, [{"op": "add", "path": "/b", "value": 2}]) == {"a": 1, "b": 2}
    assert ap([1, 2], [{"op": "add", "path": "/1", "value": 9}]) == [1, 9, 2]
    assert ap([1, 2], [{"op": "add", "path": "/-", "value": 9}]) == [1, 2, 9]
    assert ap([1, 2], [{"op": "add", "path": "/2", "value": 9}]) == [1, 2, 9]
    assert ap([1, 2, 3], [{"op": "replace", "path": "/1", "value": 9}]) == [1, 9, 3]
    assert ap({"a": [1, 2]}, [{"op": "remove", "path": "/a/0"}]) == {"a": [2]}
    assert ap({"a": 1}, [{"op": "replace", "path": "", "value": [1]}]) == [1]


def test_pointer_escapes():
    d = {"a/b": 1, "m~n": 2, "~1": 3}
    assert ap(d, [{"op": "replace", "path": "/a~1b", "value": 5}])["a/b"] == 5
    assert ap(d, [{"op": "replace", "path": "/m~0n", "value": 5}])["m~n"] == 5
    assert ap(d, [{"op": "replace", "path": "/~01", "value": 5}])["~1"] == 5
    assert ap({"": 1}, [{"op": "replace", "path": "/", "value": 2}]) == {"": 2}
    t.raises(PatchError, ap, d, [{"op": "remove", "path": "/m~2n"}])
    t.raises(PatchError, ap, d, [{"op": "remove", "path": "a"}])


def test_index_rules():
    for p in ["/01", "/3", "/-", "/x", "/-1"]:
        t.raises(PatchError, ap, [1, 2], [{"op": "replace", "path": p, "value": 0}])
    t.raises(PatchError, ap, [1], [{"op": "add", "path": "/01", "value": 0}])
    t.raises(PatchError, ap, {"a": 1}, [{"op": "add", "path": "/a/b", "value": 0}])
    t.raises(PatchError, ap, {"a": 1}, [{"op": "replace", "path": "/b", "value": 0}])
    t.raises(PatchError, ap, {"a": 1}, [{"op": "remove", "path": ""}])


def test_move_copy():
    assert ap({"a": {"b": 1}, "c": 2}, [{"op": "move", "from": "/a/b", "path": "/c"}]) == {"a": {}, "c": 1}
    assert ap([1, 2, 3], [{"op": "move", "from": "/0", "path": "/-"}]) == [2, 3, 1]
    assert ap([1, 2, 3], [{"op": "move", "from": "/0", "path": "/2"}]) == [2, 3, 1]
    assert ap({"a": 1}, [{"op": "move", "from": "/a", "path": "/a"}]) == {"a": 1}
    t.raises(PatchError, ap, {"a": {"b": 1}}, [{"op": "move", "from": "/a", "path": "/a/c"}])
    out = ap({"a": [1]}, [{"op": "copy", "from": "/a", "path": "/b"}, {"op": "add", "path": "/b/-", "value": 2}])
    assert out == {"a": [1], "b": [1, 2]}


def test_test_op():
    d = {"a": [1, {"x": 1.0}], "t": True}
    assert ap(d, [{"op": "test", "path": "/a", "value": [1.0, {"x": 1}]}]) == d
    t.raises(PatchError, ap, d, [{"op": "test", "path": "/t", "value": 1}])
    t.raises(PatchError, ap, {"z": 0}, [{"op": "test", "path": "/z", "value": False}])
    t.raises(PatchError, ap, d, [{"op": "test", "path": "/a", "value": [{"x": 1}, 1]}])


def test_atomic_and_copies():
    d = {"a": [1, 2]}
    t.raises(PatchError, ap, d, [{"op": "add", "path": "/a/-", "value": 3}, {"op": "remove", "path": "/zz"}])
    assert d == {"a": [1, 2]}
    v = {"k": [1]}
    out = ap({}, [{"op": "add", "path": "/x", "value": v}])
    v["k"].append(2)
    assert out == {"x": {"k": [1]}}
    out = ap(d, [{"op": "add", "path": "/b", "value": 0}])
    out["a"].append(9)
    assert d == {"a": [1, 2]}


def test_bad_ops():
    t.raises(PatchError, ap, {}, [{"op": "frob", "path": "/a"}])
    t.raises(PatchError, ap, {}, [{"op": "add", "path": "/a"}])
    t.raises(PatchError, ap, {}, [{"path": "/a", "value": 1}])
    t.raises(PatchError, ap, {"a": 1}, [{"op": "move", "path": "/b"}])
