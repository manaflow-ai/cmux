use std::io::{Read as _, Write as _};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::serve;

const HAND: &str = "hand_abcdefghij234567klmn";
const IDLE: &str = "hand_zzzzzzzzzz234567zzzz";
const ID: &str = "0f6c2a9e-1b2c-4d5e-8f90-123456789abc";
const NONCE: &str = "00112233445566778899aabbccddeeff";

/// One request the fake owner saw: its request line and JSON body.
#[derive(Debug, Clone)]
struct Seen {
    line: String,
    body: Value,
}

/// A fake API Worker; `handler` answers each request (status, body).
fn owner(
    handler: impl Fn(&Seen) -> (u16, String) + Send + Sync + 'static,
) -> (String, Arc<Mutex<Vec<Seen>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buffer = Vec::new();
            let mut chunk = [0_u8; 8192];
            let (head, body) = loop {
                let n = stream.read(&mut chunk).unwrap_or(0);
                buffer.extend_from_slice(&chunk[..n]);
                if let Some(end) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                    let head = String::from_utf8_lossy(&buffer[..end]).to_string();
                    let length = head
                        .lines()
                        .find_map(|l| {
                            l.to_ascii_lowercase()
                                .strip_prefix("content-length: ")
                                .map(|v| v.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if buffer.len() >= end + 4 + length || n == 0 {
                        break (head, buffer[end + 4..].to_vec());
                    }
                } else if n == 0 {
                    break (String::new(), Vec::new());
                }
            };
            let line = head.lines().next().unwrap_or_default().to_owned();
            let request = Seen { line, body: serde_json::from_slice(&body).unwrap_or(Value::Null) };
            let (status, reply) = handler(&request);
            if !request.line.contains("/v1/wire/user") {
                log.lock().unwrap().push(request);
            }
            let _ = stream.write_all(
                format!("HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}", reply.len())
                    .as_bytes(),
            );
        }
    });
    (origin, seen)
}

fn ok(value: Value) -> (u16, String) {
    (200, json!({ "ok": true, "value": value }).to_string())
}

fn refused(status: u16, code: &str) -> (u16, String) {
    (status, json!({ "ok": false, "error": { "code": code, "message": "no" } }).to_string())
}

/// The usual owner: two hands, one waiting request on the first.
fn hands_owner(seen: &Seen) -> (u16, String) {
    let line = seen.line.as_str();
    if line.starts_with("GET /v1/hands ") {
        ok(json!([
            {"hand": HAND, "name": "Build box", "profile": "mac", "online": true, "level": "ask", "pending_approvals": 1},
            {"hand": IDLE, "name": "", "pending_approvals": 0},
        ]))
    } else if line.starts_with(&format!("GET /v1/hands/{HAND}/approvals ")) {
        ok(json!([{ "id": ID, "summary": {"action": "exec", "argv": ["ls"]}, "at": 5 }]))
    } else if line.starts_with(&format!("POST /v1/hands/{HAND}/approvals/{ID} ")) {
        ok(json!({}))
    } else if line.contains("/level-challenge ") || line.contains("/challenge ") {
        ok(json!({ "nonce": NONCE }))
    } else if line.starts_with("PUT ") {
        ok(json!({}))
    } else {
        (404, "{}".into())
    }
}

/// The engine with a test app: tokens are answered with `credential`.
struct App {
    input: mpsc::UnboundedSender<String>,
    events: mpsc::UnboundedReceiver<Value>,
    credential: Option<&'static str>,
    next: u64,
}

impl App {
    fn new(credential: Option<&'static str>) -> Self {
        let (input, lines) = mpsc::unbounded_channel();
        let (sender, events) = mpsc::unbounded_channel();
        tokio::spawn(serve(lines, move |event: Value| {
            let _ = sender.send(event);
        }));
        Self { input, events, credential, next: 0 }
    }

    fn send(&self, command: Value) {
        self.input.send(command.to_string()).unwrap();
    }

    fn start(&self, api: &str) {
        self.send(json!({"t": "start", "api": api, "app_version": "1.0"}));
    }

    /// The next event named `kind` (answering token asks on the way).
    async fn next(&mut self, kind: &str) -> Value {
        let wait = async {
            loop {
                let event = self.events.recv().await.expect("engine ended");
                if event["event"] == "token" {
                    self.send(
                        json!({"t": "token", "id": event["id"], "credential": self.credential}),
                    );
                    continue;
                }
                if event["event"] == kind {
                    return event;
                }
            }
        };
        tokio::time::timeout(std::time::Duration::from_secs(10), wait).await.expect(kind)
    }

    async fn call(&mut self, op: &str, params: Value) -> Value {
        self.next += 1;
        let mut command = json!({"t": "call", "id": self.next, "op": op});
        for (key, value) in params.as_object().unwrap() {
            command[key] = value.clone();
        }
        self.send(command);
        loop {
            let reply = self.next("reply").await;
            if reply["id"] == self.next {
                return reply;
            }
        }
    }
}

fn key() -> String {
    format!("hand-approval.{HAND}.{ID}")
}

async fn refreshed(api: &str) -> App {
    let mut app = App::new(Some("tok"));
    app.start(api);
    let reply = app.call("refresh", json!({})).await;
    assert_eq!(reply["ok"], true, "{reply}");
    app
}

#[tokio::test]
async fn a_refresh_reads_the_hands_and_posts_their_waiting_requests() {
    let (api, seen) = owner(hands_owner);
    let mut app = App::new(Some("tok"));
    app.start(&api);
    app.next += 1;
    app.send(json!({"t": "call", "id": app.next, "op": "refresh"}));
    let hands = app.next("hands").await;
    assert_eq!(hands["hands"][0]["level"], "ask");
    let pending = app.next("pending").await;
    assert_eq!(pending["name"], "Build box");
    assert_eq!(pending["approval"]["key"], key());
    assert_eq!(pending["approval"]["summary"], "exec: ls");
    assert_eq!(app.next("reply").await["ok"], true);
    let lines: Vec<String> = seen.lock().unwrap().iter().map(|s| s.line.clone()).collect();
    assert!(
        !lines.iter().any(|l| l.contains(IDLE)),
        "a hand with nothing waiting is not read: {lines:?}"
    );
}

#[tokio::test]
async fn signed_out_reads_nothing() {
    let (api, seen) = owner(hands_owner);
    let mut app = App::new(None);
    app.start(&api);
    let reply = app.call("refresh", json!({})).await;
    assert_eq!(reply["error"]["kind"], "not_signed_in");
    assert!(seen.lock().unwrap().is_empty());
    let mut stopped = App::new(Some("tok"));
    assert_eq!(stopped.call("refresh", json!({})).await["error"]["kind"], "not_signed_in");
}

#[tokio::test]
async fn allow_signs_the_apps_own_text_and_settles_the_request() {
    let (api, seen) = owner(hands_owner);
    let mut app = refreshed(&api).await;
    let text = app.call("allow_text", json!({"key": key(), "environment": "prod"})).await;
    assert_eq!(text["value"]["text"], format!("cmux-hand-approval:prod:{HAND}:{ID}:allow"));
    let reply = app
        .call(
            "answer",
            json!({"key": key(), "allow": true, "install": "ins_1", "signature": "sig"}),
        )
        .await;
    assert_eq!(reply["ok"], true);
    let settled = app.next("settled").await;
    assert_eq!(settled["outcome"], "allowed");
    let posted =
        seen.lock().unwrap().iter().find(|s| s.line.starts_with("POST ")).cloned().unwrap();
    assert_eq!(posted.body, json!({"allow": true, "install": "ins_1", "signature": "sig"}));
    assert_eq!(
        app.call("answer", json!({"key": key(), "allow": false})).await["error"]["kind"],
        "unknown_approval"
    );
}

#[tokio::test]
async fn an_answer_the_server_already_has_ends_the_banner_too() {
    let (api, _) = owner(|seen| {
        if seen.line.starts_with("POST ") {
            refused(409, "hand.approval_answered")
        } else {
            hands_owner(seen)
        }
    });
    let mut app = refreshed(&api).await;
    let reply = app.call("answer", json!({"key": key(), "allow": false})).await;
    assert_eq!(reply["value"]["already"], true);
    assert_eq!(app.next("settled").await["outcome"], Value::Null);
}

#[tokio::test]
async fn a_failed_answer_keeps_the_request() {
    let (api, _) = owner(|seen| {
        if seen.line.starts_with("POST ") { refused(500, "oops") } else { hands_owner(seen) }
    });
    let mut app = refreshed(&api).await;
    let reply = app.call("answer", json!({"key": key(), "allow": false})).await;
    assert_eq!(
        (reply["error"]["kind"].clone(), reply["error"]["status"].clone()),
        (json!("http"), json!(500))
    );
    assert_eq!(
        app.call("allow_text", json!({"key": key(), "environment": "e"})).await["ok"],
        true,
        "still waiting"
    );
}

#[tokio::test]
async fn a_raise_asks_for_the_proof_without_a_call_and_a_lower_is_sent() {
    let (api, seen) = owner(hands_owner);
    let mut app = refreshed(&api).await;
    seen.lock().unwrap().clear();
    let raise =
        app.call("set_level", json!({"target": HAND, "level": "full", "known": "ask"})).await;
    assert_eq!(raise["value"]["needs_proof"], true);
    assert!(seen.lock().unwrap().is_empty());
    let lower =
        app.call("set_level", json!({"target": HAND, "level": "read-only", "known": "ask"})).await;
    assert_eq!(lower["value"], json!({}));
    let put = seen.lock().unwrap()[0].clone();
    assert!(put.line.starts_with(&format!("PUT /v1/hands/{HAND}/level ")));
    assert_eq!(put.body, json!({"level": "read-only"}));
    let bad = app.call("set_level", json!({"target": "../x", "level": "full"})).await;
    assert_eq!(bad["error"]["kind"], "invalid");
}

#[tokio::test]
async fn a_stale_lower_or_a_default_raise_becomes_a_raise() {
    let (api, _) = owner(|seen| {
        if seen.line.starts_with("PUT ") && seen.body.get("nonce").is_none() {
            refused(403, "hand.level_refused")
        } else {
            hands_owner(seen)
        }
    });
    let mut app = refreshed(&api).await;
    let stale =
        app.call("set_level", json!({"target": HAND, "level": "ask", "known": "full"})).await;
    assert_eq!(stale["value"]["needs_proof"], true);
    let default =
        app.call("set_level", json!({"target": "default:sandbox", "level": "full"})).await;
    assert_eq!(default["value"]["needs_proof"], true);
    let proof = json!({"install": "ins_1", "nonce": NONCE, "signature": "sig"});
    let proved = app
        .call("set_level", json!({"target": "default:sandbox", "level": "full", "proof": proof}))
        .await;
    assert_eq!(proved["ok"], true);
}

#[tokio::test]
async fn a_challenge_answers_the_nonce_and_the_text_to_sign() {
    let (api, seen) = owner(hands_owner);
    let mut app = refreshed(&api).await;
    let reply = app
        .call("challenge", json!({"target": "default:mac", "level": "auto", "environment": "prod"}))
        .await;
    assert_eq!(reply["value"]["text"], format!("cmux-hand-level:prod:default:mac:auto:{NONCE}"));
    assert!(
        seen.lock()
            .unwrap()
            .iter()
            .any(|s| s.line.starts_with("POST /v1/hands/defaults/mac/challenge "))
    );
    let (api, _) = owner(|seen| {
        if seen.line.contains("challenge") {
            ok(json!({"nonce": "xyz"}))
        } else {
            hands_owner(seen)
        }
    });
    let mut app = refreshed(&api).await;
    let reply = app
        .call("challenge", json!({"target": HAND, "level": "full", "environment": "prod"}))
        .await;
    assert_eq!(reply["error"]["kind"], "decoding");
}

#[tokio::test]
async fn the_presence_key_registers_as_a_jwk() {
    let (api, seen) = owner(hands_owner);
    let mut app = refreshed(&api).await;
    let text = app
        .call(
            "presence_text",
            json!({"environment": "prod", "install": "ins_1", "x": "X", "y": "Y"}),
        )
        .await;
    assert_eq!(text["value"]["text"], "cmux-hand-presence-key:prod:ins_1:X:Y");
    let reply = app
        .call(
            "register_presence_key",
            json!({"install": "ins_1", "x": "X", "y": "Y", "signature": "sig"}),
        )
        .await;
    assert_eq!(reply["ok"], true);
    let put = seen
        .lock()
        .unwrap()
        .iter()
        .find(|s| s.line.starts_with("PUT /v1/hands/presence-key "))
        .cloned()
        .unwrap();
    assert_eq!(put.body["public_jwk"], json!({"kty": "EC", "crv": "P-256", "x": "X", "y": "Y"}));
}

#[tokio::test]
async fn stopping_settles_every_request_and_the_report_shows_the_state() {
    let (api, _) = owner(hands_owner);
    let mut app = refreshed(&api).await;
    let report = app
        .call(
            "report",
            json!({"prompt": null, "secure_enclave": true, "result": "ok", "log": ["a"]}),
        )
        .await;
    let text = report["value"]["text"].as_str().unwrap().to_owned();
    let parsed: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(parsed["pending"][0]["key"], key());
    assert_eq!(parsed["hands"][1]["level"], Value::Null);
    assert_eq!(parsed["secure_enclave"], true);
    assert!(text.find("\"hands\"").unwrap() < text.find("\"pending\"").unwrap(), "keys sorted");
    app.send(json!({"t": "stop"}));
    assert_eq!(app.next("settled").await["outcome"], Value::Null);
    assert_eq!(app.next("hands").await["hands"], json!([]));
}
