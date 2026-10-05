//! A peer is a remote acpmux daemon. This daemon is an ACP client of it:
//! it watches the peer's sessions, forwards requests for them, and relays
//! the peer's notifications to local clients. Reconnects with backoff.

use crate::rpc::{Message, RpcError, method};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::sync::{Mutex, Notify, mpsc, oneshot};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

/// Source of `Peer::generation`.
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

/// What the hub receives from a peer, tagged with the peer's name and
/// generation so notices from a replaced or removed peer can be dropped.
#[derive(Debug)]
pub enum PeerNotice {
    Connected,
    Disconnected(String),
    /// Full session list from `_acpmux/watch` or a single `session_changed`.
    Sessions(Vec<Value>),
    SessionChanged {
        session: Value,
        kind: String,
        seq: u64,
    },
    Notification {
        method: String,
        params: Value,
    },
}

pub struct Peer {
    pub name: String,
    /// Unique per `Peer` instance; a replacement under the same name gets a
    /// new one.
    pub generation: u64,
    pub url: String,
    token: Option<String>,
    /// The peer's peer token (`server/peer_auth.rs`), sent with `token`.
    peer_token: Option<String>,
    /// The `ssh -W` process carrying an `ssh://` peer's current connection.
    tunnel: Mutex<Option<tokio::process::Child>>,
    out: mpsc::Sender<String>,
    out_rx: Mutex<Option<mpsc::Receiver<String>>>,
    next_id: AtomicI64,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, RpcError>>>>>,
    pub connected: AtomicBool,
    pub last_error: StdMutex<Option<String>>,
    /// Version and build the peer reported at handshake.
    pub remote_version: StdMutex<Option<(String, String)>>,
    /// The origin the peer serves this daemon as (its initialize reply):
    /// `peer` when it accepted the peer token, `remote` (Web) otherwise.
    served_as: StdMutex<Option<String>>,
    attached: StdMutex<HashSet<String>>,
    notices: mpsc::Sender<(String, u64, PeerNotice)>,
    stop: AtomicBool,
    /// Wakes `serve` so `stop` closes the live connection.
    stop_signal: Notify,
    /// Counts connect attempts that settled (ready or failed), bumped by the
    /// hub once it applied the outcome, so a caller can await the next one.
    settled: tokio::sync::watch::Sender<u64>,
}

impl Peer {
    pub fn new(
        name: &str,
        url: &str,
        token: Option<String>,
        peer_token: Option<String>,
        notices: mpsc::Sender<(String, u64, PeerNotice)>,
    ) -> Arc<Self> {
        let (out, out_rx) = mpsc::channel(1024);
        Arc::new(Self {
            name: name.to_owned(),
            generation: NEXT_GENERATION.fetch_add(1, Ordering::SeqCst),
            url: url.to_owned(),
            token,
            peer_token,
            tunnel: Mutex::new(None),
            out,
            out_rx: Mutex::new(Some(out_rx)),
            next_id: AtomicI64::new(1),
            pending: Arc::new(Mutex::new(HashMap::new())),
            connected: AtomicBool::new(false),
            last_error: StdMutex::new(None),
            remote_version: StdMutex::new(None),
            served_as: StdMutex::new(None),
            attached: StdMutex::new(HashSet::new()),
            notices,
            stop: AtomicBool::new(false),
            stop_signal: Notify::new(),
            settled: tokio::sync::watch::channel(0).0,
        })
    }

    /// Receives every later settled connect attempt.
    pub fn settled(&self) -> tokio::sync::watch::Receiver<u64> {
        self.settled.subscribe()
    }

    /// The hub applied a connect outcome (sessions listed, or the error).
    pub fn mark_settled(&self) {
        self.settled.send_modify(|count| *count += 1);
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        // Stores a permit when `serve` is not waiting yet.
        self.stop_signal.notify_one();
        if let Ok(mut t) = self.tunnel.try_lock() {
            if let Some(child) = t.as_mut() {
                let _ = child.start_kill();
            }
            *t = None;
        }
    }

    /// `ssh://user@host[:port]` -> (ssh destination, remote port); None for
    /// any other scheme and for an ssh URL `ssh_target` refuses.
    fn ssh_parts(&self) -> Option<(String, u16)> {
        let t = ssh_target(&self.url).ok()?;
        Some((t.destination, t.port))
    }

    /// Open an `ssh -W` stdio channel to the peer's WebSocket port. The
    /// connection runs over ssh's stdin and stdout, so there is no local port
    /// to wait for: the WebSocket handshake itself says whether it works.
    async fn open_tunnel(
        &self,
    ) -> Result<
        (tokio::io::Join<tokio::process::ChildStdout, tokio::process::ChildStdin>, u16),
        String,
    > {
        let (host, remote_port) = self.ssh_parts().ok_or_else(|| "not an ssh peer".to_owned())?;
        let mut child = tokio::process::Command::new("ssh")
            .args(tunnel_argv(&host, remote_port))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("spawn ssh: {e}"))?;
        let stdout = child.stdout.take().ok_or_else(|| "ssh stdout".to_owned())?;
        let stdin = child.stdin.take().ok_or_else(|| "ssh stdin".to_owned())?;
        // Replacing the previous channel ends its ssh process.
        *self.tunnel.lock().await = Some(child);
        Ok((tokio::io::join(stdout, stdin), remote_port))
    }

    /// The dashboard token (configured, else the remote daemon's own) and
    /// the remote daemon's peer token of this launch (configured, else none
    /// when the remote has none: an older daemon serves this one as Web),
    /// read over the same ssh access at each connect.
    async fn remote_tokens(&self) -> Result<(String, Option<String>), String> {
        let (host, _) = self.ssh_parts().ok_or_else(|| "not an ssh peer".to_owned())?;
        if let (Some(t), Some(p)) = (&self.token, &self.peer_token) {
            return Ok((t.clone(), Some(p.clone())));
        }
        let out = tokio::process::Command::new("ssh")
            .args(read_config_argv(&host))
            .output()
            .await
            .map_err(|e| format!("read remote config: {e}"))?;
        let (config, peer) = split_remote_read(&out.stdout);
        let peer = self.peer_token.clone().or(peer);
        if let Some(t) = &self.token {
            return Ok((t.clone(), peer));
        }
        let cfg: Value = serde_json::from_slice(config)
            .map_err(|_| format!("remote {host} has no readable ~/.acpmux/config.json"))?;
        let token = cfg
            .pointer("/websocket/token")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| format!("remote {host} config has no websocket token"))?;
        Ok((token, peer))
    }

    pub fn remote_build(&self) -> Option<String> {
        self.remote_version.lock().unwrap().as_ref().map(|(_, b)| b.clone())
    }

    pub fn summary(&self) -> Value {
        json!({
            "name": self.name,
            "url": self.url,
            "connected": self.connected.load(Ordering::SeqCst),
            "error": self.last_error.lock().unwrap().clone(),
            "remoteVersion": self.remote_version.lock().unwrap().as_ref().map(|(v, _)| v.clone()),
            "remoteBuild": self.remote_version.lock().unwrap().as_ref().map(|(_, b)| b.clone()),
            "localBuild": crate::hub::BUILD,
            "servedAs": self.served_as.lock().unwrap_or_else(|e| e.into_inner()).clone(),
            "outdated": self.remote_version.lock().unwrap().as_ref().map(|(_, b)| b != crate::hub::BUILD).unwrap_or(false),
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
            Ok(Err(_)) => {
                Err(RpcError::internal(format!("peer {} dropped the request", self.name)))
            }
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
                    let notice = PeerNotice::Disconnected(e);
                    let _ = self.notices.send((self.name.clone(), self.generation, notice)).await;
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

    async fn connect_once(
        self: &Arc<Self>,
        out_rx: &mut mpsc::Receiver<String>,
    ) -> Result<(), String> {
        if self.ssh_parts().is_some() {
            let (token, peer_token) = self.remote_tokens().await?;
            let (stream, remote_port) = self.open_tunnel().await?;
            let req = self.ws_request(
                &format!("ws://127.0.0.1:{remote_port}"),
                Some(&token),
                peer_token.as_deref(),
            )?;
            let (ws, _) = tokio::time::timeout(
                Duration::from_secs(10),
                tokio_tungstenite::client_async(req, stream),
            )
            .await
            .map_err(|_| "connect timed out".to_owned())?
            .map_err(|e| e.to_string())?;
            return self.serve(ws, out_rx).await;
        }
        let req = self.ws_request(&self.url, self.token.as_deref(), self.peer_token.as_deref())?;
        let (ws, _) =
            tokio::time::timeout(Duration::from_secs(10), tokio_tungstenite::connect_async(req))
                .await
                .map_err(|_| "connect timed out".to_owned())?
                .map_err(|e| e.to_string())?;
        self.serve(ws, out_rx).await
    }

    fn ws_request(
        &self,
        url: &str,
        token: Option<&str>,
        peer_token: Option<&str>,
    ) -> Result<tokio_tungstenite::tungstenite::handshake::client::Request, String> {
        let mut req = url.into_client_request().map_err(|e| e.to_string())?;
        if let Some(t) = token {
            req.headers_mut().insert(
                "authorization",
                format!("Bearer {t}").parse().map_err(|_| "bad token".to_owned())?,
            );
        }
        if let Some(p) = peer_token {
            req.headers_mut().insert(
                crate::server::peer_auth::HEADER,
                p.parse().map_err(|_| "bad peer token".to_owned())?,
            );
        }
        Ok(req)
    }

    /// Run one connected WebSocket until it closes.
    async fn serve<S>(
        self: &Arc<Self>,
        ws: tokio_tungstenite::WebSocketStream<S>,
        out_rx: &mut mpsc::Receiver<String>,
    ) -> Result<(), String>
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    {
        let (mut sink, mut source) = ws.split();
        self.connected.store(true, Ordering::SeqCst);
        *self.last_error.lock().unwrap() = None;
        tracing::info!(peer = %self.name, "connected to {}", self.url);

        // Handshake in a task so the read loop below can serve the responses.
        let me = self.clone();
        let handshake = tokio::spawn(async move {
            let init = me
                .request(
                    method::INITIALIZE,
                    json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "acpmux-peer", "version": crate::hub::VERSION}}),
                )
                .await?;
            let v = init
                .pointer("/_meta/acpmux/version")
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_owned();
            let b = init
                .pointer("/_meta/acpmux/build")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_owned();
            *me.remote_version.lock().unwrap() = Some((v, b));
            *me.served_as.lock().unwrap_or_else(|e| e.into_inner()) =
                init.pointer("/_meta/acpmux/origin").and_then(Value::as_str).map(str::to_owned);
            let watch = me.request(method::MUX_WATCH, json!({"enabled": true})).await?;
            let sessions =
                watch.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default();
            let _ = me
                .notices
                .send((me.name.clone(), me.generation, PeerNotice::Sessions(sessions)))
                .await;
            let _ = me.notices.send((me.name.clone(), me.generation, PeerNotice::Connected)).await;
            let attached: Vec<String> = me.attached.lock().unwrap().iter().cloned().collect();
            for sid in attached {
                let _ = me.request(method::MUX_ATTACH, json!({"sessionId": sid, "limit": 0})).await;
            }
            Ok::<(), RpcError>(())
        });

        let result = loop {
            if self.stop.load(Ordering::SeqCst) {
                break Ok(());
            }
            tokio::select! {
                _ = self.stop_signal.notified() => break Ok(()),
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
                            if self.notices.send((self.name.clone(), self.generation, notice)).await.is_err() {
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

/// The default WebSocket port of an `ssh://` peer.
pub const SSH_PEER_PORT: u16 = 47811;

/// An `ssh://` peer's ssh destination (`[user@]host`) and remote port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshTarget {
    pub destination: String,
    pub port: u16,
}

/// Parse and check `ssh://[user@]host[:port]`. Every part reaches an ssh or
/// scp argv, and a peer URL can come from any WebSocket token holder
/// (`_acpmux/peer_add`), so a part that ssh could read as an option or that
/// carries anything but a name is refused: an empty user or host, one that
/// starts with `-` (`-oProxyCommand=...`, `-F...`), whitespace or a control
/// character, an `@` in the host, and a port that is not a plain number in
/// 1..=65535. The reason never quotes the value (it may hold a secret).
pub fn ssh_target(url: &str) -> Result<SshTarget, &'static str> {
    let rest = url.strip_prefix("ssh://").ok_or("not an ssh:// url")?;
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    let (user, hostport) = match rest.split_once('@') {
        Some((user, hostport)) => (Some(user), hostport),
        None => (None, rest),
    };
    let bracketed = hostport.starts_with('[') && hostport.ends_with(']');
    let (host, port) = match hostport.rsplit_once(':') {
        Some((host, port)) if !bracketed => {
            let plain = !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit());
            let port = port.parse::<u16>().ok().filter(|p| plain && *p > 0);
            (host, port.ok_or("the port is not a plain number")?)
        }
        _ => (hostport, SSH_PEER_PORT),
    };
    check_ssh_part(host, "host")?;
    if host.contains('@') {
        return Err("the host has an @");
    }
    let destination = match user {
        Some(user) => {
            check_ssh_part(user, "user")?;
            format!("{user}@{host}")
        }
        None => host.to_owned(),
    };
    Ok(SshTarget { destination, port })
}

fn check_ssh_part(part: &str, what: &'static str) -> Result<(), &'static str> {
    let host = what == "host";
    if part.is_empty() {
        return Err(if host { "the host is empty" } else { "the user is empty" });
    }
    if part.starts_with('-') {
        return Err(if host {
            "the host starts with - (an ssh option)"
        } else {
            "the user starts with - (an ssh option)"
        });
    }
    // Names only: a user's ssh_config may put %h or %r into a shell command
    // (ProxyCommand, Match exec), and scp reads `/` and `:` itself.
    let name = |b: u8| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-');
    let plain = if let Some(inner) = part.strip_prefix('[').and_then(|p| p.strip_suffix(']')) {
        // A bracketed IPv6 address (scp strips the brackets).
        host && !inner.is_empty()
            && inner.bytes().all(|b| b.is_ascii_hexdigit() || matches!(b, b':' | b'.' | b'%'))
    } else {
        part.bytes().all(name)
    };
    if !plain {
        return Err(if host {
            "the host is not a plain name or [IPv6] address"
        } else {
            "the user is not a plain name"
        });
    }
    Ok(())
}

/// `ssh ... -W 127.0.0.1:PORT -- DESTINATION`: the `--` ends ssh's options,
/// so the destination is never read as one.
pub fn tunnel_argv(destination: &str, port: u16) -> Vec<String> {
    let mut argv: Vec<String> = [
        "-o",
        "BatchMode=yes",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=3",
        "-o",
        "ConnectTimeout=10",
        "-W",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    argv.push(format!("127.0.0.1:{port}"));
    argv.push("--".into());
    argv.push(destination.to_owned());
    argv
}

/// `ssh ... -- DESTINATION '<fixed command>'`: the remote config, a NUL,
/// then the remote daemon's peer token of this launch, if it has one.
pub fn read_config_argv(destination: &str) -> Vec<String> {
    [
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        "--",
        destination,
        "cat ~/.acpmux/config.json; printf '\\0'; cat ~/.acpmux/run/peer.token 2>/dev/null",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

/// The output of `read_config_argv`: the config bytes and the peer token
/// (None when absent or not a 64-digit hex token).
pub fn split_remote_read(out: &[u8]) -> (&[u8], Option<String>) {
    let Some(at) = out.iter().position(|b| *b == 0) else { return (out, None) };
    let token = std::str::from_utf8(&out[at + 1..]).ok().map(str::trim);
    let token = token.filter(|t| t.len() == 64 && t.bytes().all(|b| b.is_ascii_hexdigit()));
    (&out[..at], token.map(str::to_owned))
}

#[cfg(test)]
mod ssh_tests {
    use super::*;

    #[test]
    fn option_shaped_or_odd_parts_are_refused() {
        for bad in [
            "ssh://-oProxyCommand=touch%20/tmp/x",
            "ssh://-oProxyCommand=touch /tmp/x",
            "ssh://-Fevil",
            "ssh://-F",
            "ssh://-luser@host",
            "ssh://-oProxyCommand=x@host",
            "ssh://user@-oProxyCommand=x",
            "ssh://ho st",
            "ssh://host\tname",
            "ssh://host\nname",
            "ssh://host\u{7}",
            "ssh://us er@host",
            "ssh://user\r@host",
            "ssh://@host",
            "ssh://user@",
            "ssh://",
            "ssh://host:abc",
            "ssh://host:",
            "ssh://host:0",
            "ssh://host:99999",
            "ssh://host:+22",
            "ssh://a@b@c",
            "ssh://[-oProxyCommand=x]",
            "ssh://u@[-oProxyCommand=x]:22",
            "ssh://[]",
            "ssh://a/b@h",
            "ssh://u:p@h",
            "ssh://h;id",
            "ssh://$(id)",
            "ssh://`id`",
            "ssh://h|x",
            "ssh://h'x",
            "ssh://[::1",
        ] {
            assert!(ssh_target(bad).is_err(), "{bad:?} must be refused");
        }
    }

    #[test]
    fn plain_targets_parse() {
        let t = |u: &str| ssh_target(u).unwrap();
        assert_eq!(t("ssh://box"), SshTarget { destination: "box".into(), port: 47811 });
        assert_eq!(
            t("ssh://me@box.local:2222"),
            SshTarget { destination: "me@box.local".into(), port: 2222 }
        );
        assert_eq!(t("ssh://box/"), SshTarget { destination: "box".into(), port: 47811 });
        assert_eq!(t("ssh://[::1]"), SshTarget { destination: "[::1]".into(), port: 47811 });
        assert_eq!(t("ssh://[::1]:9"), SshTarget { destination: "[::1]".into(), port: 9 });
        assert_eq!(
            t("ssh://a_b@h-1.x"),
            SshTarget { destination: "a_b@h-1.x".into(), port: 47811 }
        );
    }

    #[test]
    fn a_refusal_never_quotes_the_value() {
        let secret = "ssh://-oProxyCommand=SECRETVALUE";
        let reason = ssh_target(secret).unwrap_err();
        assert!(!reason.contains("SECRETVALUE"));
    }

    #[test]
    fn the_remote_read_splits_the_config_from_the_peer_token() {
        let token = "ab".repeat(32);
        let out = format!("{{\"websocket\":{{}}}}\0{token}\n");
        let (config, peer) = split_remote_read(out.as_bytes());
        assert_eq!(config, b"{\"websocket\":{}}");
        assert_eq!(peer.as_deref(), Some(token.as_str()));
        // An older remote daemon has no peer token: it serves us as Web.
        assert_eq!(split_remote_read(b"{}\0").1, None);
        assert_eq!(split_remote_read(b"{}").1, None);
        assert_eq!(split_remote_read(b"{}\0not a token").1, None);
    }

    #[test]
    fn the_destination_always_follows_double_dash() {
        for argv in [tunnel_argv("box", 1), read_config_argv("box")] {
            let dd = argv.iter().position(|a| a == "--").expect("a -- in every ssh argv");
            assert_eq!(argv[dd + 1], "box", "{argv:?}");
            assert!(argv[..dd].iter().all(|a| a != "box"));
        }
    }
}
