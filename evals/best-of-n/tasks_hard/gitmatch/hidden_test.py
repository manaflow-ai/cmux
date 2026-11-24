from gitmatch import is_ignored as ig


def test_basename_and_anchor():
    assert ig(["*.log"], "a/b/x.log") and ig(["*.log"], "x.log") and not ig(["*.log"], "x.logs")
    assert ig(["/build"], "build") and not ig(["/build"], "src/build")
    assert ig(["doc/*.txt"], "doc/a.txt") and not ig(["doc/*.txt"], "doc/x/a.txt") and not ig(["doc/*.txt"], "a/doc/b.txt")
    assert ig(["build"], "src/build/out.o")


def test_dir_only():
    assert ig(["out/"], "out", is_dir=True) and not ig(["out/"], "out") and ig(["out/"], "a/out/f.txt")
    assert not ig(["out/"], "a/out")


def test_negation_and_parent_rule():
    assert not ig(["*.log", "!keep.log"], "keep.log") and ig(["*.log", "!keep.log"], "a.log")
    assert ig(["!keep.log", "*.log"], "keep.log")
    assert ig(["logs/", "!logs/keep.log"], "logs/keep.log")
    assert not ig(["logs/*", "!logs/keep.log"], "logs/keep.log") and ig(["logs/*", "!logs/keep.log"], "logs/x")


def test_double_star():
    assert ig(["**/foo"], "foo") and ig(["**/foo"], "a/b/foo") and ig(["**/foo/bar"], "x/foo/bar")
    assert ig(["a/**"], "a/x/y") and not ig(["a/**"], "a", is_dir=True) and not ig(["a/**"], "b/a/x")
    assert ig(["a/**/b"], "a/b") and ig(["a/**/b"], "a/x/y/b") and not ig(["a/**/b"], "a/xb")
    assert ig(["foo**bar"], "fooxbar") and not ig(["foo**bar"], "foo/bar")


def test_classes_and_escapes():
    assert ig(["file[0-9].txt"], "file3.txt") and not ig(["file[0-9].txt"], "filex.txt")
    assert ig(["file[!0-9].txt"], "filex.txt") and not ig(["file[!0-9].txt"], "file3.txt")
    assert ig(["?.c"], "a.c") and not ig(["?.c"], "ab.c") and ig(["\\*.c"], "*.c") and not ig(["\\*.c"], "a.c")
    assert ig(["\\#x"], "#x") and ig(["\\!x"], "!x") and not ig(["#x"], "#x")


def test_spaces_and_blank():
    assert ig(["a.txt   "], "a.txt") and ig(["a\\ "], "a ") and not ig(["", "  "], "x")
