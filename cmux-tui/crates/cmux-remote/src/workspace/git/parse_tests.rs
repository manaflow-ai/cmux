//! Malformed `git status`, `git diff --name-status -z` and diff text are a
//! typed error or a whole-input section, never a panic.

use super::*;

#[test]
fn status_reads_branch_and_changes() {
    let (branch, changes) =
        parse_status(b"## main...origin/main\0 M src/lib.rs\0R  new.rs\0old.rs\0").unwrap();
    assert_eq!(branch.as_deref(), Some("main"));
    assert_eq!(changes.len(), 2);
    assert_eq!(changes[0].path, "src/lib.rs");
    assert_eq!((changes[0].index_status, changes[0].worktree_status), (' ', 'M'));
    assert_eq!(changes[1].path, "new.rs");
    assert_eq!(changes[1].original_path.as_deref(), Some("old.rs"));
}

#[test]
fn status_rejects_short_and_unspaced_entries() {
    for output in [&b"M\0"[..], b" M\0", b"MMx\0", b"##\0"] {
        let error = parse_status(output).unwrap_err();
        assert_eq!(error.code, "git-parse-error", "{output:?}");
    }
}

#[test]
fn status_rename_without_source_is_an_error() {
    let error = parse_status(b"R  new.rs\0").unwrap_err();
    assert_eq!(error.code, "git-parse-error");
}

#[test]
fn name_status_reads_every_kind() {
    let paths =
        parse_diff_path_metadata(b"M\0a.rs\0R100\0old.rs\0new.rs\0A\0b.rs\0D\0c.rs\0").unwrap();
    assert_eq!(paths.len(), 4);
    assert_eq!(paths[1].old_path.as_deref(), Some("old.rs"));
    assert_eq!(paths[1].new_path.as_deref(), Some("new.rs"));
    assert_eq!(paths[2].old_path, None);
    assert_eq!(paths[3].new_path, None);
}

#[test]
fn name_status_rejects_malformed_fields() {
    for output in [
        &b"M"[..],
        b"\0a.rs\0",
        b"Q\0a.rs\0",
        b"M1x\0a.rs\0",
        b"M\0a.rs",
        b"M\0\0",
        b"R100\0old.rs\0",
    ] {
        let error = parse_diff_path_metadata(output).err().expect("malformed metadata is an error");
        assert_eq!(error.code, "git-parse-error", "{output:?}");
    }
}

#[test]
fn diff_sections_split_at_each_header_and_keep_a_preamble() {
    let source = b"preamble\ndiff --git a/x b/x\n+1\ndiff --git a/y b/y\n+2";
    let sections = split_diff_section_ranges(source);
    assert_eq!(sections, vec![0..31, 31..source.len()]);
    assert_eq!(split_diff_section_ranges(b""), Vec::<Range<usize>>::new());
    assert_eq!(split_diff_section_ranges(b"no headers\n"), vec![0..11]);
}
