//! An in-process stand-in for the backend's signaling Durable Object, for
//! tests: same routes, same JSON, same relay frame rewrite, same admission
//! rule (a signal reaches a device of the sender's own user, or answers an
//! existing session). The bearer token is `user:<userId>`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

#[derive(Debug, Clone, Default)]
pub struct FakeOptions {
    /// Remove `endpoints` from wg-init and wg-resp, so WireGuard can only
    /// use the relay.
    pub strip_wg_endpoints: bool,
    /// Do not stamp `fromUserId` on forwarded signals.
    pub omit_from_user_id: bool,
}

struct Device {
    user: String,
    out: mpsc::UnboundedSender<Message>,
}

#[derive(Default)]
struct State {
    devices: HashMap<String, Device>,
    /// sessionId → the two devices in it.
    sessions: HashMap<String, (String, String)>,
    relayed_frames: u64,
}

pub struct FakeSignaling {
    pub base_url: String,
    state: Arc<Mutex<State>>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for FakeSignaling {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl FakeSignaling {
    pub async fn start(options: FakeOptions) -> Self {
        Self::start_on("127.0.0.1:0", options).await
    }

    /// Listen on `address` (for a fake backend reachable from another host).
    /// Besides the signaling WebSocket it answers `GET /v1/health`,
    /// `GET /v1/ice` (Cloudflare STUN only) and `POST /v1/devices`.
    pub async fn start_on(address: &str, options: FakeOptions) -> Self {
        let listener = TcpListener::bind(address).await.expect("bind");
        let base_url = format!("http://{}", listener.local_addr().expect("addr"));
        let state = Arc::new(Mutex::new(State::default()));
        let shared = Arc::clone(&state);
        let task = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                tokio::spawn(serve(stream, Arc::clone(&shared), options.clone()));
            }
        });
        Self { base_url, state, task }
    }

    /// Binary relay frames forwarded so far.
    pub fn relayed_frames(&self) -> u64 {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).relayed_frames
    }

    /// Drop every socket of `device` (simulates a signaling outage).
    pub fn kick(&self, device: &str) {
        let removed = self.state.lock().unwrap_or_else(PoisonError::into_inner).devices.remove(device);
        if let Some(device) = removed {
            let _ = device.out.send(Message::Close(None));
        }
    }
}

#[allow(clippy::result_large_err)] // tungstenite's handshake callback signature
async fn serve(stream: tokio::net::TcpStream, state: Arc<Mutex<State>>, options: FakeOptions) {
    let mut stream = stream;
    match peek_head(&stream).await {
        Some(head) if !head.to_ascii_lowercase().contains("upgrade: websocket") => {
            answer_http(&mut stream, &head).await;
            return;
        }
        Some(_) => {}
        None => return,
    }
    let mut identity = None;
    let callback = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        let user = request
            .headers()
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer user:"))
            .map(str::to_owned);
        let device = request
            .uri()
            .query()
            .and_then(|q| q.split('&').find_map(|kv| kv.strip_prefix("deviceId=")))
            .map(str::to_owned);
        let path_ok =
            request.uri().path().starts_with("/v1/teams/") && request.uri().path().ends_with("/signal");
        match (user, device, path_ok) {
            (Some(user), Some(device), true) => {
                identity = Some((user, device));
                Ok(response)
            }
            _ => {
                let mut refused = ErrorResponse::new(Some("unauthorized".into()));
                *refused.status_mut() = tokio_tungstenite::tungstenite::http::StatusCode::UNAUTHORIZED;
                Err(refused)
            }
        }
    };
    let Ok(socket) = tokio_tungstenite::accept_hdr_async(stream, callback).await else { return };
    let Some((user, device)) = identity else { return };
    let (mut sink, mut source) = socket.split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();
    tokio::spawn(async move {
        while let Some(message) = out_rx.recv().await {
            let close = matches!(message, Message::Close(_));
            if sink.send(message).await.is_err() || close {
                break;
            }
        }
        let _ = sink.close().await;
    });
    let _ = out_tx.send(Message::Text(json!({"type":"hello","you":device,"macs":[]}).to_string().into()));
    let replaced = state
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .devices
        .insert(device.clone(), Device { user: user.clone(), out: out_tx.clone() });
    // One live socket per device, as in the backend (team-hub.ts): a
    // reconnect closes the old socket with 4000 "replaced".
    if let Some(old) = replaced {
        let _ = old.out.send(Message::Close(Some(CloseFrame {
            code: CloseCode::Library(4000),
            reason: "replaced".into(),
        })));
    }
    while let Some(Ok(message)) = source.next().await {
        // A replaced socket is closing: the backend ignores what it still
        // sends (team-hub.ts `replaced`).
        let current = state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .devices
            .get(&device)
            .is_some_and(|d| d.out.same_channel(&out_tx));
        if !current {
            continue;
        }
        match message {
            Message::Text(text) => {
                let Ok(mut value) = serde_json::from_str::<Value>(&text) else { continue };
                if value["type"] != "signal" {
                    continue;
                }
                let to = value["to"].as_str().unwrap_or_default().to_owned();
                let session = value["sessionId"].as_str().unwrap_or_default().to_owned();
                value["from"] = Value::String(device.clone());
                if options.omit_from_user_id {
                    if let Some(object) = value.as_object_mut() {
                        object.remove("fromUserId");
                    }
                } else {
                    value["fromUserId"] = Value::String(user.clone());
                }
                if options.strip_wg_endpoints
                    && matches!(value["payload"]["kind"].as_str(), Some("wg-init" | "wg-resp"))
                {
                    value["payload"]["endpoints"] = json!([]);
                }
                let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
                let existing = state.sessions.get(&session).cloned();
                let admitted = match &existing {
                    Some((a, b)) => (a == &device && b == &to) || (b == &device && a == &to),
                    None => state.devices.get(&to).is_some_and(|target| target.user == user),
                };
                let target = state.devices.get(&to).map(|d| d.out.clone());
                match (admitted, target) {
                    (true, Some(target)) => {
                        if existing.is_none() {
                            state.sessions.insert(session, (device.clone(), to));
                        }
                        let _ = target.send(Message::Text(value.to_string().into()));
                    }
                    (true, None) => {
                        let _ = out_tx.send(Message::Text(
                            json!({"type":"error","code":"offline","message":"device is offline"})
                                .to_string()
                                .into(),
                        ));
                    }
                    (false, _) => {
                        let _ = out_tx.send(Message::Text(
                            json!({"type":"error","code":"not_owner","message":"not your device"})
                                .to_string()
                                .into(),
                        ));
                    }
                }
            }
            Message::Binary(bytes) => {
                if bytes.len() < 32 {
                    continue;
                }
                let session = uuid::Uuid::from_slice(&bytes[..16]).map(|u| u.to_string()).unwrap_or_default();
                let to = uuid::Uuid::from_slice(&bytes[16..32]).map(|u| u.to_string()).unwrap_or_default();
                let Ok(from) = uuid::Uuid::parse_str(&device) else { continue };
                let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
                let admitted = state
                    .sessions
                    .get(&session)
                    .is_some_and(|(a, b)| (a == &device && b == &to) || (b == &device && a == &to));
                if !admitted {
                    continue;
                }
                let mut rewritten = bytes.to_vec();
                rewritten[16..32].copy_from_slice(from.as_bytes());
                if let Some(target) = state.devices.get(&to) {
                    let _ = target.out.send(Message::Binary(rewritten.into()));
                    state.relayed_frames += 1;
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }
    let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
    if state.devices.get(&device).is_some_and(|d| d.out.same_channel(&out_tx)) {
        state.devices.remove(&device);
    }
}

/// The request head (through the blank line), without consuming it.
async fn peek_head(stream: &tokio::net::TcpStream) -> Option<String> {
    let mut buffer = vec![0u8; 8192];
    for _ in 0..200 {
        let read = stream.peek(&mut buffer).await.ok()?;
        if read == 0 {
            return None;
        }
        let text = String::from_utf8_lossy(&buffer[..read]);
        if let Some(end) = text.find("\r\n\r\n") {
            return Some(text[..end + 4].to_owned());
        }
        if read == buffer.len() {
            return None;
        }
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    None
}

async fn answer_http(stream: &mut tokio::net::TcpStream, head: &str) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let length = head
        .lines()
        .find_map(|line| {
            line.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().to_owned())
        })
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(0);
    let mut request = vec![0u8; head.len() + length.min(1 << 20)];
    if stream.read_exact(&mut request).await.is_err() {
        return;
    }
    let body: Value = serde_json::from_slice(&request[head.len()..]).unwrap_or(Value::Null);
    let line = head.lines().next().unwrap_or_default();
    let authorized = head.lines().any(|l| l.to_ascii_lowercase().starts_with("authorization: bearer user:"));
    let (status, reply) = if line.starts_with("GET /v1/health") {
        ("200 OK", json!({"ok": true, "version": "fake"}))
    } else if !authorized {
        ("401 Unauthorized", json!({"error": "unauthorized"}))
    } else if line.starts_with("GET /v1/ice") {
        ("200 OK", json!({"iceServers": [{"urls": ["stun:stun.cloudflare.com:3478"]}], "ttl": 3600}))
    } else if line.starts_with("POST /v1/devices") {
        ("200 OK", json!({"device": body}))
    } else {
        ("404 Not Found", json!({"error": "not_found"}))
    };
    let reply = reply.to_string();
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
        reply.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
}
