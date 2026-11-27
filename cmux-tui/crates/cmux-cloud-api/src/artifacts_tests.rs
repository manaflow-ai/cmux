//! `artifacts.read` against a fake platform on a local port: the route, query and headers sent,
//! the answer for every status, and each param refused before a request. Ported from the app's
//! `ArtifactsPageProviderTests` URL and fetch tests.

use std::io::{Read, Write as _};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::super::{Auth, Failure, Request, perform};

/// A fake that answers every request with `response` (the raw HTTP) and keeps each request's head.
fn fake(response: String) -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buffer = Vec::new();
            let mut chunk = [0_u8; 8192];
            while !buffer.windows(4).any(|w| w == b"\r\n\r\n") {
                let n = stream.read(&mut chunk).unwrap_or(0);
                if n == 0 {
                    break;
                }
                buffer.extend_from_slice(&chunk[..n]);
            }
            log.lock().unwrap().push(String::from_utf8_lossy(&buffer).to_lowercase());
            let _ = stream.write_all(response.as_bytes());
        }
    });
    (origin, seen)
}

fn answer(status: u16, headers: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {status} X\r\n{headers}content-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    )
}

fn request(api: &str, auth: Auth, args: Value) -> Request {
    Request {
        call: "artifacts.read".into(),
        api: api.into(),
        auth,
        credential: "access".into(),
        refresh: None,
        team: None,
        app_version: None,
        local_only: false,
        args: args.as_object().cloned().unwrap_or_default(),
    }
}

fn go(request: &Request) -> Result<Value, Failure> {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(perform(request, Zeroizing::new(Vec::new())))
}

fn body(answer: &Value) -> Vec<u8> {
    BASE64.decode(answer["body_base64"].as_str().unwrap()).unwrap()
}

#[test]
fn a_file_read_sends_the_bearer_and_answers_its_type_commit_and_body() {
    let (origin, seen) =
        fake(answer(200, "content-type: text/markdown\r\nx-artifacts-commit: abc123\r\n", "# hi"));
    let read = request(
        &origin,
        Auth::Worker,
        json!({"route": "file", "path": "notes/a.md", "ref": "main"}),
    );
    let answer = go(&read).unwrap();
    assert_eq!(answer["status"], 200);
    assert_eq!(answer["content_type"], "text/markdown");
    assert_eq!(answer["commit"], "abc123");
    assert_eq!(answer["size"], 4);
    assert_eq!(body(&answer), b"# hi");
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert!(
        seen[0].starts_with("get /v1/artifacts/file?ref=main&path=notes%2fa.md "),
        "{}",
        seen[0]
    );
    assert!(seen[0].contains("\r\nauthorization: bearer access\r\n"), "{}", seen[0]);
    assert!(!seen[0].contains("cookie"), "{}", seen[0]);
}

#[test]
fn each_query_value_is_encoded_whole() {
    let (origin, seen) = fake(answer(200, "content-type: application/json\r\n", "[]"));
    let path = "a&limit=9+b;c#d e";
    let read =
        request(&origin, Auth::Worker, json!({"route": "history", "path": path, "limit": 5}));
    go(&read).unwrap();
    let seen = seen.lock().unwrap();
    let line = seen[0].lines().next().unwrap();
    assert_eq!(line, "get /v1/artifacts/history?path=a%26limit%3d9%2bb%3bc%23d+e&limit=5 http/1.1");
}

#[test]
fn a_base_path_is_kept_and_an_empty_path_is_not_sent() {
    let (origin, seen) = fake(answer(200, "", "{}"));
    let read = request(
        &format!("{origin}/prefix/"),
        Auth::Worker,
        json!({"route": "tree", "path": "", "limit": 3}),
    );
    go(&read).unwrap();
    let seen = seen.lock().unwrap();
    assert!(seen[0].starts_with("get /prefix/v1/artifacts/tree http/1.1"), "{}", seen[0]);
}

#[test]
fn every_status_is_answered_for_the_app_to_read() {
    for status in [401_u16, 403, 404, 500] {
        let (origin, _seen) = fake(answer(status, "", "no"));
        let answer = go(&request(&origin, Auth::Worker, json!({"route": "tree"}))).unwrap();
        assert_eq!(answer["status"], status);
        assert_eq!(body(&answer), b"no");
    }
}

#[test]
fn a_redirect_is_not_followed() {
    let (elsewhere, elsewhere_seen) = fake(answer(200, "", "{}"));
    let (origin, seen) =
        fake(answer(302, &format!("location: {elsewhere}/v1/artifacts/tree\r\n"), ""));
    let answer = go(&request(&origin, Auth::Worker, json!({"route": "tree"}))).unwrap();
    assert_eq!(answer["status"], 302);
    assert_eq!(seen.lock().unwrap().len(), 1);
    assert!(elsewhere_seen.lock().unwrap().is_empty());
}

#[test]
fn a_file_too_large_to_preview_comes_back_without_its_body() {
    let big = "x".repeat(super::FILE_BODY_LIMIT + 1);
    let (origin, _seen) = fake(answer(200, "content-type: text/plain\r\n", &big));
    let answer =
        go(&request(&origin, Auth::Worker, json!({"route": "file", "path": "big"}))).unwrap();
    assert_eq!(answer["size"], super::FILE_BODY_LIMIT + 1);
    assert!(answer.get("body_base64").is_none());
}

#[test]
fn a_tree_or_history_body_is_kept_to_8_mib_and_counted_past_it() {
    for route in ["tree", "history"] {
        let at = "x".repeat(super::BODY_LIMIT);
        let (origin, _seen) = fake(answer(200, "content-type: application/json\r\n", &at));
        let answer = go(&request(&origin, Auth::Worker, json!({"route": route}))).unwrap();
        assert_eq!(answer["size"], super::BODY_LIMIT);
        assert_eq!(body(&answer).len(), super::BODY_LIMIT);

        // Chunked, so the length is counted from the stream rather than a declared length.
        let past = "x".repeat(super::BODY_LIMIT + 1);
        let chunked = format!(
            "HTTP/1.1 200 X\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n{:x}\r\n{past}\r\n0\r\n\r\n",
            past.len()
        );
        let (origin, _seen) = fake(chunked);
        let answer = go(&request(&origin, Auth::Worker, json!({"route": route}))).unwrap();
        assert_eq!(answer["size"], super::BODY_LIMIT + 1);
        assert!(answer.get("body_base64").is_none());
    }
}

#[test]
fn a_body_past_the_answer_cap_is_its_size_not_a_failure() {
    let huge = "x".repeat(crate::MAX_ANSWER_BYTES + 1);
    let (origin, _seen) = fake(answer(200, "content-type: application/octet-stream\r\n", &huge));
    let answer =
        go(&request(&origin, Auth::Worker, json!({"route": "file", "path": "huge"}))).unwrap();
    assert_eq!(answer["status"], 200);
    assert_eq!(answer["size"], crate::MAX_ANSWER_BYTES + 1);
    assert!(answer.get("body_base64").is_none());
}

#[test]
fn bad_params_and_origins_are_refused_before_any_request() {
    let (origin, seen) = fake(answer(200, "", "{}"));
    let refused = [
        json!({"route": "commits"}),
        json!({}),
        json!({"route": "file"}),
        json!({"route": "file", "path": ""}),
        json!({"route": "tree", "ref": "a\nb"}),
        json!({"route": "tree", "ref": "r".repeat(257)}),
        json!({"route": "tree", "path": "p".repeat(4097)}),
        json!({"route": "tree", "path": 3}),
        json!({"route": "history", "limit": 0}),
        json!({"route": "history", "limit": 101}),
        json!({"route": "history", "limit": "5"}),
    ];
    for args in refused {
        let failure = go(&request(&origin, Auth::Worker, args.clone())).unwrap_err();
        assert!(
            matches!(&failure, Failure::Http { status: 400, code: Some(code), .. } if code == "artifacts.invalid_params"),
            "{args}: {failure:?}"
        );
    }
    let stack = go(&request(&origin, Auth::Stack, json!({"route": "tree"}))).unwrap_err();
    assert!(matches!(stack, Failure::Http { status: 501, .. }), "{stack:?}");
    for api in [
        "http://example.com",
        "https://user@example.com",
        "https://example.com/?q=1",
        "ftp://example.com",
    ] {
        let failure = go(&request(api, Auth::Worker, json!({"route": "tree"}))).unwrap_err();
        assert!(matches!(failure, Failure::Transport(_)), "{api}: {failure:?}");
    }
    assert!(seen.lock().unwrap().is_empty());
    // At the limits, sent.
    go(&request(
        &origin,
        Auth::Worker,
        json!({"route": "history", "ref": "r".repeat(256), "path": "p".repeat(4096), "limit": 100}),
    ))
    .unwrap();
}
