use super::*;

#[test]
fn push_failures_explain_the_remote_refusal_and_next_action() {
    let git = UserGit { root: std::path::Path::new("."), deadline: deadline() };
    let cases = [
        (
            Some("!\tHEAD:refs/heads/main\t[remote rejected] (protected branch hook declined)"),
            "remote: error: GH006: Protected branch update failed for refs/heads/main.",
            "rejected_by_remote",
            "feature branch",
        ),
        (
            Some("!\tHEAD:refs/heads/feature\t[rejected] (fetch first)"),
            "",
            "rejected_non_fast_forward",
            "pull first",
        ),
        (
            Some("!\tHEAD:refs/heads/feature\t[remote rejected] (pre-receive hook declined)"),
            "remote: repository rules rejected this update",
            "rejected_by_remote",
            "branch rules",
        ),
        (
            None,
            "fatal: Authentication failed for 'https://example.invalid/repo'",
            "auth_failed",
            "sign in",
        ),
    ];
    for (line, stderr, reason, action) in cases {
        let run = UserRun {
            success: false,
            code: Some(FATAL_EXIT),
            stdout: vec![],
            stderr: stderr.into(),
        };
        let error = classified(&git, line, &run);
        assert_eq!(error.details["reason"], reason);
        assert!(error.details["extra"]["message"].as_str().unwrap().contains(action));
    }
}
