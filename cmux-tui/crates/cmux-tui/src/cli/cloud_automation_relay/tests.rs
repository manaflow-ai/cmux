use super::*;
use serde_json::json;
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

/// A fake owner that answers every request with `reply` and keeps what it saw.
fn owner(status: u16, reply: &'static str) -> (String, Arc<Mutex<Vec<String>>>) {
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

#[test]
fn a_read_is_posted_to_v1_read_with_the_bearer() {
    let (api, seen) = owner(200, r#"{"ok":true,"value":{"automations":[]}}"#);
    let answer = run(
        json!({"api": api, "credential": "tok", "request": {"op": "automation.list", "params": {"limit": 50}}}),
    );
    assert_eq!(answer, json!({"ok": true, "value": {"automations": []}}));
    let seen = seen.lock().unwrap();
    assert!(seen[0].starts_with("POST /v1/read "), "{}", seen[0]);
    assert!(seen[0].to_ascii_lowercase().contains("authorization: bearer tok"));
}

#[test]
fn signed_out_is_refused_before_any_call() {
    let (api, seen) = owner(200, "{}");
    let answer = run(json!({"api": api, "credential": null, "request": {"op": "automation.list"}}));
    assert_eq!(answer["error"]["code"], "automation.signed_out");
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn a_refused_op_never_reaches_the_owner() {
    let (api, seen) = owner(200, "{}");
    let answer = run(
        json!({"api": api, "credential": "tok", "request": {"op": "automation.deploy", "idempotency_key": "k"}}),
    );
    assert_eq!(answer["error"]["code"], "automation.op_not_allowed");
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn an_owner_that_does_not_answer_is_unreachable() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let api = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    let answer =
        run(json!({"api": api, "credential": "tok", "request": {"op": "automation.list"}}));
    assert_eq!(answer["error"]["code"], "owner.unreachable");
}

#[test]
fn plain_http_to_another_host_is_refused() {
    let answer = run(
        json!({"api": "http://example.com", "credential": "tok", "request": {"op": "automation.list"}}),
    );
    assert_eq!(answer["error"]["code"], "owner.unreachable");
}
