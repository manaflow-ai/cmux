use super::*;

#[test]
fn parses_issue_links_and_rejects_pull_requests() {
    assert_eq!(
        parse_issue_url("https://github.com/acme/widget/issues/42").unwrap(),
        GithubIssueLink { owner: "acme".into(), repo: "widget".into(), number: 42 }
    );
    assert!(parse_issue_url("https://github.com/acme/widget/pull/42").is_err());
    assert!(parse_issue_url("https://github.com/acme/widget/issues/0").is_err());
    assert!(parse_issue_url("https://github.com/../widget/issues/42").is_err());
    assert!(parse_issue_url("https://github.com/acme/../issues/42").is_err());
}

#[test]
fn names_fix_branches_from_number_and_title() {
    let issue = GithubIssueLink { owner: "acme".into(), repo: "widget".into(), number: 42 };
    assert_eq!(branch_name(&issue, "Fix flaky upload!"), "fix/42-fix-flaky-upload");
}

#[test]
fn matches_github_https_and_scp_origins_only() {
    assert_eq!(
        parse_github_origin("https://github.com/acme/widget.git"),
        Some(("acme".into(), "widget".into()))
    );
    assert_eq!(
        parse_github_origin("git@github.com:acme/widget.git"),
        Some(("acme".into(), "widget".into()))
    );
    assert_eq!(parse_github_origin("https://github.com.evil.example/acme/widget.git"), None);
    assert_eq!(parse_github_origin("https://gitlab.com/acme/widget.git"), None);
}
