use super::*;
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

/// A fake cmux API that answers every request with `status` and `reply` and keeps what it saw.
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
                format!("HTTP/1.1 {status} X\r\ncontent-type: application/json\r\nlocation: https://elsewhere.invalid/\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}", reply.len())
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
        .block_on(post(input.to_string().as_bytes()))
}

#[test]
fn a_post_carries_the_body_bearer_and_headers_and_answers_any_status() {
    let (api, seen) = api(409, r#"{"code":"key.already_registered"}"#);
    let answer = run(json!({"api": format!("{api}/"), "path": "/v1/ops", "body": r#"{"op":"x"}"#,
                            "bearer": "tok", "headers": {"x-cmux-team": "team_x", "x-cmux-client-version": "2.4.0"}}));
    assert_eq!(
        answer,
        json!({"ok": true, "status": 409, "body": r#"{"code":"key.already_registered"}"#})
    );
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert!(seen[0].starts_with("POST /v1/ops "), "{}", seen[0]);
    let lower = seen[0].to_ascii_lowercase();
    assert!(lower.contains("authorization: bearer tok"));
    assert!(lower.contains("x-cmux-team: team_x"));
    assert!(lower.contains("x-cmux-client-version: 2.4.0"));
    assert!(lower.contains("content-type: application/json"));
    assert!(seen[0].ends_with(r#"{"op":"x"}"#));
}

#[test]
fn a_redirect_is_answered_not_followed() {
    let (api, seen) = api(302, "");
    let answer = run(json!({"api": api, "path": "v1/install/token", "body": "{}", "bearer": null}));
    assert_eq!(answer["status"], 302);
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert!(!seen[0].to_ascii_lowercase().contains("authorization:"));
}

#[test]
fn plain_http_off_this_machine_and_odd_paths_are_refused_before_any_call() {
    let (api, seen) = api(200, "{}");
    for (base, path) in [
        ("http://cloud.example.com", "v1/ops"),
        ("https://user@cloud.example.com", "v1/ops"),
        (api.as_str(), "v1/ops?x=1"),
        (api.as_str(), "v1/../admin"),
    ] {
        let answer = run(json!({"api": base, "path": path, "body": "{}"}));
        assert_eq!(answer["error"]["kind"], "invalid", "{base} {path}");
    }
    assert_eq!(
        run(json!({"api": api, "path": "v1/ops", "headers": {"bad name": "x"}}))["error"]["kind"],
        "invalid"
    );
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn a_read_or_challenge_hedges_a_keyed_mutation_retries_once_the_rest_go_once() {
    assert_eq!(replay("v1/read", "{}"), Replay::Hedge);
    assert_eq!(replay("/v1/auth/challenge", "{}"), Replay::Hedge);
    assert_eq!(replay("v1/ops", r#"{"op":"x","idempotency_key":"k1"}"#), Replay::RetryOnce);
    assert_eq!(replay("v1/ops", r#"{"op":"x","idempotency_key":""}"#), Replay::Never);
    assert_eq!(replay("v1/install/token", "{}"), Replay::Never);
}

fn drive<T>(future: impl Future<Output = T>) -> T {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .start_paused(true)
        .build()
        .unwrap()
        .block_on(future)
}

fn connect_failure() -> Failed {
    Failed { kind: "connect", message: "refused".into() }
}

#[test]
fn a_hedged_read_starts_another_attempt_after_the_stagger_and_takes_the_first_answer() {
    let calls = AtomicUsize::new(0);
    let got = drive(send(Replay::Hedge, Duration::from_secs(1), 3, || {
        let n = calls.fetch_add(1, Ordering::SeqCst);
        async move {
            if n == 0 {
                // The black-holed first socket: never answers within the test.
                tokio::time::sleep(Duration::from_secs(60)).await;
            }
            Ok::<usize, Failed>(n)
        }
    }));
    assert_eq!(got.unwrap(), 1);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
}

#[test]
fn a_hedged_read_that_fails_every_time_stops_at_its_attempts() {
    let calls = AtomicUsize::new(0);
    let got = drive(send(Replay::Hedge, Duration::from_secs(1), 3, || {
        calls.fetch_add(1, Ordering::SeqCst);
        async { Err::<(), Failed>(connect_failure()) }
    }));
    assert_eq!(got.unwrap_err().kind, "connect");
    assert_eq!(calls.load(Ordering::SeqCst), 3);
}

#[test]
fn a_keyed_mutation_is_sent_again_only_after_a_connection_failure() {
    for (first, expected) in [("connect", 2), ("timeout", 2), ("transport", 1)] {
        let calls = AtomicUsize::new(0);
        let _ = drive(send(Replay::RetryOnce, Duration::from_secs(1), 3, || {
            let n = calls.fetch_add(1, Ordering::SeqCst);
            async move {
                if n == 0 { Err(Failed { kind: first, message: String::new() }) } else { Ok(()) }
            }
        }));
        assert_eq!(calls.load(Ordering::SeqCst), expected, "{first}");
    }
    let calls = AtomicUsize::new(0);
    let _ = drive(send(Replay::Never, Duration::from_secs(1), 3, || {
        calls.fetch_add(1, Ordering::SeqCst);
        async { Err::<(), Failed>(connect_failure()) }
    }));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
fn a_request_may_name_its_attempt_timeout_capped_and_a_resend_is_reported() {
    let one = |extra: Value| {
        let mut input = json!({"api": "https://api.example", "path": "v1/ops", "body": "{}"});
        input.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        request(input.to_string().as_bytes()).ok().unwrap().timeout
    };
    assert_eq!(one(json!({})), TIMEOUT);
    assert_eq!(one(json!({"timeout_secs": 40})), Duration::from_secs(40));
    assert_eq!(one(json!({"timeout_secs": 9999})), Duration::from_secs(MAX_TIMEOUT_SECS));
    // Nothing listens on a fresh port: a keyed mutation fails to connect, is sent once more, and says so.
    let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let answer = run(json!({"api": format!("http://127.0.0.1:{port}"), "path": "v1/ops",
                            "body": r#"{"idempotency_key":"k"}"#, "timeout_secs": 2}));
    assert_eq!(answer["ok"], json!(false));
    assert_eq!(answer["resent"], json!(true));
    let once =
        run(json!({"api": format!("http://127.0.0.1:{port}"), "path": "v1/ops", "body": "{}"}));
    assert!(once.get("resent").is_none());
}
