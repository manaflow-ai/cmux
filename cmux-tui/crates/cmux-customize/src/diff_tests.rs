use super::unified;

#[test]
fn equal_texts_have_no_diff() {
    assert_eq!(unified("a\nb\n", "a\nb\n"), None);
}

#[test]
fn one_changed_line_shows_with_its_context() {
    let old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n";
    let new = "1\n2\n3\n4\nfive\n6\n7\n8\n9\n";
    assert_eq!(unified(old, new).unwrap(), "@@ -2,7 +2,7 @@\n 2\n 3\n 4\n-5\n+five\n 6\n 7\n 8\n");
}

#[test]
fn a_new_file_is_all_additions() {
    assert_eq!(unified("", "a\nb\n").unwrap(), "@@ -0,0 +1,2 @@\n+a\n+b\n");
}

#[test]
fn a_removed_tail_keeps_its_context() {
    assert_eq!(unified("a\nb\nc\n", "a\n").unwrap(), "@@ -1,3 +1,1 @@\n a\n-b\n-c\n");
}

#[test]
fn two_far_changes_are_two_hunks() {
    let old: String = (1..=30).map(|n| format!("{n}\n")).collect();
    let new = old.replace("\n3\n", "\nthree\n").replace("\n27\n", "\ntwenty-seven\n");
    let diff = unified(&old, &new).unwrap();
    assert_eq!(diff.matches("@@ -").count(), 2, "{diff}");
    assert!(diff.contains("-27\n+twenty-seven\n"));
}
