use super::*;
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

const CODE: &str = "cmh_team_0123456789abcdefghij.abcdefghijABCDEFGHIJ0123456789-_abcdefghijk";

/// A fake cmux-api that answers every request with `status` and `reply` and keeps each request
/// as it arrived (head and body).
fn api(status: u16, reply: &'static str) -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buffer = Vec::new();
            let mut chunk = [0_u8; 8192];
            loop {
                let n = stream.read(&mut chunk).unwrap_or(0);
                buffer.extend_from_slice(&chunk[..n]);
                let text = String::from_utf8_lossy(&buffer).to_string();
                if let Some(end) = text.find("\r\n\r\n") {
                    let length = text[..end]
                        .lines()
                        .find_map(|l| {
                            l.to_ascii_lowercase()
                                .strip_prefix("content-length: ")
                                .map(|v| v.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if buffer.len() >= end + 4 + length {
                        break;
                    }
                }
                if n == 0 {
                    break;
                }
            }
            log.lock().unwrap().push(String::from_utf8_lossy(&buffer).to_string());
            let _ = stream.write_all(
                format!("HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}", reply.len())
                    .as_bytes(),
            );
        }
    });
    (origin, seen)
}

fn run(input: Value) -> Value {
    let _ = rustls::crypto::ring::default_provider().install_default();
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(relay(input.to_string().as_bytes()))
}

fn body_of(request: &str) -> Value {
    let body = request.split_once("\r\n\r\n").map_or("", |(_, body)| body);
    serde_json::from_str(body).unwrap_or(Value::Null)
}

fn authorization(request: &str) -> Option<String> {
    request.lines().find_map(|line| {
        let lower = line.to_ascii_lowercase();
        lower.strip_prefix("authorization: ").map(|_| line["authorization: ".len()..].to_owned())
    })
}

#[test]
fn a_mint_posts_the_apps_session_as_the_bearer_and_answers_the_code() {
    let reply = r#"{"code":"cmh_team_0123456789abcdefghij.abcdefghijABCDEFGHIJ0123456789-_abcdefghijk","expires_at":1700000120000,"user":"user_1","email":"a@b.c","device":"air"}"#;
    let (origin, seen) = api(201, reply);
    let answer = run(json!({
        "api": origin, "credential": "stack-access",
        "request": {"op": "mint", "device": "  air  "},
    }));
    assert_eq!(
        answer,
        json!({"ok": true, "value": {
            "code": CODE, "expires_at": 1_700_000_120_000_i64, "user": "user_1",
            "email": "a@b.c", "device": "air",
        }})
    );
    let seen = seen.lock().unwrap();
    assert!(seen[0].starts_with("POST /v1/auth/handoffs "), "{}", seen[0]);
    assert_eq!(authorization(&seen[0]).as_deref(), Some("Bearer stack-access"));
    assert_eq!(body_of(&seen[0]), json!({"device": "air"}));
}

#[test]
fn a_mint_signed_out_is_refused_before_any_request() {
    let (origin, seen) = api(201, "{}");
    for credential in [Value::Null, json!(""), json!("  ")] {
        let answer =
            run(json!({"api": origin, "credential": credential, "request": {"op": "mint"}}));
        assert_eq!(answer["error"]["code"], "not_signed_in");
    }
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn an_install_or_agent_token_gets_the_servers_403_as_not_signed_in() {
    // cmux-api refuses any bearer that is not the app's human Stack session (auth-handoff-routes.ts).
    let (origin, _seen) = api(
        403,
        r#"{"error":{"code":"auth_handoff.human_session_required","message":"only the app"}}"#,
    );
    let answer =
        run(json!({"api": origin, "credential": "install-token", "request": {"op": "mint"}}));
    assert_eq!(answer, refusal("not_signed_in", "only the app"));
}

#[test]
fn a_redeem_sends_no_bearer_even_with_a_credential_and_hands_back_the_session() {
    let reply = r#"{"already_signed_in":false,"access_token":"new-a","refresh_token":"new-r","user":"user_1","stack_user":"st_1","email":null,"device":"air","minted_device":"mini"}"#;
    let (origin, seen) = api(200, reply);
    let answer = run(json!({
        "api": origin, "credential": "this-macs-session",
        "request": {"op": "redeem", "code": CODE, "device": "air", "expected_user": "st_9"},
    }));
    assert_eq!(
        answer,
        json!({"ok": true, "value": {
            "session": {"access_token": "new-a", "refresh_token": "new-r"},
            "reply": {"signed_in": true, "already_signed_in": false, "user": "user_1",
                      "email": null, "device": "air"},
        }})
    );
    let seen = seen.lock().unwrap();
    assert!(seen[0].starts_with("POST /v1/auth/handoffs/redeem "), "{}", seen[0]);
    assert_eq!(authorization(&seen[0]), None);
    assert!(!seen[0].contains("this-macs-session"));
    assert_eq!(body_of(&seen[0]), json!({"code": CODE, "device": "air", "expected_user": "st_9"}));
}

#[test]
fn a_redeem_already_signed_in_has_no_session_and_one_without_tokens_is_unavailable() {
    let (origin, _seen) =
        api(200, r#"{"already_signed_in":true,"user":"user_1","stack_user":"st_1"}"#);
    let answer = run(json!({"api": origin, "credential": null,
                            "request": {"op": "redeem", "code": CODE}}));
    assert_eq!(answer["value"]["session"], Value::Null);
    assert_eq!(answer["value"]["reply"]["already_signed_in"], true);
    let (origin, _seen) = api(200, r#"{"user":"user_1","stack_user":"st_1","access_token":"a"}"#);
    let answer = run(json!({"api": origin, "credential": null,
                            "request": {"op": "redeem", "code": CODE}}));
    assert_eq!(answer["error"]["code"], "unavailable");
}

#[test]
fn a_bad_code_device_or_op_is_refused_before_any_request() {
    let (origin, seen) = api(200, "{}");
    for request in [
        json!({"op": "redeem", "code": "cmh_team_short.x"}),
        json!({"op": "redeem"}),
        json!({"op": "redeem", "code": CODE, "expected_user": 7}),
        json!({"op": "mint", "device": "x".repeat(65)}),
        json!({"op": "mint", "device": "a\nb"}),
        json!({"op": "mint", "device": 3}),
        json!({"op": "redeem", "code": CODE, "device": CODE}),
        json!({"op": "mint", "device": "cmh_team_x"}),
        json!({"op": "deploy"}),
    ] {
        let answer = run(json!({"api": origin, "credential": "tok", "request": request}));
        assert_eq!(answer["error"]["code"], "invalid_params", "{request}");
    }
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn server_codes_map_to_the_clis_codes() {
    for (server, socket) in [
        ("auth_handoff.invalid", "handoff_invalid"),
        ("auth_handoff.other_user", "other_user"),
        ("auth.sso_required", "sso_required"),
        ("auth_handoff.rate_limited", "rate_limited"),
        ("auth_handoff.human_session_required", "not_signed_in"),
        ("auth.unauthenticated", "not_signed_in"),
        ("auth_handoff.no_account", "not_signed_in"),
        ("validation.invalid", "invalid_params"),
        ("owner.unreachable", "unavailable"),
    ] {
        assert_eq!(socket_code(Some(server)), socket, "{server}");
    }
    assert_eq!(socket_code(None), "unavailable");
}

#[test]
fn an_api_that_does_not_answer_or_is_plain_http_elsewhere_is_unavailable() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    let answer = run(json!({"api": origin, "credential": "tok", "request": {"op": "mint"}}));
    assert_eq!(answer["error"]["code"], "unavailable");
    let answer = run(json!({"api": "http://example.com", "credential": "tok",
                            "request": {"op": "mint"}}));
    assert_eq!(answer["error"]["code"], "unavailable");
}
