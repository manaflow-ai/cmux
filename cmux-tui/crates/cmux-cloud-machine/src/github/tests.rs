//! The GitHub App check (moved from the app's CloudGitHubAppTests).

use super::*;

#[test]
fn an_active_connection_on_a_configured_app_is_ready() {
    let ready = br#"{"configured":true,"app_slug":"cmux","connection":{"status":"active","account_login":"acme"}}"#;
    assert_eq!(status(200, ready), GitHubApp::Ready);
}

#[test]
fn every_other_answer_says_why() {
    for (code, text, expected) in [
        (
            200,
            r#"{"configured":true,"app_slug":"cmux","connection":null}"#,
            GitHubApp::NotConnected,
        ),
        (
            200,
            r#"{"configured":true,"app_slug":"cmux","allowed":false,"connection":{"status":"active"}}"#,
            GitHubApp::Unknown,
        ),
        (
            200,
            r#"{"configured":true,"app_slug":"cmux","allowed":true,"connection":{"status":"active"}}"#,
            GitHubApp::Ready,
        ),
        (
            200,
            r#"{"configured":true,"app_slug":"cmux","connection":{"status":"needs_reauth"}}"#,
            GitHubApp::NotConnected,
        ),
        (
            200,
            r#"{"configured":false,"app_slug":null,"connection":null}"#,
            GitHubApp::NotConfigured,
        ),
        (
            404,
            r#"{"error":{"code":"integration.not_found","message":"no GitHub connection"}}"#,
            GitHubApp::NotConnected,
        ),
        (
            503,
            r#"{"error":{"code":"integration.unavailable","message":"GitHub App is not configured"}}"#,
            GitHubApp::Unknown,
        ),
        (
            401,
            r#"{"error":{"code":"auth.unauthenticated","message":"sign in"}}"#,
            GitHubApp::Unknown,
        ),
        (200, r#"{"connection":{"status":"active"}}"#, GitHubApp::Unknown),
        (
            200,
            r#"{"configured":true,"app_slug":"","connection":{"status":"active"}}"#,
            GitHubApp::Unknown,
        ),
        (200, r#"{"configured":true,"connection":{"status":"active"}}"#, GitHubApp::Unknown),
        (
            200,
            "{\"configured\":true,\"app_slug\":\" \\n\",\"connection\":{\"status\":\"active\"}}",
            GitHubApp::Unknown,
        ),
        (200, "not json", GitHubApp::Unknown),
        (502, "", GitHubApp::Unknown),
    ] {
        assert_eq!(status(code, text.as_bytes()), expected, "{code} {text}");
    }
}

#[test]
fn only_a_team_id_reaches_the_url() {
    assert_eq!(
        path("team_01HZX9").as_deref(),
        Some("/v1/integrations/github/status?team=team_01HZX9")
    );
    for other in
        ["", "team_", "01HZX9", "team_a&b=c", "team_a/../x", "team_a b", "TEAM_a", "team_a\n"]
    {
        assert_eq!(path(other), None, "{other:?}");
    }
    assert!(path(&format!("team_{}", "a".repeat(120))).is_some());
    assert!(path(&format!("team_{}", "a".repeat(121))).is_none());
}
