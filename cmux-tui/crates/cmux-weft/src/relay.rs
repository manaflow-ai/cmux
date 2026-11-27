//! The relay (`weft-relay`): DERP-shaped, over WebSocket.
//!
//! A client opens `GET /v1/relay` (WebSocket), sends its relay ticket as the
//! first text message, then exchanges binary [`crate::relay_frame`]s. The
//! relay forwards a frame only to a client of the same tailnet, stamps the
//! sender's ticket key on it (never the client's claim), and closes the
//! connection when the ticket expires. It never sees plaintext: the payload
//! is a WireGuard datagram.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Router;
use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::response::IntoResponse;
use axum::routing::get;
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc;

use crate::relay_frame;

/// Frames queued toward one client before new ones are dropped (UDP-like:
/// WireGuard and TCP inside it recover from loss, not from head-of-line
/// blocking).
const QUEUE: usize = 1024;
/// The first message must arrive this soon.
const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
/// Token bucket per connection: sustained frames per second and burst.
const FRAMES_PER_SECOND: f64 = 20_000.0;
const BURST: f64 = 40_000.0;
const MAX_CLIENTS: usize = 50_000;

pub struct RelayConfig {
    /// The coordinator's ticket authority (Ed25519 public key).
    pub ticket_public_key: [u8; 32],
    /// This relay's region, reported by `/healthz`.
    pub region: String,
}

type ClientKey = (String, [u8; 32]);

struct Client {
    connection: u64,
    sender: mpsc::Sender<Vec<u8>>,
}

struct Inner {
    authority: [u8; 32],
    region: String,
    clients: Mutex<HashMap<ClientKey, Client>>,
    next_connection: AtomicU64,
    forwarded: AtomicU64,
    dropped: AtomicU64,
    connected: AtomicUsize,
}

/// Build the relay router.
pub fn router(config: RelayConfig) -> Router {
    let inner = Arc::new(Inner {
        authority: config.ticket_public_key,
        region: config.region,
        clients: Mutex::new(HashMap::new()),
        next_connection: AtomicU64::new(1),
        forwarded: AtomicU64::new(0),
        dropped: AtomicU64::new(0),
        connected: AtomicUsize::new(0),
    });
    Router::new()
        .route("/healthz", get(health))
        .route("/healthz/{region}", get(health_in))
        .route("/v1/relay", get(upgrade))
        .route("/v1/relay/{region}", get(upgrade_in))
        .with_state(inner)
}

/// On Fly.io, ask the proxy to replay a request meant for another region
/// there (`fly-replay`). One relay app then serves every region under one
/// hostname, and `/v1/relay/<region>` always lands on that region's relay,
/// so two clients that use the same URL meet on the same machine.
fn replay_elsewhere(state: &Inner, region: &str) -> Option<axum::response::Response> {
    if region == state.region || std::env::var_os("FLY_APP_NAME").is_none() {
        return None;
    }
    if !(region.len() <= 8
        && region.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit()))
    {
        return Some(axum::http::StatusCode::NOT_FOUND.into_response());
    }
    let mut response = axum::http::StatusCode::CONFLICT.into_response();
    if let Ok(value) = axum::http::HeaderValue::from_str(&format!("region={region}")) {
        response.headers_mut().insert("fly-replay", value);
    }
    Some(response)
}

async fn health_in(
    State(state): State<Arc<Inner>>,
    axum::extract::Path(region): axum::extract::Path<String>,
) -> axum::response::Response {
    match replay_elsewhere(&state, &region) {
        Some(response) => response,
        None => health(State(state)).await.into_response(),
    }
}

async fn upgrade_in(
    State(state): State<Arc<Inner>>,
    axum::extract::Path(region): axum::extract::Path<String>,
    upgrade: WebSocketUpgrade,
) -> axum::response::Response {
    match replay_elsewhere(&state, &region) {
        Some(response) => response,
        None => upgrade
            .max_message_size(64 * 1024)
            .on_upgrade(move |socket| handle(state, socket))
            .into_response(),
    }
}

/// Serve the relay on `listener`.
pub async fn serve_relay(listener: TcpListener, config: RelayConfig) -> anyhow::Result<()> {
    axum::serve(listener, router(config)).await?;
    Ok(())
}

async fn health(State(state): State<Arc<Inner>>) -> impl IntoResponse {
    axum::Json(serde_json::json!({
        "ok": true,
        "region": state.region,
        "clients": state.connected.load(Ordering::Relaxed),
        "forwarded": state.forwarded.load(Ordering::Relaxed),
        "dropped": state.dropped.load(Ordering::Relaxed),
    }))
}

async fn upgrade(State(state): State<Arc<Inner>>, upgrade: WebSocketUpgrade) -> impl IntoResponse {
    upgrade.max_message_size(64 * 1024).on_upgrade(move |socket| handle(state, socket))
}

struct Bucket {
    tokens: f64,
    at: tokio::time::Instant,
}

impl Bucket {
    fn take(&mut self) -> bool {
        let now = tokio::time::Instant::now();
        let elapsed = now.duration_since(self.at).as_secs_f64();
        self.at = now;
        self.tokens = (self.tokens + elapsed * FRAMES_PER_SECOND).min(BURST);
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

async fn handle(state: Arc<Inner>, socket: WebSocket) {
    let (mut sink, mut stream) = socket.split();
    let hello = tokio::time::timeout(HELLO_TIMEOUT, stream.next()).await;
    let Ok(Some(Ok(Message::Text(text)))) = hello else { return };
    let now = crate::now_ms();
    let ticket = match crate::ticket::verify(&state.authority, text.as_str(), now) {
        Ok(ticket) => ticket,
        Err(error) => {
            let _ = sink.send(Message::Text(format!("error: {error}").into())).await;
            return;
        }
    };
    let key: ClientKey = (ticket.tailnet.clone(), ticket.node_key);
    let connection = state.next_connection.fetch_add(1, Ordering::Relaxed);
    let (sender, mut receiver) = mpsc::channel::<Vec<u8>>(QUEUE);
    {
        let Ok(mut clients) = state.clients.lock() else { return };
        if clients.len() >= MAX_CLIENTS && !clients.contains_key(&key) {
            return;
        }
        // A newer connection for the same key replaces the old one (a client
        // that reconnected); the old one's queue closes and its task ends.
        clients.insert(key.clone(), Client { connection, sender });
    }
    state.connected.fetch_add(1, Ordering::Relaxed);
    if sink.send(Message::Text("ok".into())).await.is_err() {
        unregister(&state, &key, connection);
        return;
    }

    let remaining = Duration::from_millis(ticket.expires_ms.saturating_sub(now));
    let expiry = tokio::time::sleep(remaining);
    tokio::pin!(expiry);
    let mut bucket = Bucket { tokens: BURST, at: tokio::time::Instant::now() };
    loop {
        tokio::select! {
            () = &mut expiry => break,
            outbound = receiver.recv() => {
                let Some(frame) = outbound else { break };
                if sink.send(Message::Binary(frame.into())).await.is_err() {
                    break;
                }
            }
            inbound = stream.next() => {
                match inbound {
                    Some(Ok(Message::Binary(frame))) => {
                        if !bucket.take() {
                            state.dropped.fetch_add(1, Ordering::Relaxed);
                            continue;
                        }
                        forward(&state, &key, &frame);
                    }
                    Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
                    Some(Ok(Message::Text(_))) | Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                }
            }
        }
    }
    unregister(&state, &key, connection);
    let _ = sink.close().await;
}

fn forward(state: &Inner, from: &ClientKey, frame: &[u8]) {
    let Some((destination, datagram)) = relay_frame::decode(frame) else {
        state.dropped.fetch_add(1, Ordering::Relaxed);
        return;
    };
    let target = (from.0.clone(), destination);
    let sender = match state.clients.lock() {
        Ok(clients) => clients.get(&target).map(|client| client.sender.clone()),
        Err(_) => None,
    };
    let Some(sender) = sender else {
        state.dropped.fetch_add(1, Ordering::Relaxed);
        return;
    };
    match sender.try_send(relay_frame::encode(&from.1, datagram)) {
        Ok(()) => {
            state.forwarded.fetch_add(1, Ordering::Relaxed);
        }
        Err(_) => {
            state.dropped.fetch_add(1, Ordering::Relaxed);
        }
    }
}

fn unregister(state: &Inner, key: &ClientKey, connection: u64) {
    if let Ok(mut clients) = state.clients.lock()
        && clients.get(key).is_some_and(|client| client.connection == connection)
    {
        clients.remove(key);
    }
    state.connected.fetch_sub(1, Ordering::Relaxed);
}
