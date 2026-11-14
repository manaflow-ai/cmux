use super::{BranchHeaders, branch_line, tracking};

#[test]
fn head_tracking_reads_each_form_that_git_prints() {
    assert_eq!(tracking(""), (0, 0));
    assert_eq!(tracking("gone"), (0, 0));
    assert_eq!(tracking("ahead 3"), (3, 0));
    assert_eq!(tracking("behind 12"), (0, 12));
    assert_eq!(tracking("ahead 3, behind 12"), (3, 12));
}

#[test]
fn head_branch_line_takes_only_the_line_of_the_branch() {
    let line = "refs/heads/a\0abc\0origin/a\0ahead 1, behind 2";
    let headers = BranchHeaders {
        head: Some("abc".to_string()),
        branch: Some("a".to_string()),
        upstream: Some("origin/a".to_string()),
        ahead: 1,
        behind: 2,
    };
    assert_eq!(branch_line(line, "refs/heads/a", "a"), Some(headers));
    // A branch below the name is another branch.
    assert_eq!(branch_line("refs/heads/a/b\0abc\0\0", "refs/heads/a", "a"), None);
    // No upstream.
    let alone = branch_line("refs/heads/a\0abc\0\0", "refs/heads/a", "a").unwrap();
    assert_eq!((alone.upstream, alone.ahead, alone.behind), (None, 0, 0));
    // A line that a cut output left short.
    assert_eq!(branch_line("refs/heads/a\0abc", "refs/heads/a", "a"), None);
}
