use super::*;
use std::io::{Read as _, Write as _};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

/// A fake cmux VM API that answers every request with `status` and `reply` and keeps each
/// request as it arrived (head and body).
fn vm_api(status: u16, reply: &'static str) -> (String, Arc<Mutex<Vec<String>>>) {
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
        .block_on(mint(input.to_string().as_bytes()))
}

fn header<'a>(request: &'a str, name: &str) -> Option<&'a str> {
    request.lines().find_map(|line| {
        let (key, value) = line.split_once(": ")?;
        key.eq_ignore_ascii_case(name).then_some(value)
    })
}

#[test]
fn a_mint_posts_vm_scopes_with_the_session_and_team_to_the_selections_vm_api() {
    let (origin, seen) = vm_api(201, r#"{"key":"cmuxvm_sk_secret","id":"vmk_1"}"#);
    let answer = run(json!({
        "backend": {"kind": "production"}, "vmOrigin": origin, "credential": "stack-access",
        "teamId": "team_1", "params": {"ttlSeconds": 3600, "maxVms": 2, "scopes": ["admin"]},
    }));
    assert_eq!(
        answer,
        json!({"ok": true, "value": {"key": "cmuxvm_sk_secret", "id": "vmk_1", "baseUrl": origin, "teamId": "team_1"}})
    );
    let seen = seen.lock().unwrap();
    let request = &seen[0];
    assert!(request.starts_with("POST /v1/agent-keys "), "{request}");
    assert_eq!(header(request, "authorization"), Some("Bearer stack-access"));
    assert_eq!(header(request, "x-cmux-team-id"), Some("team_1"));
    let body: Value = serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap();
    assert_eq!(body["scopes"], json!(["vm:read", "vm:write", "vm:exec"]));
    assert_eq!(body["ttlSeconds"], 3600);
    assert_eq!(body["maxVms"], 2);
}

#[test]
fn a_refusal_carries_the_socket_code_and_never_the_key() {
    let (origin, _) = vm_api(403, r#"{"message":"no cmuxvm_sk_leaked here"}"#);
    let answer = run(json!({
        "backend": {"kind": "production"}, "vmOrigin": origin, "credential": "s", "teamId": "t",
    }));
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["error"]["code"], "forbidden");
    assert!(!answer.to_string().contains("leaked"), "{answer}");
    let (origin, _) = vm_api(401, "{}");
    let answer = run(json!({
        "backend": {"kind": "production"}, "vmOrigin": origin, "credential": "s", "teamId": "t",
    }));
    assert_eq!(answer["error"]["appText"], "notSignedIn");
}

#[test]
fn nothing_is_sent_without_a_session_a_team_or_valid_limits() {
    let (origin, seen) = vm_api(201, r#"{"key":"k"}"#);
    let base = |extra: Value| {
        let mut input = json!({"backend": {"kind": "production"}, "vmOrigin": origin, "credential": "s", "teamId": "t"});
        input.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        run(input)
    };
    assert_eq!(base(json!({"credential": " "}))["error"]["code"], "not_signed_in");
    assert_eq!(base(json!({"teamId": null}))["error"]["code"], "no_team");
    assert_eq!(base(json!({"params": {"maxVms": 99}}))["error"]["code"], "invalid_params");
    // A credential never goes over plain http to anything but loopback.
    assert_eq!(base(json!({"vmOrigin": "http://vm.example.com"}))["error"]["code"], "internal");
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn no_answer_is_unreachable() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    let answer = run(json!({
        "backend": {"kind": "production"}, "vmOrigin": origin, "credential": "s", "teamId": "t",
    }));
    assert_eq!(answer["error"]["code"], "unavailable");
    assert_eq!(answer["error"]["appText"], "unreachable");
    assert_eq!(answer["error"]["status"], 0);
}
