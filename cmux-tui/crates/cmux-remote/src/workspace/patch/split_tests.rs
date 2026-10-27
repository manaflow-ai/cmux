//! A unified patch splits into one section per file at its `---`/`+++`
//! headers; a hunk line that looks like a header stays in its hunk.

use super::*;

#[test]
fn sections_split_at_each_file_and_stop_at_the_next_diff_header() {
    let source = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n\
                  diff --git a/y b/y\nindex 1..2\n--- a/y\n+++ b/y\n@@ -1 +1 @@\n-c\n+d\n";
    let sections = split_unified_patch(source).unwrap();
    assert_eq!(
        sections,
        vec![
            "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n".to_owned(),
            "--- a/y\n+++ b/y\n@@ -1 +1 @@\n-c\n+d\n".to_owned(),
        ]
    );
}

#[test]
fn a_removed_line_that_looks_like_a_header_stays_in_its_hunk() {
    let source = "--- a/x\n+++ b/x\n@@ -1,2 +1 @@\n--- not a header\n-a\n+b\n";
    let sections = split_unified_patch(source).unwrap();
    assert_eq!(sections, vec![source.to_owned()]);
}

#[test]
fn a_header_at_the_last_line_is_not_a_section() {
    let error = split_unified_patch("--- a/x").unwrap_err();
    assert_eq!(error.code, "invalid-patch");
    let error = split_unified_patch("").unwrap_err();
    assert_eq!(error.code, "invalid-patch");
}
