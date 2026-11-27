use super::*;

fn known(code: &str) -> StackError {
    StackError::Known {
        code: code.into(),
        message: "m".into(),
        http_status: 400,
        request_id: None,
        details: None,
    }
}

#[test]
fn codes_the_screen_renders_are_left_alone() {
    for code in ["SCHEMA_ERROR", "INVALID_TOTP_CODE", "otp_expired", "EMAIL_PASSWORD_MISMATCH"] {
        assert_eq!(AuthError::display_safe(&known(code)), None, "{code}");
    }
    assert_eq!(AuthError::display_safe(&StackError::Parse("x")), None);
    assert_eq!(AuthError::display_safe(&StackError::Client("x")), None);
}

#[test]
fn a_refused_redirect_names_the_refused_origin() {
    let refused = StackError::Known {
        code: "REDIRECT_URL_NOT_WHITELISTED".into(),
        message: "m".into(),
        http_status: 400,
        request_id: None,
        details: Some(serde_json::json!({
            "redirect_url": "https://cmux-staging.vercel.app/handler/sign-in?after_auth_return_to=x"
        })),
    };
    let expected =
        AuthError::RedirectNotAllowed { origin: Some("https://cmux-staging.vercel.app".into()) };
    assert_eq!(AuthError::display_safe(&refused), Some(expected.clone()));
    assert_eq!(expected.failure_detail(), "REDIRECT_URL_NOT_WHITELISTED");
    // An answer without details still reads as the plain refusal, never the generic error.
    assert_eq!(
        AuthError::display_safe(&known("redirect_url_not_whitelisted")),
        Some(AuthError::RedirectNotAllowed { origin: None })
    );
    let ported = StackError::Known {
        code: "REDIRECT_URL_NOT_WHITELISTED".into(),
        message: "m".into(),
        http_status: 400,
        request_id: None,
        details: Some(serde_json::json!({
            "redirect_url": "https://cmux-dev-backend-1.tail137216.ts.net:4123/handler/oauth-callback"
        })),
    };
    assert_eq!(
        rejected_redirect_origin(&ported).as_deref(),
        Some("https://cmux-dev-backend-1.tail137216.ts.net:4123")
    );
}

#[test]
fn auth_failures_collapse_and_everything_else_is_a_server_error() {
    for code in ["UNAUTHORIZED", "invalid_token", "TOKEN_EXPIRED"] {
        assert_eq!(AuthError::display_safe(&known(code)), Some(AuthError::Unauthorized), "{code}");
    }
    assert_eq!(AuthError::display_safe(&known("oauth_cancelled")), Some(AuthError::Cancelled));
    let server = Some(AuthError::ServerError(0, "auth_failed".into()));
    assert_eq!(AuthError::display_safe(&known("SOMETHING_NEW")), server);
    assert_eq!(
        AuthError::display_safe(&StackError::Http { status: 502, request_id: None }),
        server
    );
    // As in Swift: the client wraps a transport failure, so it reads as the generic error.
    assert_eq!(AuthError::display_safe(&StackError::Network("x")), server);
    assert_eq!(AuthError::display_safe(&StackError::TimedOut), server);
}

#[test]
fn only_unauthorized_clears_a_cached_session() {
    assert!(AuthError::Unauthorized.clears_cached_session());
    assert!(!AuthError::NetworkError.clears_cached_session());
    assert!(!AuthError::ServerError(500, "x".into()).clears_cached_session());
}

#[test]
fn the_failure_line_names_code_status_and_request_id_only() {
    let error = StackError::Http { status: 503, request_id: Some("r-1".into()) };
    assert_eq!(AuthError::failure_detail_for(&error), "HTTP_ERROR · HTTP 503 · Request ID r-1");
    let empty_id = StackError::Http { status: 503, request_id: Some(String::new()) };
    assert_eq!(AuthError::failure_detail_for(&empty_id), "HTTP_ERROR · HTTP 503");
    let oauth = StackError::OAuth { code: "invalid_grant".into(), status: 400 };
    assert_eq!(AuthError::failure_detail_for(&oauth), "INVALID_GRANT");
    assert_eq!(AuthError::failure_detail_for(&StackError::Network("x")), "NETWORK_ERROR");
    assert_eq!(AuthError::ServerError(429, "rate".into()).failure_detail(), "RATE · HTTP 429");
    assert_eq!(AuthError::ServerError(0, "auth_failed".into()).failure_detail(), "AUTH_FAILED");
    assert_eq!(
        AuthError::BrowserSignInFailed("closed".into()).failure_detail(),
        "BROWSER_SIGN_IN_FAILED"
    );
}
