//! The Stack client against a fake Stack on a local port: the refresh exchange and its outcomes
//! (success, rejection, 429 with Retry-After and its cooldown, timeout), the 401 refresh-and-retry,
//! the API's 429 and known errors, the sign-in exchanges, the user and the team list.

mod fake;

use std::time::Duration;

use cmux_stack_auth::{
    AuthError, BodyKind, OAuthCallback, RefreshFailure, Session, SignInRateLimit, StackClient,
    StackConfig, StackError, TokenResolution,
};
use fake::{Reply, ok, serve, status, token};
use serde_json::json;

const TOKEN_PATH: &str = "/api/v1/auth/oauth/token";

fn client(origin: &str) -> StackClient {
    let mut config = StackConfig::new(origin, "proj-1", "pck_key");
    config.transport_retry_base = Duration::ZERO;
    config.refresh_lead = Duration::from_secs(60);
    StackClient::new(config).unwrap()
}

/// A session whose access token is still valid for 30 s of a 10-minute life: inside the lead,
/// so it is refreshed, but usable as a fallback.
fn stale_session() -> Session {
    Session::new(Some(&token(30, 600, "old")), Some("refresh-1"))
}

fn expired_session() -> Session {
    Session::new(Some(&token(-10, 600, "old")), Some("refresh-1"))
}

#[tokio::test]
async fn a_fresh_token_is_used_with_no_request() {
    let (origin, log) = serve(|_| ok(json!({})));
    let fresh = token(600, 900, "fresh");
    let mut session = Session::new(Some(&fresh), Some("refresh-1"));
    let resolution = client(&origin).likely_valid_access_token(&mut session).await;
    assert_eq!(resolution, TokenResolution::Valid(fresh));
    assert!(log.lock().unwrap().is_empty());
}

#[tokio::test]
async fn refresh_success_mints_a_token_into_the_session() {
    let minted = token(600, 600, "new");
    let answer = minted.clone();
    let (origin, log) = serve(move |seen| {
        assert_eq!(seen.target, TOKEN_PATH);
        ok(json!({ "access_token": answer }))
    });
    let mut session = expired_session();
    let resolution = client(&origin).likely_valid_access_token(&mut session).await;
    assert_eq!(resolution, TokenResolution::Valid(minted.clone()));
    assert_eq!(session.access_token.as_deref(), Some(minted.as_str()));
    assert_eq!(session.refresh_token.as_deref(), Some("refresh-1"));

    let log = log.lock().unwrap();
    let seen = &log[0];
    assert_eq!(seen.method, "POST");
    assert_eq!(seen.header("content-type").as_deref(), Some("application/x-www-form-urlencoded"));
    assert_eq!(seen.form_value("grant_type").as_deref(), Some("refresh_token"));
    assert_eq!(seen.form_value("refresh_token").as_deref(), Some("refresh-1"));
    assert_eq!(seen.form_value("client_id").as_deref(), Some("proj-1"));
    assert_eq!(seen.form_value("client_secret").as_deref(), Some("pck_key"));
    assert_eq!(seen.header("x-hexclave-project-id").as_deref(), Some("proj-1"));
    assert_eq!(seen.header("x-hexclave-publishable-client-key").as_deref(), Some("pck_key"));
    assert_eq!(seen.header("x-hexclave-access-type").as_deref(), Some("client"));
    // Stack answers 429 to the legacy aliases.
    assert!(seen.headers.iter().all(|(name, _)| !name.starts_with("x-stack-")));
}

#[tokio::test]
async fn a_project_with_no_key_sends_no_key_header_and_the_public_secret() {
    let (origin, log) = serve(|_| ok(json!({ "access_token": token(600, 600, "new") })));
    let mut config = StackConfig::new(&origin, "proj-1", "");
    config.transport_retry_base = Duration::ZERO;
    let mut session = expired_session();
    StackClient::new(config).unwrap().likely_valid_access_token(&mut session).await;
    let log = log.lock().unwrap();
    assert_eq!(log[0].header("x-hexclave-publishable-client-key"), None);
    assert_eq!(log[0].form_value("client_secret").as_deref(), Some("__stack_public_client__"));
}

#[tokio::test]
async fn an_invalid_refresh_token_401_empties_the_session() {
    let (origin, _) = serve(|_| status(401, json!({ "error": "invalid_grant" })));
    let mut session = stale_session();
    let resolution = client(&origin).likely_valid_access_token(&mut session).await;
    assert_eq!(resolution, TokenResolution::Rejected);
    assert_eq!(session, Session::default());
}

#[tokio::test]
async fn a_400_invalid_grant_is_a_rejection_too() {
    let (origin, _) = serve(|_| status(400, json!({ "error": "invalid_grant" })));
    let mut session = expired_session();
    let resolution = client(&origin).force_refresh_access_token(&mut session).await;
    assert_eq!(resolution, TokenResolution::Rejected);
    assert_eq!(session, Session::default());
}

#[tokio::test]
async fn a_5xx_or_unreadable_200_keeps_the_session() {
    for reply in [status(503, json!({})), ok(json!({ "no_token": true }))] {
        let reply = std::sync::Mutex::new(Some(reply));
        let (origin, _) = serve(move |_| reply.lock().unwrap().take().unwrap_or(Reply::Drop));
        let mut session = stale_session();
        let before = session.clone();
        let resolution = client(&origin).likely_valid_access_token(&mut session).await;
        assert!(matches!(
            resolution,
            TokenResolution::Fallback { failure: RefreshFailure::Transient, .. }
        ));
        assert_eq!(resolution.access_token(), before.access_token.as_deref());
        assert_eq!(session, before);
    }
}

#[tokio::test]
async fn a_429_with_retry_after_cools_down_and_falls_back() {
    let (origin, log) = serve(|_| {
        Reply::Answer(
            429,
            vec![("retry-after", "120".to_owned()), ("content-type", "text/html".to_owned())],
            "<html>slow down</html>".to_owned(),
        )
    });
    let stack = client(&origin);
    let mut session = stale_session();
    let first = stack.likely_valid_access_token(&mut session).await;
    assert_eq!(
        first,
        TokenResolution::Fallback {
            access_token: session.access_token.clone().unwrap(),
            failure: RefreshFailure::RateLimited { retry_after_s: Some(120.0) },
        }
    );
    // The cooldown holds the next exchange back: no second request.
    let mut expired = expired_session();
    let before = expired.clone();
    let second = stack.likely_valid_access_token(&mut expired).await;
    assert_eq!(second, TokenResolution::Unavailable(RefreshFailure::CoolingDown));
    assert_eq!(expired, before);
    assert_eq!(log.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn a_refresh_that_stalls_times_out_and_keeps_the_session() {
    let (origin, _) = serve(|_| Reply::Stall);
    let mut config = StackConfig::new(&origin, "proj-1", "pck_key");
    config.refresh_timeout = Duration::from_millis(300);
    let mut session = expired_session();
    let before = session.clone();
    let started = std::time::Instant::now();
    let resolution =
        StackClient::new(config).unwrap().likely_valid_access_token(&mut session).await;
    assert_eq!(resolution, TokenResolution::Unavailable(RefreshFailure::TimedOut));
    assert_eq!(session, before);
    assert!(started.elapsed() < Duration::from_secs(5));
}

#[tokio::test]
async fn a_request_that_stalls_times_out() {
    let (origin, _) = serve(|_| Reply::Stall);
    let mut config = StackConfig::new(&origin, "proj-1", "pck_key");
    config.request_timeout = Duration::from_millis(300);
    config.transport_retries = 0;
    let result = StackClient::new(config).unwrap().send_sign_in_code("a@b.c", "cmux://cb").await;
    assert_eq!(result, Err(StackError::TimedOut));
}

#[tokio::test]
async fn an_idempotent_request_is_retried_after_a_dropped_connection() {
    let count = std::sync::atomic::AtomicUsize::new(0);
    let fresh = token(600, 900, "fresh");
    let (origin, log) = serve(move |_| {
        if count.fetch_add(1, std::sync::atomic::Ordering::SeqCst) < 2 {
            Reply::Drop
        } else {
            ok(json!({ "items": [] }))
        }
    });
    let mut session = Session::new(Some(&fresh), Some("refresh-1"));
    let teams = client(&origin).list_teams(&mut session).await.unwrap();
    assert!(teams.is_empty());
    assert_eq!(log.lock().unwrap().len(), 3);
}

#[tokio::test]
async fn a_post_is_not_retried_after_a_dropped_connection() {
    let (origin, log) = serve(|_| Reply::Drop);
    let result = client(&origin).send_sign_in_code("a@b.c", "cmux://cb").await;
    assert!(matches!(result, Err(StackError::Network(_))), "{result:?}");
    assert_eq!(log.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn the_team_list_parses_and_leaves_out_vm_tenants() {
    let fresh = token(600, 900, "fresh");
    let (origin, log) = serve(|_| {
        ok(json!({ "items": [
            { "id": "t1", "display_name": "Acme", "profile_image_url": "https://img/a.png",
              "client_read_only_metadata": { "cmuxPlan": "pro" } },
            { "id": "t2", "display_name": "VM", "client_read_only_metadata": { "cmuxVmPersonalTenant": true } },
            { "id": "t3", "display_name": "Long plan", "client_read_only_metadata": { "cmuxPlan": "x".repeat(65) } },
            { "id": "t4", "display_name": "Plain" }
        ]}))
    });
    let mut session = Session::new(Some(&fresh), Some("refresh-1"));
    let teams = client(&origin).list_teams(&mut session).await.unwrap();
    let ids: Vec<_> = teams.iter().map(|t| t.id.as_str()).collect();
    assert_eq!(ids, ["t1", "t3", "t4"]);
    assert_eq!(teams[0].display_name, "Acme");
    assert_eq!(teams[0].plan.as_deref(), Some("pro"));
    assert_eq!(teams[0].profile_image_url.as_deref(), Some("https://img/a.png"));
    assert_eq!(teams[1].plan, None);

    let log = log.lock().unwrap();
    assert_eq!(log[0].method, "GET");
    assert_eq!(log[0].target, "/api/v1/teams?user_id=me");
    assert_eq!(log[0].header("x-hexclave-access-token").as_deref(), Some(fresh.as_str()));
    assert_eq!(log[0].header("x-hexclave-refresh-token").as_deref(), Some("refresh-1"));
    assert_eq!(log[0].header("x-hexclave-override-error-status").as_deref(), Some("true"));
    assert!(log[0].header("x-hexclave-random-nonce").is_some());
}

#[tokio::test]
async fn a_team_list_with_no_items_is_an_error_not_an_empty_list() {
    let fresh = token(600, 900, "fresh");
    let (origin, _) = serve(|_| ok(json!({ "unexpected": true })));
    let mut session = Session::new(Some(&fresh), Some("refresh-1"));
    let result = client(&origin).list_teams(&mut session).await;
    assert!(matches!(result, Err(StackError::Parse(_))));
}

#[tokio::test]
async fn signed_out_team_calls_say_so_without_a_request() {
    let (origin, log) = serve(|_| ok(json!({})));
    let mut session = Session::default();
    assert_eq!(client(&origin).list_teams(&mut session).await, Err(StackError::NotSignedIn));
    assert_eq!(client(&origin).current_user(&mut session).await, Ok(None));
    assert!(log.lock().unwrap().is_empty());
}

#[tokio::test]
async fn an_expired_access_token_401_refreshes_once_and_retries() {
    let first = token(600, 900, "first");
    let minted = token(600, 900, "minted");
    let rejected = first.clone();
    let answer = minted.clone();
    let (origin, log) = serve(move |seen| {
        if seen.target == TOKEN_PATH {
            return ok(json!({ "access_token": answer }));
        }
        if seen.header("x-hexclave-access-token").as_deref() == Some(rejected.as_str()) {
            return Reply::Answer(
                401,
                vec![("x-hexclave-known-error", "invalid_access_token".to_owned())],
                json!({ "message": "expired" }).to_string(),
            );
        }
        ok(json!({ "id": "u1", "primary_email": "a@b.c", "display_name": "A",
                   "selected_team": { "id": "t1" },
                   "client_read_only_metadata": { "cmuxReviewDemoContent": true } }))
    });
    let mut session = Session::new(Some(&first), Some("refresh-1"));
    let user = client(&origin).current_user(&mut session).await.unwrap().unwrap();
    assert_eq!(user.id, "u1");
    assert_eq!(user.primary_email.as_deref(), Some("a@b.c"));
    assert_eq!(user.selected_team_id.as_deref(), Some("t1"));
    assert!(user.demonstration_content_enabled);
    assert_eq!(session.access_token.as_deref(), Some(minted.as_str()));
    let targets: Vec<_> = log.lock().unwrap().iter().map(|s| s.target.clone()).collect();
    assert_eq!(targets, ["/api/v1/users/me", TOKEN_PATH, "/api/v1/users/me"]);
}

#[tokio::test]
async fn an_anonymous_user_is_no_user_and_a_string_demo_flag_is_off() {
    let fresh = token(600, 900, "fresh");
    let (origin, _) = serve(|_| ok(json!({ "id": "u1", "is_anonymous": true })));
    let mut session = Session::new(Some(&fresh), Some("refresh-1"));
    assert_eq!(client(&origin).current_user(&mut session).await, Ok(None));

    let (origin, _) = serve(|_| {
        ok(json!({ "id": "u2", "client_read_only_metadata": { "cmuxReviewDemoContent": "true" } }))
    });
    let user = client(&origin).current_user(&mut session).await.unwrap().unwrap();
    assert!(!user.demonstration_content_enabled);
    assert_eq!(user.selected_team_id, None);
}

#[tokio::test]
async fn an_api_429_reports_a_redacted_endpoint_and_its_retry_after() {
    let (origin, _) = serve(|_| {
        Reply::Answer(
            429,
            vec![
                ("retry-after", "7".to_owned()),
                ("x-hexclave-request-id", "req-9".to_owned()),
                ("content-type", "text/html".to_owned()),
            ],
            "<html/>".to_owned(),
        )
    });
    let error = client(&origin).send_sign_in_code("a@b.c", "cmux://cb").await.unwrap_err();
    let StackError::RateLimited(limit) = &error else { panic!("{error:?}") };
    assert_eq!(limit.endpoint, "/api/v1/auth/otp/send-sign-in-code");
    assert_eq!(limit.body_kind, BodyKind::Html);
    assert_eq!(limit.retry_after_s, Some(7.0));
    let sign_in = SignInRateLimit::from_error(&error).unwrap();
    assert_eq!(sign_in.retry_after, Some(Duration::from_secs(7)));
    assert_eq!(AuthError::display_safe(&error), None);
    assert_eq!(AuthError::failure_detail_for(&error), "RATE_LIMITED · HTTP 429 · Request ID req-9");
}

#[tokio::test]
async fn a_known_error_keeps_its_code_status_and_request_id() {
    let (origin, _) = serve(|_| {
        Reply::Answer(
            200,
            vec![
                ("x-hexclave-actual-status", "400".to_owned()),
                ("x-stack-known-error", "VERIFICATION_CODE_ERROR".to_owned()),
                ("x-hexclave-request-id", "req-1".to_owned()),
            ],
            json!({ "message": "bad code", "details": { "n": 1 } }).to_string(),
        )
    });
    let error = client(&origin).sign_in_with_code("123456nonce").await.unwrap_err();
    assert_eq!(
        error,
        StackError::Known {
            code: "VERIFICATION_CODE_ERROR".to_owned(),
            message: "bad code".to_owned(),
            http_status: 400,
            request_id: Some("req-1".to_owned()),
            details: Some(json!({ "n": 1 })),
        }
    );
    assert_eq!(AuthError::display_safe(&error), None);
    assert_eq!(
        AuthError::failure_detail_for(&error),
        "VERIFICATION_CODE_ERROR · HTTP 400 · Request ID req-1"
    );
}

#[tokio::test]
async fn the_code_sign_in_sends_the_code_and_answers_the_session() {
    let (origin, log) = serve(|seen| match seen.target.as_str() {
        "/api/v1/auth/otp/send-sign-in-code" => ok(json!({ "nonce": "n-1" })),
        _ => ok(json!({ "access_token": "a-1", "refresh_token": "r-1" })),
    });
    let stack = client(&origin);
    assert_eq!(stack.send_sign_in_code("a@b.c", "cmux://cb").await.unwrap(), "n-1");
    let session = stack.sign_in_with_code("123456n-1").await.unwrap();
    assert_eq!(session, Session::new(Some("a-1"), Some("r-1")));
    let log = log.lock().unwrap();
    assert_eq!(log[0].json(), json!({ "email": "a@b.c", "callback_url": "cmux://cb" }));
    assert_eq!(log[1].json(), json!({ "code": "123456n-1" }));
    assert_eq!(log[1].header("x-hexclave-access-token"), None);
}

#[tokio::test]
async fn a_sign_in_answer_with_no_refresh_token_is_a_parse_error() {
    let (origin, _) = serve(|_| ok(json!({ "access_token": "a-1" })));
    let result = client(&origin).sign_in_with_password("a@b.c", "pw").await;
    assert!(matches!(result, Err(StackError::Parse(_))));
}

#[tokio::test]
async fn the_oauth_code_exchange_proves_the_verifier() {
    let (origin, log) = serve(|_| ok(json!({ "access_token": "a-1", "refresh_token": "r-1" })));
    let stack = client(&origin);
    let start =
        stack.oauth_authorize_url("Google", "cmux://success", "cmux://error", None).unwrap();
    assert!(start.url.starts_with(&format!("{origin}/api/v1/auth/oauth/authorize/google?")));
    assert!(start.url.contains("code_challenge_method=S256"));
    assert!(start.url.contains(&format!("state={}", start.state)));
    assert!(!start.url.contains("token="));
    assert_eq!(start.code_verifier.len(), 64);
    assert!(!format!("{start:?}").contains(&start.code_verifier));

    let callback = OAuthCallback::parse("cmux://success?code=c-1&state=s");
    let session = stack.exchange_oauth_code(&callback, &start).await.unwrap();
    assert_eq!(session, Session::new(Some("a-1"), Some("r-1")));
    let log = log.lock().unwrap();
    assert_eq!(log[0].target, TOKEN_PATH);
    assert_eq!(log[0].form_value("grant_type").as_deref(), Some("authorization_code"));
    assert_eq!(log[0].form_value("code").as_deref(), Some("c-1"));
    assert_eq!(log[0].form_value("redirect_uri").as_deref(), Some("cmux://success"));
    assert_eq!(log[0].form_value("code_verifier").as_deref(), Some(start.code_verifier.as_str()));
}

#[tokio::test]
async fn an_oauth_refusal_keeps_its_error_code() {
    let (origin, _) =
        serve(|_| status(400, json!({ "error": "invalid_grant", "error_description": "used" })));
    let stack = client(&origin);
    let start =
        stack.oauth_authorize_url("github", "cmux://success", "cmux://error", Some("tok")).unwrap();
    assert!(start.url.contains("token=tok"));
    let error =
        stack.exchange_oauth_code(&OAuthCallback::Code("c".into()), &start).await.unwrap_err();
    assert_eq!(error, StackError::OAuth { code: "invalid_grant".into(), status: 400 });
    let missing =
        stack.exchange_oauth_code(&OAuthCallback::parse("cmux://success?x=1"), &start).await;
    assert_eq!(missing, Err(StackError::OAuth { code: "missing_code".into(), status: 0 }));
    let cancelled = OAuthCallback::parse("cmux://error?error=OAUTH_CANCELLED");
    let error = stack.exchange_oauth_code(&cancelled, &start).await.unwrap_err();
    assert_eq!(AuthError::display_safe(&error), Some(AuthError::Cancelled));
}

#[tokio::test]
async fn selecting_and_clearing_a_team_patches_the_user() {
    let fresh = token(600, 900, "fresh");
    let (origin, log) = serve(|_| ok(json!({})));
    let stack = client(&origin);
    let mut session = Session::new(Some(&fresh), Some("refresh-1"));
    stack.set_selected_team(&mut session, Some("t1")).await.unwrap();
    stack.set_selected_team(&mut session, None).await.unwrap();
    let log = log.lock().unwrap();
    assert_eq!(log[0].method, "PATCH");
    assert_eq!(log[0].target, "/api/v1/users/me");
    assert_eq!(log[0].json(), json!({ "selected_team_id": "t1" }));
    assert_eq!(log[1].json(), json!({ "selected_team_id": null }));
}

#[tokio::test]
async fn creating_a_team_selects_it() {
    let fresh = token(600, 900, "fresh");
    let (origin, log) = serve(|seen| match seen.method.as_str() {
        "POST" => ok(json!({ "id": "t9", "display_name": "New" })),
        _ => ok(json!({})),
    });
    let mut session = Session::new(Some(&fresh), Some("refresh-1"));
    let team = client(&origin).create_team(&mut session, "New").await.unwrap();
    assert_eq!(team.id, "t9");
    let log = log.lock().unwrap();
    assert_eq!(log[0].json(), json!({ "display_name": "New", "creator_user_id": "me" }));
    assert_eq!(log[1].json(), json!({ "selected_team_id": "t9" }));
}

#[tokio::test]
async fn revoking_a_session_deletes_the_current_one_and_skips_an_empty_pair() {
    let (origin, log) = serve(|_| ok(json!({})));
    let stack = client(&origin);
    stack.revoke_session(&Session::default()).await.unwrap();
    assert!(log.lock().unwrap().is_empty());
    stack.revoke_session(&Session::new(Some("a"), Some("r"))).await.unwrap();
    let log = log.lock().unwrap();
    assert_eq!(
        (log[0].method.as_str(), log[0].target.as_str()),
        ("DELETE", "/api/v1/auth/sessions/current")
    );
    assert_eq!(log[0].header("x-hexclave-refresh-token").as_deref(), Some("r"));
}

#[tokio::test]
async fn no_debug_line_holds_a_token() {
    let session = Session::new(Some("secret-access"), Some("secret-refresh"));
    let line = format!("{session:?} {:?}", TokenResolution::Valid("secret-access".into()));
    assert!(!line.contains("secret"), "{line}");
}
