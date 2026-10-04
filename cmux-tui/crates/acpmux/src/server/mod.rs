//! Client-facing side. acpmux acts as an ACP agent to every connection and
//! adds the `_acpmux/*` extension methods. Transports: Unix socket lines and
//! WebSocket text frames. Both feed `serve_connection`.

use crate::config::PermissionPolicy;
use crate::hub::{EventFilter, Hub, HubEvent, VERSION};
use crate::rpc::{Message, RpcError, method};
use crate::store::EventRecord;
use anyhow::{Context, Result};
use cmux_local_auth::{ListenerPolicy, Refusal};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, UnixListener};
use tokio::sync::{broadcast, mpsc};

/// How one connection receives one attached session's live records.
#[derive(Debug, Clone, Default)]
pub struct SubOpts {
    /// Every record arrives as `_acpmux/event` (agent notifications nested
    /// in `msg`) instead of `session/update` plus `_acpmux/event`.
    pub event_stream: bool,
    /// With `event_stream`, only records this filter passes are sent.
    pub filter: EventFilter,
}

pub struct Conn {
    pub id: String,
    /// The listener this connection came in on.
    pub origin: Origin,
    name: StdMutex<String>,
    out: mpsc::Sender<String>,
    subs: StdMutex<HashMap<String, SubOpts>>,
    watch_all: AtomicBool,
}

impl Conn {
    fn send(&self, msg: &Message) {
        let _ = self.out.try_send(msg.to_line());
    }
    fn sub_opts(&self, session_id: &str) -> Option<SubOpts> {
        self.subs.lock().unwrap().get(session_id).cloned()
    }
    /// Subscribe with default options; keeps options already set.
    fn subscribe(&self, session_id: &str) -> bool {
        let mut subs = self.subs.lock().unwrap();
        if subs.contains_key(session_id) {
            return false;
        }
        subs.insert(session_id.to_owned(), SubOpts::default());
        true
    }
    /// Subscribe, replacing any options. True when the subscription is new.
    fn subscribe_with(&self, session_id: &str, opts: SubOpts) -> bool {
        self.subs.lock().unwrap().insert(session_id.to_owned(), opts).is_none()
    }
    fn unsubscribe(&self, session_id: &str) -> bool {
        self.subs.lock().unwrap().remove(session_id).is_some()
    }
    fn label(&self) -> String {
        let n = self.name.lock().unwrap().clone();
        if n.is_empty() { self.id.clone() } else { format!("{n}#{}", &self.id[..6]) }
    }
}

// ----------------------------------------------------------------- listen

pub async fn listen_unix(hub: Arc<Hub>, path: PathBuf) -> Result<()> {
    let listener = bind_unix(&path).await?;
    serve_unix(hub, listener).await
}

/// Bind the daemon socket (mode 0600), refusing to steal a live one.
pub async fn bind_unix(path: &std::path::Path) -> Result<UnixListener> {
    // A configured path longer than sun_path fails here with the path and
    // the limit, never as a bare bind error.
    cmux_unix_socket::check_path(path)?;
    if let Some(parent) = path.parent() {
        // Owner-only when created here, like the /tmp fallback directory.
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent)?;
    }
    if path.exists() {
        // Refuse to steal a live socket.
        if tokio::net::UnixStream::connect(path).await.is_ok() {
            anyhow::bail!("another acpmux daemon owns {}", path.display());
        }
        std::fs::remove_file(path)?;
    }
    let listener = UnixListener::bind(path).with_context(|| format!("bind {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    tracing::info!("listening on {}", path.display());
    Ok(listener)
}

pub async fn serve_unix(hub: Arc<Hub>, listener: UnixListener) -> Result<()> {
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!("accept failed: {e}");
                continue;
            }
        };
        let hub = hub.clone();
        tokio::spawn(async move {
            let (rd, mut wr) = stream.into_split();
            let (in_tx, in_rx) = mpsc::channel::<String>(256);
            let (out_tx, mut out_rx) = mpsc::channel::<String>(4096);
            tokio::spawn(async move {
                let mut lines = BufReader::new(rd).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if in_tx.send(line).await.is_err() {
                        break;
                    }
                }
            });
            tokio::spawn(async move {
                while let Some(line) = out_rx.recv().await {
                    if wr.write_all(line.as_bytes()).await.is_err() {
                        break;
                    }
                }
            });
            serve_connection(hub, in_rx, out_tx).await;
        });
    }
}

const INDEX_HTML: &str = include_str!("../../web/index.html");

/// One TCP port serves both the dashboard page (plain HTTP GET) and the
/// WebSocket protocol. The request head is peeked, never consumed, so the
/// WebSocket handshake still sees the full request.
///
/// Every request passes the localhost listener rule first
/// (plans/cmux-next/identity.md section 4): a loopback `Host`, no foreign
/// `Origin`, and the token, which is mandatory.
pub async fn listen_ws(hub: Arc<Hub>, addr: String, token: String) -> Result<()> {
    let listener = bind_ws(&addr).await?;
    serve_ws(hub, listener, token).await
}

/// Bind the dashboard/WebSocket port. `127.0.0.1:0` picks a free port; read
/// it back with `local_addr`.
pub async fn bind_ws(addr: &str) -> Result<TcpListener> {
    let listener = TcpListener::bind(addr).await.with_context(|| format!("bind {addr}"))?;
    let local = listener.local_addr().map(|a| a.to_string()).unwrap_or_else(|_| addr.to_owned());
    tracing::info!("web + websocket listening on {local}");
    Ok(listener)
}

/// The origin of the app's bundled agent pane page (a `cmux-agent` URL
/// scheme handler). A `file://` page would send `Origin: null`, which every
/// localhost listener refuses.
pub const AGENT_PANE_ORIGIN: &str = "cmux-agent://pane";

/// The Origin and Host rule of this listener: its own origin (the
/// dashboard page), the agent pane, and the origins and hosts the config
/// adds (`websocket.allowed_origins`, `websocket.allowed_hosts`). Never
/// `null`. An entry that does not parse is skipped with a warning.
pub fn listener_policy(
    address: std::net::SocketAddr,
    extra_origins: &[String],
    extra_hosts: &[String],
) -> ListenerPolicy {
    let mut policy = ListenerPolicy::for_bind(address).with_origin(AGENT_PANE_ORIGIN);
    for origin in extra_origins {
        if cmux_local_auth::parse_origin(origin).is_none() {
            tracing::warn!(
                "websocket.allowed_origins: ignoring {origin:?} (not scheme://host[:port])"
            );
            continue;
        }
        policy = policy.with_origin(origin);
    }
    for host in extra_hosts {
        policy = policy.with_host(host);
    }
    policy
}

/// Validate a `--allow-dev-origin` value: only a loopback `http` origin with
/// an explicit port (a page dev server on this machine). Anything else is an
/// error, so the flag can never admit a web site.
pub fn dev_origin(value: &str) -> Result<String> {
    let origin = cmux_local_auth::parse_origin(value)
        .ok_or_else(|| anyhow::anyhow!("--allow-dev-origin {value:?} is not scheme://host:port"))?;
    let rest = origin
        .strip_prefix("http://")
        .ok_or_else(|| anyhow::anyhow!("--allow-dev-origin {value:?} must be http"))?;
    let (host, port) = rest
        .rsplit_once(':')
        .ok_or_else(|| anyhow::anyhow!("--allow-dev-origin {value:?} needs a port"))?;
    anyhow::ensure!(
        matches!(host, "127.0.0.1" | "localhost" | "[::1]") && port.parse::<u16>().is_ok(),
        "--allow-dev-origin {value:?} must be a loopback host with a port"
    );
    Ok(origin)
}

/// An accepted web socket streams many small ACP deltas: send each at once (no Nagle delay).
fn tune_ws_socket(stream: &tokio::net::TcpStream) {
    if let Err(e) = stream.set_nodelay(true) {
        tracing::debug!("ws TCP_NODELAY: {e}");
    }
}

pub async fn serve_ws(hub: Arc<Hub>, listener: TcpListener, token: String) -> Result<()> {
    serve_ws_with(hub, listener, token, None).await
}

/// How long a connection may wait before its first frame decides whether it
/// is the local app (`local_app.rs`); after it, it is remote-origin.
const FIRST_FRAME: std::time::Duration = std::time::Duration::from_secs(10);

/// `serve_ws` with this launch's LocalApp token: a connection that meets
/// every LocalApp condition is served as `Origin::LocalApp`.
pub async fn serve_ws_with(
    hub: Arc<Hub>,
    listener: TcpListener,
    token: String,
    local_app: Option<Arc<local_app::LocalAppAuth>>,
) -> Result<()> {
    anyhow::ensure!(!token.is_empty(), "the acpmux web listener needs a token");
    let bound = listener.local_addr()?;
    let (extra_origins, extra_hosts) = {
        let config = hub.config.read().await;
        let (mut origins, hosts) = config
            .websocket
            .as_ref()
            .map(|w| (w.allowed_origins.clone(), w.allowed_hosts.clone()))
            .unwrap_or_default();
        origins.extend(config.dev_origins.iter().cloned());
        (origins, hosts)
    };
    let policy = Arc::new(listener_policy(listener.local_addr()?, &extra_origins, &extra_hosts));
    let token = Arc::new(token);
    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!("ws accept failed: {e}");
                continue;
            }
        };
        tune_ws_socket(&stream);
        let hub = hub.clone();
        let token = token.clone();
        let policy = policy.clone();
        let local_app = local_app.clone();
        tokio::spawn(async move {
            let mut head = [0u8; 4096];
            let n = match tokio::time::timeout(
                std::time::Duration::from_secs(5),
                stream.peek(&mut head),
            )
            .await
            {
                Ok(Ok(n)) => n,
                _ => return,
            };
            // The peek only routes the request. Each path checks the full
            // head it parses: serve_http reads it, tungstenite parses the
            // upgrade request for the callback.
            let head_text = String::from_utf8_lossy(&head[..n]).into_owned();
            if !head_text.to_ascii_lowercase().contains("upgrade: websocket") {
                serve_http(stream, &policy, &token, peer).await;
                return;
            }
            let expected = token.clone();
            // The upgrade request's Origin headers, for the LocalApp check.
            let seen_origins: Arc<StdMutex<Vec<String>>> = Arc::default();
            let record_origins = seen_origins.clone();
            let callback = move |req: &tokio_tungstenite::tungstenite::handshake::server::Request,
                                 resp: tokio_tungstenite::tungstenite::handshake::server::Response| {
                let values = |name: &str| {
                    req.headers()
                        .get_all(name)
                        .iter()
                        .map(|value| value.to_str().unwrap_or("\u{0}"))
                        .collect::<Vec<_>>()
                };
                let refuse = |refusal: Refusal| {
                    tokio_tungstenite::tungstenite::http::Response::builder()
                        .status(refusal.status())
                        .body(Some(refusal.reason().to_owned()))
                        .expect("static response")
                };
                if let Err(refusal) = policy.check(&values("host"), &values("origin")) {
                    return Err(refuse(refusal));
                }
                *record_origins.lock().unwrap_or_else(|e| e.into_inner()) =
                    values("origin").into_iter().map(str::to_owned).collect();
                let header = req
                    .headers()
                    .get("authorization")
                    .and_then(|v| v.to_str().ok())
                    .and_then(cmux_local_auth::bearer_token);
                let query = req.uri().query().and_then(cmux_local_auth::query_token);
                cmux_local_auth::check_token(header.or(query), &expected)
                    .map(|()| resp)
                    .map_err(refuse)
            };
            let ws = match tokio_tungstenite::accept_hdr_async(stream, callback).await {
                Ok(ws) => ws,
                Err(e) => {
                    tracing::warn!("ws handshake from {peer} rejected: {e}");
                    return;
                }
            };
            let (mut sink, mut source) = ws.split();
            let (in_tx, in_rx) = mpsc::channel::<String>(256);
            let (out_tx, mut out_rx) = mpsc::channel::<String>(4096);
            // The first frame decides LocalApp; it reaches the protocol
            // handler without the token.
            let mut origin = Origin::Web;
            let mut first = None;
            if let Some(auth) = &local_app {
                let frame = tokio::time::timeout(FIRST_FRAME, async {
                    while let Some(Ok(frame)) = source.next().await {
                        if let tokio_tungstenite::tungstenite::Message::Text(t) = frame {
                            return Some(t.to_string());
                        }
                    }
                    None
                })
                .await
                .ok()
                .flatten();
                let origins = seen_origins.lock().unwrap_or_else(|e| e.into_inner()).clone();
                let hello = local_app::Hello {
                    listener: bound,
                    peer,
                    origins: &origins,
                    first_frame: frame.as_deref(),
                };
                if auth.is_local_app(&hello) {
                    origin = Origin::LocalApp;
                }
                first = frame.map(|f| local_app::strip_token(&f));
            }
            if let Some(first) = first
                && in_tx.send(first).await.is_err()
            {
                return;
            }
            tokio::spawn(async move {
                while let Some(Ok(frame)) = source.next().await {
                    if let tokio_tungstenite::tungstenite::Message::Text(t) = frame
                        && in_tx.send(t.to_string()).await.is_err()
                    {
                        break;
                    }
                }
            });
            tokio::spawn(async move {
                while let Some(line) = out_rx.recv().await {
                    let text = line.trim_end_matches('\n').to_owned();
                    if sink
                        .send(tokio_tungstenite::tungstenite::Message::Text(text.into()))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
            });
            serve_connection_with(hub, in_rx, out_tx, origin).await;
        });
    }
}

/// Check the `Host` and `Origin` values of a complete request head.
fn check_head(policy: &ListenerPolicy, head: &str) -> Result<(), Refusal> {
    let mut hosts = Vec::new();
    let mut origins = Vec::new();
    for line in head.split("\r\n").skip(1) {
        if line.is_empty() {
            break;
        }
        let Some((name, value)) = line.split_once(':') else { continue };
        let name = name.trim();
        if name.eq_ignore_ascii_case("host") {
            hosts.push(value.trim());
        } else if name.eq_ignore_ascii_case("origin") {
            origins.push(value.trim());
        }
    }
    policy.check(&hosts, &origins)
}

async fn refuse_http(mut stream: tokio::net::TcpStream, refusal: Refusal) {
    let status = match refusal.status() {
        401 => "401 Unauthorized",
        _ => "403 Forbidden",
    };
    let body = refusal.reason();
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: text/plain\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

/// The largest request head the dashboard reads.
const MAX_HTTP_HEAD_BYTES: usize = 32 * 1024;

/// Read a request head up to its blank line. None when it is larger than
/// [`MAX_HTTP_HEAD_BYTES`] (room for large localhost cookies), the peer
/// closes first, or it takes over 2 s.
async fn read_http_head(stream: &mut tokio::net::TcpStream) -> Option<String> {
    let read = async {
        let mut head = Vec::with_capacity(1024);
        let mut chunk = [0u8; 4096];
        while !head.windows(4).any(|window| window == b"\r\n\r\n") {
            if head.len() >= MAX_HTTP_HEAD_BYTES {
                return None;
            }
            let n = stream.read(&mut chunk).await.ok()?;
            if n == 0 {
                return None;
            }
            head.extend_from_slice(&chunk[..n]);
        }
        Some(String::from_utf8_lossy(&head).into_owned())
    };
    tokio::time::timeout(std::time::Duration::from_secs(2), read).await.ok().flatten()
}

/// Minimal HTTP for the dashboard. The whole head passes the listener rule
/// first; then GET / with a matching token serves the page, and anything
/// else is 401 or 404.
async fn serve_http(
    mut stream: tokio::net::TcpStream,
    policy: &ListenerPolicy,
    token: &str,
    peer: std::net::SocketAddr,
) {
    let Some(head) = read_http_head(&mut stream).await else {
        refuse_http(stream, Refusal::MissingHost).await;
        return;
    };
    if let Err(refusal) = check_head(policy, &head) {
        tracing::warn!("web request from {peer} refused: {refusal}");
        refuse_http(stream, refusal).await;
        return;
    }
    let first = head.lines().next().unwrap_or("");
    let mut parts = first.split_whitespace();
    let method_ = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let (status, body, ctype) = if !method_.eq_ignore_ascii_case("get") {
        ("405 Method Not Allowed", "method not allowed".to_owned(), "text/plain")
    } else if path == "/health" {
        ("200 OK", "ok".to_owned(), "text/plain")
    } else if path == "/" || path == "/index.html" {
        if cmux_local_auth::check_token(cmux_local_auth::query_token(query), token).is_ok() {
            ("200 OK", INDEX_HTML.to_owned(), "text/html; charset=utf-8")
        } else {
            ("401 Unauthorized", "<!doctype html><meta charset=utf-8><title>acpmux</title><p style=\"font-family:system-ui;padding:2rem\">This dashboard needs its token. Run <code>acpmux web</code> in a terminal to get the full link.</p>".to_owned(), "text/html; charset=utf-8")
        }
    } else {
        ("404 Not Found", "not found".to_owned(), "text/plain")
    };
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: {ctype}\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

// ------------------------------------------------------------ connection

/// Where a connection came from. A `Web` connection (the WebSocket
/// listener: peer daemons, remote clients, relays) is remote-origin: remote
/// chains build their settings from scratch, so it never starts or sets a
/// preset that carries harness args or a system prompt, and the session
/// pool never serves it. `LocalApp` is the app's own agent pane, proven by
/// every condition in `local_app.rs`: the pool serves it, it may start any
/// configured preset, and like `Web` it never sets a preset's harness args
/// or system prompt and never reads a token back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Origin {
    /// The local Unix socket.
    #[default]
    Local,
    /// The WebSocket listener.
    Web,
    /// The app's agent pane over the WebSocket listener (`local_app.rs`).
    LocalApp,
}

/// A connection from the local Unix socket.
pub async fn serve_connection(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
) {
    serve_connection_with(hub, inbound, out, Origin::Local).await
}

pub async fn serve_connection_with(
    hub: Arc<Hub>,
    mut inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
) {
    let conn = Arc::new(Conn {
        id: uuid::Uuid::now_v7().to_string(),
        origin,
        name: StdMutex::new(String::new()),
        out,
        subs: StdMutex::new(HashMap::new()),
        watch_all: AtomicBool::new(false),
    });
    tracing::debug!(conn = %conn.id, "client connected");

    // Fan-out task.
    let fan = {
        let hub = hub.clone();
        let conn = conn.clone();
        let mut rx = hub.subscribe();
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(ev) => deliver(&hub, &conn, ev),
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        conn.send(&Message::notification("_acpmux/lagged", json!({"dropped": n})));
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        })
    };

    while let Some(line) = inbound.recv().await {
        if line.trim().is_empty() {
            continue;
        }
        let msg = match Message::parse(&line) {
            Ok(m) => m,
            Err(e) => {
                conn.send(&Message::err(Value::Null, e));
                continue;
            }
        };
        match msg {
            Message::Request { id, method: m, params } => {
                let hub = hub.clone();
                let conn = conn.clone();
                tokio::spawn(async move {
                    let result =
                        handle_request(&hub, &conn, &m, params.unwrap_or(Value::Null)).await;
                    conn.send(&match result {
                        Ok(v) => Message::ok(id, v),
                        Err(e) => Message::err(id, e),
                    });
                });
            }
            Message::Notification { method: m, params } => {
                let hub = hub.clone();
                let conn = conn.clone();
                tokio::spawn(async move {
                    handle_notification(&hub, &conn, &m, params.unwrap_or(Value::Null)).await;
                });
            }
            Message::Response { .. } => {
                // acpmux sends no requests to clients today (permission goes
                // through _acpmux/permission_pending + permission_respond).
            }
        }
    }
    fan.abort();
    // Every attachment this connection held ends with it.
    let subs: Vec<String> = conn.subs.lock().unwrap().drain().map(|(k, _)| k).collect();
    for id in subs {
        if let Ok(s) = hub.resolve(&id) {
            hub.attach_count(&s, -1);
        }
    }
    tracing::debug!(conn = %conn.id, "client disconnected");
}

/// Turn a hub record into client notifications for one connection.
fn deliver(hub: &Hub, conn: &Conn, ev: HubEvent) {
    let rec = &ev.record;
    let watching = conn.watch_all.load(Ordering::SeqCst);
    let sub = conn.sub_opts(&ev.session_id);
    let attached = sub.is_some();
    if !watching && !attached {
        return;
    }
    if let Some(sub) = &sub
        && rec.dir != "peer"
    {
        if sub.event_stream {
            if sub.filter.matches(rec) {
                conn.send(&Message::notification(
                    method::MUX_EVENT,
                    event_value(&ev.session_id, rec),
                ));
            }
        } else {
            // Agent -> client updates as standard ACP notifications.
            if rec.dir == "in"
                && !rec.kind.ends_with(".replay")
                && let Some(m) = rec.msg.get("method").and_then(Value::as_str)
                && m == method::SESSION_UPDATE
            {
                let mut params = rec.msg.get("params").cloned().unwrap_or(json!({}));
                params["sessionId"] = Value::String(ev.session_id.clone());
                crate::hub::merge_mux_meta(
                    &mut params,
                    json!({"seq": rec.seq, "at": rec.at, "kind": rec.kind}),
                );
                conn.send(&Message::notification(method::SESSION_UPDATE, params));
            }
            if rec.dir == "mux" {
                conn.send(&Message::notification(
                    method::MUX_EVENT,
                    event_value(&ev.session_id, rec),
                ));
            }
        }
        if rec.dir == "mux" && rec.kind == "permission_request" {
            conn.send(&Message::notification(
                method::MUX_PERMISSION_PENDING,
                permission_pending(&ev.session_id, rec, "attach"),
            ));
        }
    }
    if watching {
        if let Some(remote) = &ev.remote {
            // Peers already filter to the interesting kinds and send a summary.
            if rec.dir == "peer" {
                let sid = remote
                    .summary
                    .get("sessionId")
                    .cloned()
                    .unwrap_or_else(|| Value::String(ev.session_id.clone()));
                conn.send(&Message::notification(
                    method::MUX_SESSION_CHANGED,
                    json!({"sessionId": sid, "session": remote.summary, "kind": rec.kind, "recordKind": rec.kind, "seq": rec.seq, "peer": remote.peer}),
                ));
            }
            return;
        }
        if rec.dir == "mux" && rec.kind == "purged" {
            conn.send(&Message::notification(
                method::MUX_SESSION_CHANGED,
                json!({"sessionId": ev.session_id, "session": {"sessionId": ev.session_id}, "kind": "purged", "recordKind": "purged", "seq": rec.seq}),
            ));
            return;
        }
        if rec.dir != "mux" {
            return;
        }
        let kind = match rec.kind.as_str() {
            "status"
            | "created"
            | "user_message"
            | "turn_end"
            | "turn_error"
            | "renamed"
            | "forked"
            | "imported"
            | "permission_request"
            | "permission_decision"
            | "permission_group"
            | "permission_chat_allowance"
            | "mode"
            | "model"
            | "config"
            | "policy"
            | "rules"
            | "tags"
            | "turn_started"
            | "turn_result" => rec.kind.as_str(),
            "queued" | "dequeued" => "queue",
            "permission_auto" => "permission_resolved",
            _ => return,
        };
        if let Ok(s) = hub.resolve(&ev.session_id) {
            conn.send(&Message::notification(
                method::MUX_SESSION_CHANGED,
                json!({"sessionId": ev.session_id, "session": hub.session_summary(&s), "kind": kind, "recordKind": rec.kind, "seq": rec.seq}),
            ));
        }
        // A watcher that is not attached still learns a permission is waiting.
        if rec.kind == "permission_request" && !attached {
            conn.send(&Message::notification(
                method::MUX_PERMISSION_PENDING,
                permission_pending(&ev.session_id, rec, "watch"),
            ));
        }
    }
}

fn permission_pending(session_id: &str, rec: &EventRecord, via: &str) -> Value {
    let mut p = rec.msg.clone();
    p["sessionId"] = Value::String(session_id.to_owned());
    p["seq"] = json!(rec.seq);
    p["via"] = Value::String(via.to_owned());
    p
}

pub fn event_value(session_id: &str, rec: &EventRecord) -> Value {
    json!({
        "sessionId": session_id,
        "seq": rec.seq,
        "at": rec.at,
        "dir": rec.dir,
        "kind": rec.kind,
        "msg": rec.msg,
    })
}

fn str_param<'a>(params: &'a Value, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str)
}

fn session_key(params: &Value) -> Result<&str, RpcError> {
    str_param(params, "sessionId")
        .or_else(|| str_param(params, "session"))
        .or_else(|| str_param(params, "name"))
        .ok_or_else(|| RpcError::invalid_params("sessionId or session is required"))
}

fn mux_meta(params: &Value) -> Option<&Value> {
    params.get("_meta").and_then(|m| m.get("acpmux"))
}

pub(crate) fn iso(ms: u64) -> String {
    // Minimal RFC3339 without pulling a date crate.
    let secs = (ms / 1000) as i64;
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{:03}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60,
        ms % 1000
    )
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

pub mod local_app;
mod redact;
mod requests;
mod wait;
use requests::{handle_notification, handle_request};

#[cfg(test)]
mod nodelay_tests {
    use super::tune_ws_socket;

    #[tokio::test]
    async fn an_accepted_web_socket_sends_without_nagle_delay() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let _client = tokio::net::TcpStream::connect(address).await.unwrap();
        let (accepted, _) = listener.accept().await.unwrap();
        assert!(!accepted.nodelay().unwrap(), "a fresh socket has Nagle on");
        tune_ws_socket(&accepted);
        assert!(accepted.nodelay().unwrap());
    }
}
