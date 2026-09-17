//! A peer is a remote acpmux daemon. This daemon is an ACP client of it:
//! it watches the peer's sessions, forwards requests for them, and relays
//! the peer's notifications to local clients. Reconnects with backoff.

use crate::rpc::{Message, RpcError, method};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

/// What the hub receives from a peer.
#[derive(Debug)]
pub enum PeerNotice {
    Connected,
    Disconnected(String),
    /// Full session list from `_acpmux/watch` or a single `session_changed`.
    Sessions(Vec<Value>),
    SessionChanged { session: Value, kind: String, seq: u64 },
    Notification { method: String, params: Value },
}

pub struct Peer {
    pub name: String,
    pub url: String,
    token: Option<String>,
    /// For `ssh://host[:port]` peers: the local port the tunnel binds.
    tunnel_port: Option<u16>,
    tunnel: Mutex<Option<tokio::process::Child>>,
    out: mpsc::Sender<String>,
    out_rx: Mutex<Option<mpsc::Receiver<String>>>,
    next_id: AtomicI64,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, RpcError>>>>>,
    pub connected: AtomicBool,
    pub last_error: StdMutex<Option<String>>,
    attached: StdMutex<HashSet<String>>,
    notices: mpsc::Sender<(String, PeerNotice)>,
    stop: AtomicBool,
}

impl Peer {
    pub fn new(name: &str, url: &str, token: Option<String>, notices: mpsc::Sender<(String, PeerNotice)>) -> Arc<Self> {
        let (out, out_rx) = mpsc::channel(1024);
        let tunnel_port = url.starts_with("ssh://").then(|| {
            // Stable local port derived from the peer name, in 48000..48999.
            let mut h: u32 = 2166136261;
            for b in name.bytes() {
                h ^= b as u32;
                h = h.wrapping_mul(16777619);
            }
            48000 + (h % 1000) as u16
        });
        Arc::new(Self {
            name: name.to_owned(),
            url: url.to_owned(),
            token,
            tunnel_port,
            tunnel: Mutex::new(None),
            out,
            out_rx: Mutex::new(Some(out_rx)),
            next_id: AtomicI64::new(1),
            pending: Arc::new(Mutex::new(HashMap::new())),
            connected: AtomicBool::new(false),
            last_error: StdMutex::new(None),
            attached: StdMutex::new(HashSet::new()),
            notices,
            stop: AtomicBool::new(false),
        })
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Ok(mut t) = self.tunnel.try_lock() {
            if let Some(child) = t.as_mut() {
                let _ = child.start_kill();
            }
            *t = None;
        }
    }

    /// `ssh://user@host[:port]` -> (ssh target, remote port).
    fn ssh_parts(&self) -> Option<(String, u16)> {
        let rest = self.url.strip_prefix("ssh://")?;
        let (host, port) = match rest.rsplit_once(':') {
            Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) && !p.is_empty() => (h.to_owned(), p.parse().unwrap_or(47811)),
            _ => (rest.to_owned(), 47811),
        };
        Some((host, port))
    }

    /// Open (or reopen) the SSH tunnel and, if no token is configured, read
    /// the remote daemon's token from its config over the same SSH access.
    async fn ensure_tunnel(&self) -> Result<String, String> {
        let (host, remote_port) = self.ssh_parts().ok_or_else(|| "not an ssh peer".to_owned())?;
        let local = self.tunnel_port.ok_or_else(|| "no tunnel port".to_owned())?;
        let mut guard = self.tunnel.lock().await;
        let alive = guard.as_mut().map(|c| matches!(c.try_wait(), Ok(None))).unwrap_or(false);
        if !alive {
            let child = tokio::process::Command::new("ssh")
                .args([
                    "-N",
                    "-o", "BatchMode=yes",
                    "-o", "ExitOnForwardFailure=yes",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3",
                    "-o", "ConnectTimeout=10",
                    "-L", &format!("127.0.0.1:{local}:127.0.0.1:{remote_port}"),
                    &host,
                ])
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::piped())
                .kill_on_drop(true)
                .spawn()
                .map_err(|e| format!("spawn ssh: {e}"))?;
            *guard = Some(child);
            // Wait for the forward to accept connections.
            let mut ok = false;
            for _ in 0..40 {
                tokio::time::sleep(Duration::from_millis(250)).await;
                if tokio::net::TcpStream::connect(("127.0.0.1", local)).await.is_ok() {
                    ok = true;
                    break;
                }
                if let Some(c) = guard.as_mut() {
                    if let Ok(Some(status)) = c.try_wait() {
                        return Err(format!("ssh tunnel to {host} exited: {status}"));
                    }
                }
            }
            if !ok {
                return Err(format!("ssh tunnel to {host} did not come up on port {local}"));
            }
        }
        drop(guard);
        if let Some(t) = &self.token {
            return Ok(t.clone());
        }
        // Read the remote token once over ssh.
        let out = tokio::process::Command::new("ssh")
            .args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", &host, "cat ~/.acpmux/config.json"])
            .output()
            .await
            .map_err(|e| format!("read remote config: {e}"))?;
        let cfg: Value = serde_json::from_slice(&out.stdout).map_err(|_| format!("remote {host} has no readable ~/.acpmux/config.json"))?;
        cfg.pointer("/websocket/token")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| format!("remote {host} config has no websocket token"))
    }

    pub fn summary(&self) -> Value {
        json!({
            "name": self.name,
            "url": self.url,
            "connected": self.connected.load(Ordering::SeqCst),
            "error": self.last_error.lock().unwrap().clone(),
        })
    }

    /// Remember that local clients want this session's stream, so it is
    /// re-attached after a reconnect.
    pub fn mark_attached(&self, session_id: &str) -> bool {
        self.attached.lock().unwrap().insert(session_id.to_owned())
    }

    pub async fn request(&self, m: &str, params: Value) -> Result<Value, RpcError> {
        if !self.connected.load(Ordering::SeqCst) {
            return Err(RpcError::internal(format!("peer {} is not connected", self.name)));
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(Value::from(id).to_string(), tx);
        if self.out.send(Message::request(id, m, params).to_line()).await.is_err() {
            return Err(RpcError::internal(format!("peer {} connection closed", self.name)));
        }
        match tokio::time::timeout(Duration::from_secs(600), rx).await {
            Ok(Ok(r)) => r,
            Ok(Err(_)) => Err(RpcError::internal(format!("peer {} dropped the request", self.name))),
            Err(_) => Err(RpcError::internal(format!("peer {} timed out", self.name))),
        }
    }

    pub async fn notify(&self, m: &str, params: Value) -> Result<(), RpcError> {
        self.out
            .send(Message::notification(m, params).to_line())
            .await
            .map_err(|_| RpcError::internal(format!("peer {} connection closed", self.name)))
    }

    /// Run the connect loop until `stop`.
    pub async fn run(self: Arc<Self>) {
        let mut backoff = 1u64;
        let mut out_rx = self.out_rx.lock().await.take().expect("peer run called twice");
        while !self.stop.load(Ordering::SeqCst) {
            match self.connect_once(&mut out_rx).await {
                Ok(()) => backoff = 1,
                Err(e) => {
                    *self.last_error.lock().unwrap() = Some(e.clone());
                    let _ = self.notices.send((self.name.clone(), PeerNotice::Disconnected(e))).await;
                }
            }
            self.connected.store(false, Ordering::SeqCst);
            let mut p = self.pending.lock().await;
            for (_, tx) in p.drain() {
                let _ = tx.send(Err(RpcError::internal("peer disconnected")));
            }
            drop(p);
            if self.stop.load(Ordering::SeqCst) {
                break;
            }
            tokio::time::sleep(Duration::from_secs(backoff)).await;
            backoff = (backoff * 2).min(30);
        }
    }

    async fn connect_once(self: &Arc<Self>, out_rx: &mut mpsc::Receiver<String>) -> Result<(), String> {
        let (ws_url, token) = if let Some(local) = self.tunnel_port {
            let token = self.ensure_tunnel().await?;
            (format!("ws://127.0.0.1:{local}"), Some(token))
        } else {
            (self.url.clone(), self.token.clone())
        };
        let mut req = ws_url.as_str().into_client_request().map_err(|e| e.to_string())?;
        if let Some(t) = &token {
            req.headers_mut().insert(
                "authorization",
                format!("Bearer {t}").parse().map_err(|_| "bad token".to_owned())?,
            );
        }
        let (ws, _) = tokio::time::timeout(Duration::from_secs(10), tokio_tungstenite::connect_async(req))
            .await
            .map_err(|_| "connect timed out".to_owned())?
            .map_err(|e| e.to_string())?;
        let (mut sink, mut source) = ws.split();
        self.connected.store(true, Ordering::SeqCst);
        *self.last_error.lock().unwrap() = None;
        tracing::info!(peer = %self.name, "connected to {}", self.url);

        // Handshake in a task so the read loop below can serve the responses.
        let me = self.clone();
        let handshake = tokio::spawn(async move {
            me.request(
                method::INITIALIZE,
                json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "acpmux-peer", "version": crate::hub::VERSION}}),
            )
            .await?;
            let watch = me.request(method::MUX_WATCH, json!({"enabled": true})).await?;
            let sessions = watch.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
            let _ = me.notices.send((me.name.clone(), PeerNotice::Sessions(sessions))).await;
            let _ = me.notices.send((me.name.clone(), PeerNotice::Connected)).await;
            let attached: Vec<String> = me.attached.lock().unwrap().iter().cloned().collect();
            for sid in attached {
                let _ = me.request(method::MUX_ATTACH, json!({"sessionId": sid, "limit": 0})).await;
            }
            Ok::<(), RpcError>(())
        });

        let result = loop {
            tokio::select! {
                frame = source.next() => {
                    let Some(frame) = frame else { break Err("peer closed the connection".to_owned()) };
                    let frame = match frame { Ok(f) => f, Err(e) => break Err(e.to_string()) };
                    let text = match frame {
                        tokio_tungstenite::tungstenite::Message::Text(t) => t.to_string(),
                        tokio_tungstenite::tungstenite::Message::Close(_) => break Err("peer closed the connection".to_owned()),
                        _ => continue,
                    };
                    let Ok(msg) = Message::parse(&text) else { continue };
                    match msg {
                        Message::Response { id, result, error } => {
                            if let Some(tx) = self.pending.lock().await.remove(&id.to_string()) {
                                let _ = tx.send(match error { Some(e) => Err(e), None => Ok(result.unwrap_or(Value::Null)) });
                            }
                        }
                        Message::Notification { method: m, params } => {
                            let p = params.unwrap_or(Value::Null);
                            let notice = if m == method::MUX_SESSION_CHANGED {
                                PeerNotice::SessionChanged {
                                    session: p.get("session").cloned().unwrap_or(Value::Null),
                                    kind: p.get("kind").and_then(Value::as_str).unwrap_or("").to_owned(),
                                    seq: p.get("seq").and_then(Value::as_u64).unwrap_or(0),
                                }
                            } else {
                                PeerNotice::Notification { method: m, params: p }
                            };
                            if self.notices.send((self.name.clone(), notice)).await.is_err() {
                                break Ok(());
                            }
                        }
                        Message::Request { id, .. } => {
                            // acpmux does not send requests to clients today.
                            let _ = sink.send(tokio_tungstenite::tungstenite::Message::Text(
                                Message::err(id, RpcError::method_not_found("client-side request")).to_value().to_string().into(),
                            )).await;
                        }
                    }
                }
                line = out_rx.recv() => {
                    let Some(line) = line else { break Ok(()) };
                    let text = line.trim_end_matches('\n').to_owned();
                    if let Err(e) = sink.send(tokio_tungstenite::tungstenite::Message::Text(text.into())).await {
                        break Err(e.to_string());
                    }
                }
            }
        };
        handshake.abort();
        result
    }
}
