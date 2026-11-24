from gitstatus import parse, summarize, status, badge, Entry


def test_reported_copy_in_index():
    entries, s = status(b"C  copy.txt\0orig.txt\0 M other.txt\0")
    assert [(e.x, e.y, e.path, e.orig_path) for e in entries] == [
        ("C", " ", "copy.txt", "orig.txt"), (" ", "M", "other.txt", None)]
    assert (s.staged, s.unstaged, s.renamed) == (1, 1, 1)


def test_rename_in_index_still_works():
    entries = parse("R  new name.txt\0old -> name.txt\0")
    assert entries == [Entry("R", " ", "new name.txt", "old -> name.txt")]


def test_rename_and_copy_in_work_tree_column():
    entries, s = status(" R moved.rs\0src.rs\0 C dup.rs\0base.rs\0?? new.rs\0")
    assert [(e.path, e.orig_path) for e in entries] == [("moved.rs", "src.rs"), ("dup.rs", "base.rs"),
                                                        ("new.rs", None)]
    assert (s.staged, s.unstaged, s.renamed, s.untracked) == (0, 2, 2, 1)


def test_rename_both_columns_modified():
    entries = parse("RM a.txt\0b.txt\0MM c.txt\0")
    assert [(e.x, e.y, e.path, e.orig_path) for e in entries] == [("R", "M", "a.txt", "b.txt"),
                                                                 ("M", "M", "c.txt", None)]
    assert summarize(entries).staged == 2 and summarize(entries).unstaged == 2


def test_every_unmerged_code_is_conflicted():
    codes = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
    data = "".join(f"{c} f{i}\0" for i, c in enumerate(codes))
    entries, s = status(data)
    assert [e.kind for e in entries] == ["conflicted"] * 7
    assert (s.conflicted, s.staged, s.unstaged) == (7, 0, 0)
    assert badge(s) == "7!"


def test_added_or_deleted_on_one_side_is_not_conflicted():
    entries, s = status("A  new.c\0D  gone.c\0AM half.c\0 D wt.c\0")
    assert [e.kind for e in entries] == ["changed"] * 4
    assert (s.conflicted, s.staged, s.unstaged) == (0, 3, 2)


def test_untracked_ignored_and_badge():
    entries, s = status(b"?? a\0?? dir/\0!! build/\0M  x\0AA y\0")
    assert (s.untracked, s.ignored, s.staged, s.conflicted) == (2, 1, 1, 1)
    assert badge(s) == "1! 1+ 2?"
    assert not s.clean


def test_clean_and_ignored_only():
    assert badge(status(b"")[1]) == "clean"
    entries, s = status(b"!! node_modules/\0")
    assert s.clean and s.ignored == 1 and badge(s) == "clean"


def test_paths_verbatim_including_newlines_and_spaces():
    entries = parse(b" M  lead space\0M  line\nbreak\0R  to\0 from \0")
    assert [e.path for e in entries] == [" lead space", "line\nbreak", "to"]
    assert entries[2].orig_path == " from "


def test_rename_without_source_path_is_an_error():
    for data in ("R  a\0", " C a\0"):
        try:
            parse(data)
        except ValueError:
            pass
        else:
            raise AssertionError(data)
