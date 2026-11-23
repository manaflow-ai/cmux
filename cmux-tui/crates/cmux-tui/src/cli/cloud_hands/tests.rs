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
    /// The bearer the request carried.
    bearer: String,
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
            let bearer = head
                .lines()
                .find_map(|l| {
                    l.to_ascii_lowercase().strip_prefix("authorization: bearer ").map(str::to_owned)
                })
                .unwrap_or_default();
            let request =
                Seen { line, bearer, body: serde_json::from_slice(&body).unwrap_or(Value::Null) };
            // Logged before the answer, so a slow answer shows as already asked.
            if !request.line.contains("/v1/wire/user") {
                log.lock().unwrap().push(request.clone());
            }
            let (status, reply) = handler(&request);
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
    /// Each token answer adds its count (`tok-1`, `tok-2`, ...), as a session that rotates.
    rotating: bool,
    answered: u64,
    next: u64,
    /// Events read while waiting for another one, in order.
    backlog: Vec<Value>,
}

impl App {
    fn new(credential: Option<&'static str>) -> Self {
        // `run_if_requested` installs ring before it serves; these tests call `serve` directly, and
        // under nextest each test is its own process, so no other test has installed it either.
        let _ = rustls::crypto::ring::default_provider().install_default();
        let (input, lines) = mpsc::unbounded_channel();
        let (sender, events) = mpsc::unbounded_channel();
        tokio::spawn(serve(lines, move |event: Value| {
            let _ = sender.send(event);
        }));
        Self {
            input,
            events,
            credential,
            rotating: false,
            answered: 0,
            next: 0,
            backlog: Vec::new(),
        }
    }

    fn token(&mut self) -> Option<String> {
        self.answered += 1;
        let base = self.credential?;
        Some(if self.rotating { format!("{base}-{}", self.answered) } else { base.to_owned() })
    }

    fn send(&self, command: Value) {
        self.input.send(command.to_string()).unwrap();
    }

    fn start(&self, api: &str) {
        self.send(json!({"t": "start", "api": api, "app_version": "1.0"}));
    }

    /// The next event named `kind` (answering token asks on the way); others wait in the backlog.
    async fn next(&mut self, kind: &str) -> Value {
        if let Some(index) = self.backlog.iter().position(|event| event["event"] == kind) {
            return self.backlog.remove(index);
        }
        let wait = async {
            loop {
                let event = self.events.recv().await.expect("engine ended");
                if event["event"] == "token" {
                    let credential = self.token();
                    self.send(json!({"t": "token", "id": event["id"], "credential": credential}));
                    continue;
                }
                if event["event"] == kind {
                    return event;
                }
                self.backlog.push(event);
            }
        };
        // timeout: test-only bound; a missing event fails the test instead of hanging it.
        tokio::time::timeout(std::time::Duration::from_secs(10), wait).await.expect(kind)
    }

    /// Sends one call; its id.
    fn ask(&mut self, op: &str, params: Value) -> u64 {
        self.next += 1;
        let mut command = json!({"t": "call", "id": self.next, "op": op});
        for (key, value) in params.as_object().unwrap() {
            command[key] = value.clone();
        }
        self.send(command);
        self.next
    }

    /// The reply to call `id` (other replies wait in the backlog).
    async fn reply(&mut self, id: u64) -> Value {
        let mut other = Vec::new();
        let reply = loop {
            let reply = self.next("reply").await;
            if reply["id"] == id {
                break reply;
            }
            other.push(reply);
        };
        self.backlog.extend(other);
        reply
    }

    async fn call(&mut self, op: &str, params: Value) -> Value {
        let id = self.ask(op, params);
        self.reply(id).await
    }

    /// Every event that comes within `wait` (token asks answered).
    async fn drain(&mut self, wait: std::time::Duration) -> Vec<Value> {
        let mut seen = std::mem::take(&mut self.backlog);
        let deadline = tokio::time::Instant::now() + wait;
        while let Ok(Some(event)) = tokio::time::timeout_at(deadline, self.events.recv()).await {
            if event["event"] == "token" {
                let credential = self.token();
                self.send(json!({"t": "token", "id": event["id"], "credential": credential}));
                continue;
            }
            seen.push(event);
        }
        seen
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
    app.backlog.clear();
    app.send(json!({"t": "stop"}));
    assert_eq!(app.next("settled").await["outcome"], Value::Null);
    assert_eq!(app.next("hands").await["hands"], json!([]));
}

#[tokio::test]
async fn each_route_call_of_a_read_takes_a_fresh_token() {
    let (api, seen) = owner(hands_owner);
    let mut app = App::new(Some("tok"));
    app.rotating = true;
    app.start(&api);
    assert_eq!(app.call("refresh", json!({})).await["ok"], true);
    let seen = seen.lock().unwrap();
    let list = seen.iter().find(|s| s.line.starts_with("GET /v1/hands ")).unwrap();
    let waiting = seen.iter().find(|s| s.line.contains("/approvals ")).unwrap();
    assert!(list.bearer.starts_with("tok-") && waiting.bearer.starts_with("tok-"));
    assert_ne!(list.bearer, waiting.bearer, "the approvals read asked for its own token");
}

/// The usual owner, but an answer takes a while.
fn slow_answers(seen: &Seen) -> (u16, String) {
    if seen.line.starts_with("POST ") && seen.line.contains("/approvals/") {
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    hands_owner(seen)
}

/// Answers the call's token ask, so its request is at the owner when this returns.
async fn in_flight(app: &mut App, seen: &Arc<Mutex<Vec<Seen>>>) {
    let early = app.drain(std::time::Duration::from_millis(150)).await;
    app.backlog.extend(early);
    assert!(
        seen.lock().unwrap().iter().any(|s| s.line.starts_with("POST ")),
        "the answer reached the owner"
    );
}

#[tokio::test]
async fn a_call_started_before_stop_never_settles_after_it() {
    let (api, seen) = owner(slow_answers);
    let mut app = refreshed(&api).await;
    let id = app.ask("answer", json!({"key": key(), "allow": false}));
    in_flight(&mut app, &seen).await;
    app.send(json!({"t": "stop"}));
    let reply = app.reply(id).await;
    assert_eq!(reply["error"]["kind"], "not_signed_in", "{reply}");
    let after = app.drain(std::time::Duration::from_millis(900)).await;
    assert!(
        !after.iter().any(|e| e["event"] == "settled" && e["outcome"] == "denied"),
        "the old call settled into the stopped session: {after:?}"
    );
    assert!(!after.iter().any(|e| e["event"] == "reply" && e["id"] == id), "answered once");
}

#[tokio::test]
async fn an_old_starts_call_is_ignored_after_a_restart() {
    let (api, seen) = owner(slow_answers);
    let mut app = refreshed(&api).await;
    let id = app.ask("answer", json!({"key": key(), "allow": false}));
    in_flight(&mut app, &seen).await;
    app.start(&api);
    assert_eq!(app.reply(id).await["error"]["kind"], "not_signed_in");
    assert_eq!(app.call("refresh", json!({})).await["ok"], true);
    let after = app.drain(std::time::Duration::from_millis(900)).await;
    assert!(!after.iter().any(|e| e["event"] == "settled"), "nothing settles: {after:?}");
    let text = app.call("allow_text", json!({"key": key(), "environment": "e"})).await;
    assert_eq!(text["ok"], true, "the request still waits: {text}");
}

#[tokio::test]
async fn a_hand_whose_read_fails_keeps_the_requests_of_the_hands_read_before_it() {
    let (api, _) = owner(|seen| {
        if seen.line.starts_with("GET /v1/hands ") {
            ok(json!([
                {"hand": HAND, "name": "Build box", "pending_approvals": 1},
                {"hand": IDLE, "name": "Other", "pending_approvals": 1},
            ]))
        } else if seen.line.starts_with(&format!("GET /v1/hands/{IDLE}/approvals ")) {
            refused(500, "internal")
        } else {
            hands_owner(seen)
        }
    });
    let mut app = App::new(Some("tok"));
    app.start(&api);
    let reply = app.call("refresh", json!({})).await;
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(app.next("pending").await["approval"]["key"], key());
    let text = app.call("allow_text", json!({"key": key(), "environment": "e"})).await;
    assert_eq!(text["ok"], true, "{text}");
}

/// The usual owner, but the hands list takes a while.
fn slow_lists(seen: &Seen) -> (u16, String) {
    if seen.line.starts_with("GET /v1/hands ") {
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    hands_owner(seen)
}

#[tokio::test]
async fn a_refresh_running_when_a_new_start_begins_answers_that_its_session_ended() {
    let (api, seen) = owner(slow_lists);
    let mut app = App::new(Some("tok"));
    app.start(&api);
    let id = app.ask("refresh", json!({}));
    let early = app.drain(std::time::Duration::from_millis(150)).await;
    app.backlog.extend(early);
    assert!(seen.lock().unwrap().iter().any(|s| s.line.starts_with("GET /v1/hands ")));
    app.start(&api);
    let reply = app.reply(id).await;
    assert_eq!(reply["error"]["kind"], "not_signed_in", "{reply}");
    let after = app.drain(std::time::Duration::from_millis(900)).await;
    assert!(
        !after.iter().any(|e| e["event"] == "reply" && e["id"] == id),
        "answered once, never by the new start: {after:?}"
    );
}
