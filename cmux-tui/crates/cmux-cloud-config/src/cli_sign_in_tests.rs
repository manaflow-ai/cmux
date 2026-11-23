use super::*;

fn project(base: &str) -> Project {
    Project {
        stack_base_url: base.to_owned(),
        project_id: "proj".to_owned(),
        publishable_client_key: "pck".to_owned(),
    }
}

fn header<'a>(call: &'a HttpCall, name: &str) -> Option<&'a str> {
    call.headers.iter().find(|(key, _)| key == name).map(|(_, value)| value.as_str())
}

#[test]
fn start_posts_to_stack_cli_with_the_client_headers() {
    let call = start_request(&project("https://api.stack-auth.com"));
    assert_eq!(call.method, "POST");
    assert_eq!(call.url, "https://api.stack-auth.com/api/v1/auth/cli");
    assert_eq!(header(&call, "x-stack-project-id"), Some("proj"));
    assert_eq!(header(&call, "x-stack-publishable-client-key"), Some("pck"));
    assert_eq!(header(&call, "x-stack-access-type"), Some("client"));
    let body: Value = serde_json::from_str(&call.body).unwrap();
    assert_eq!(body["expires_in_millis"], LOGIN_EXPIRES_IN_MS);
}

#[test]
fn a_base_that_already_names_the_api_version_is_not_doubled() {
    for base in ["https://s.example/api/v1", "https://s.example/api/v1/", "https://s.example/"] {
        assert_eq!(poll_request(&project(base), "p").url, "https://s.example/api/v1/auth/cli/poll");
    }
}

#[test]
fn the_measured_start_answer_opens_cmux_confirmation_page() {
    let body =
        r#"{"polling_code":"pc1","login_code":"lc 1","expires_at":"2026-11-22T00:41:00.281Z"}"#;
    assert_eq!(
        read_start(200, body, "https://cmux.com/"),
        Started::Started {
            polling_code: "pc1".to_owned(),
            confirm_url: "https://cmux.com/handler/cli-auth-confirm?login_code=lc%201".to_owned(),
            expires_at: "2026-11-22T00:41:00.281Z".to_owned(),
        }
    );
}

#[test]
fn a_start_without_codes_or_with_an_error_is_refused() {
    assert_eq!(
        read_start(200, "{}", "https://cmux.com"),
        Started::Refused { reason: "200 no login code".to_owned() }
    );
    assert_eq!(
        read_start(429, r#"{"code":"RATE_LIMITED"}"#, "https://cmux.com"),
        Started::Refused { reason: "429 RATE_LIMITED".to_owned() }
    );
    assert_eq!(
        read_start(502, "<html>", "https://cmux.com"),
        Started::Refused { reason: "502".to_owned() }
    );
}

#[test]
fn poll_carries_the_polling_code() {
    let call = poll_request(&project("https://api.stack-auth.com"), "pc1");
    let body: Value = serde_json::from_str(&call.body).unwrap();
    assert_eq!(body["polling_code"], "pc1");
}

#[test]
fn poll_answers_read_as_wait_sign_in_end_or_retry() {
    assert_eq!(read_poll(200, r#"{"status":"waiting"}"#), Polled::Waiting);
    assert_eq!(
        read_poll(201, r#"{"status":"success","refresh_token":"rt"}"#),
        Polled::SignedIn { refresh_token: "rt".to_owned() }
    );
    assert_eq!(
        read_poll(200, r#"{"status":"success"}"#),
        Polled::Ended { reason: "confirmed without a session".to_owned() }
    );
    assert_eq!(
        read_poll(200, r#"{"status":"expired"}"#),
        Polled::Ended { reason: "expired".to_owned() }
    );
    assert_eq!(read_poll(200, r#"{"status":"used"}"#), Polled::Ended { reason: "used".to_owned() });
    assert_eq!(
        read_poll(400, r#"{"code":"INVALID_POLLING_CODE"}"#),
        Polled::Ended { reason: "400 INVALID_POLLING_CODE".to_owned() }
    );
    assert_eq!(read_poll(429, "{}"), Polled::Retry { reason: "429".to_owned() });
    assert_eq!(read_poll(503, ""), Polled::Retry { reason: "503".to_owned() });
    assert_eq!(read_poll(200, "{}"), Polled::Retry { reason: "200 no status".to_owned() });
}

#[test]
fn the_refresh_sends_the_confirmed_token_and_keeps_it_when_not_rotated() {
    let call = token_request(&project("https://api.stack-auth.com"), "rt");
    assert_eq!(call.url, "https://api.stack-auth.com/api/v1/auth/sessions/current/refresh");
    assert_eq!(header(&call, "x-stack-refresh-token"), Some("rt"));
    assert_eq!(
        read_token(200, r#"{"access_token":"at"}"#, "rt"),
        Tokens::Tokens { access_token: "at".to_owned(), refresh_token: "rt".to_owned() }
    );
    assert_eq!(
        read_token(200, r#"{"access_token":"at","refresh_token":"rt2"}"#, "rt"),
        Tokens::Tokens { access_token: "at".to_owned(), refresh_token: "rt2".to_owned() }
    );
    assert_eq!(
        read_token(401, r#"{"code":"REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED"}"#, "rt"),
        Tokens::Refused { reason: "401 REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED".to_owned() }
    );
}

#[test]
fn answers_serialize_with_a_kind_tag_for_the_app() {
    let json = serde_json::to_value(Polled::SignedIn { refresh_token: "rt".to_owned() }).unwrap();
    assert_eq!(json, serde_json::json!({ "kind": "signedIn", "refreshToken": "rt" }));
    assert_eq!(
        serde_json::to_value(Polled::Waiting).unwrap(),
        serde_json::json!({ "kind": "waiting" })
    );
}
