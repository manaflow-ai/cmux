from hunkapply import HunkFailed, PatchError, apply, apply_text, parse
from pytest_shim import raises

SRC = ["def a():", "    return None", "", "def b():", "    return None", ""]


def failed_index(lines, diff):
    try:
        apply(lines, diff)
    except HunkFailed as e:
        return e.index
    raise AssertionError("did not raise HunkFailed")


def test_later_hunk_shifted_by_earlier_additions():
    diff = ("--- a/m.py\n+++ b/m.py\n"
            "@@ -1,1 +1,4 @@\n+import os\n+import sys\n+\n def a():\n"
            "@@ -5,1 +8,1 @@\n-    return None\n+    return 0\n")
    assert apply(SRC, diff) == ["import os", "import sys", "", "def a():", "    return None", "",
                                "def b():", "    return 0", ""]


def test_later_hunk_shifted_by_earlier_removals():
    lines = ["x", "y", "z", "k", "k", "w"]
    diff = "@@ -1,3 +1,0 @@\n-x\n-y\n-z\n@@ -5,1 +2,1 @@\n-k\n+K\n"
    assert apply(lines, diff) == ["k", "K", "w"]


def test_count_omitted_means_one():
    assert apply(["a", "b", "c"], "@@ -2 +2 @@\n-b\n+B\n") == ["a", "B", "c"]
    hunks = parse("@@ -2 +2,2 @@\n-b\n+B\n+B2\n")
    assert (hunks[0].old_len, hunks[0].new_len) == (1, 2)


def test_pure_insertion_goes_after_the_named_line():
    assert apply(["a", "b", "c"], "@@ -2,0 +3,2 @@\n+x\n+y\n") == ["a", "b", "x", "y", "c"]
    assert apply(["a", "b"], "@@ -0,0 +1,1 @@\n+top\n") == ["top", "a", "b"]


def test_hunk_found_earlier_than_expected():
    lines = ["one", "two", "target", "after"]
    diff = "@@ -5,2 +5,2 @@\n-target\n+TARGET\n after\n"
    assert apply(lines, diff) == ["one", "two", "TARGET", "after"]


def test_nearest_match_wins_and_before_beats_after():
    assert apply(["t", "x", "t"], "@@ -2,1 +2,1 @@\n-t\n+T\n") == ["T", "x", "t"]
    assert apply(["t", "x", "x", "x", "t", "x"], "@@ -4,1 +4,1 @@\n-t\n+T\n") == ["t", "x", "x", "x", "T", "x"]


def test_drift_of_earlier_hunk_carries_to_later_ones():
    view = ["h1", "r", "m1", "m2", "m3", "r", "end"]
    actual = ["p", "p", "p", "p"] + view
    diff = "@@ -1,1 +1,1 @@\n-h1\n+H1\n@@ -6,1 +6,1 @@\n-r\n+R\n"
    assert apply(actual, diff) == ["p", "p", "p", "p", "H1", "r", "m1", "m2", "m3", "R", "end"]


def test_never_matches_inside_an_earlier_hunk():
    diff = "@@ -1,1 +1,2 @@\n a\n+z\n@@ -3,1 +4,1 @@\n-z\n+Z\n"
    assert failed_index(["a", "b", "c", "d"], diff) == 1


def test_exact_multi_hunk_and_failure_index():
    lines = ["l%d" % i for i in range(1, 31)]
    diff = "@@ -2,2 +2,2 @@\n l2\n-l3\n+L3\n@@ -20,2 +20,3 @@\n l20\n+new\n l21\n"
    out = apply(lines, diff)
    assert out[:4] == ["l1", "l2", "L3", "l4"]
    assert out[19:22] == ["l20", "new", "l21"]
    assert len(out) == 31
    assert failed_index(lines, "@@ -2,1 +2,1 @@\n-l2\n+x\n@@ -10,1 +10,1 @@\n-nope\n+x\n") == 1
    assert failed_index(lines, "@@ -1,1 +1,1 @@\n-nope\n+x\n") == 0
    far = "@@ -1,1 +1,1 @@\n-l25\n+x\n"
    assert apply(lines, far, max_offset=24)[24] == "x"
    assert failed_index(lines, far) == 0


def test_text_wrapper_and_malformed():
    assert apply_text("a\nb\n", "@@ -2,1 +2,1 @@\n-b\n+c\n") == "a\nc\n"
    raises(PatchError, parse, "@@ -1,2 +1,2 @@\n-a\n+b\n")
    raises(PatchError, parse, "@@ nonsense @@\n")
