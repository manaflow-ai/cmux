//! Client-facing side. acpmux acts as an ACP agent to every connection and
//! adds the `_acpmux/*` extension methods. Transports: Unix socket lines and
//! WebSocket text frames. Both feed `serve_connection`.

use crate::config::PermissionPolicy;
use crate::hub::{Hub, HubEvent, VERSION};
use crate::rpc::{Message, RpcError, method};
use crate::store::EventRecord;
use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, UnixListener};
use tokio::sync::{broadcast, mpsc};

pub struct Conn {
    pub id: String,
    name: StdMutex<String>,
    out: mpsc::Sender<String>,
    subs: StdMutex<HashSet<String>>,
    watch_all: AtomicBool,
}

impl Conn {
    fn send(&self, msg: &Message) {
        let _ = self.out.try_send(msg.to_line());
    }
    fn subscribed(&self, session_id: &str) -> bool {
        self.subs.lock().unwrap().contains(session_id)
    }
    fn subscribe(&self, session_id: &str) {
        self.subs.lock().unwrap().insert(session_id.to_owned());
    }
    fn label(&self) -> String {
        let n = self.name.lock().unwrap().clone();
        if n.is_empty() { self.id.clone() } else { format!("{n}#{}", &self.id[..6]) }
    }
}

// ----------------------------------------------------------------- listen

pub async fn listen_unix(hub: Arc<Hub>, path: PathBuf) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if path.exists() {
        // Refuse to steal a live socket.
        if tokio::net::UnixStream::connect(&path).await.is_ok() {
            anyhow::bail!("another acpmux daemon owns {}", path.display());
        }
        std::fs::remove_file(&path)?;
    }
    let listener = UnixListener::bind(&path).with_context(|| format!("bind {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    tracing::info!("listening on {}", path.display());
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

const INDEX_HTML: &str = include_str!("../web/index.html");

/// One TCP port serves both the dashboard page (plain HTTP GET) and the
/// WebSocket protocol. The request head is peeked, never consumed, so the
/// WebSocket handshake still sees the full request.
pub async fn listen_ws(hub: Arc<Hub>, addr: String, token: Option<String>) -> Result<()> {
    let listener = TcpListener::bind(&addr).await.with_context(|| format!("bind {addr}"))?;
    tracing::info!("web + websocket listening on {addr}");
    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!("ws accept failed: {e}");
                continue;
            }
        };
        let hub = hub.clone();
        let token = token.clone();
        tokio::spawn(async move {
            let mut head = [0u8; 4096];
            let n = match tokio::time::timeout(std::time::Duration::from_secs(5), stream.peek(&mut head)).await {
                Ok(Ok(n)) => n,
                _ => return,
            };
            let head_text = String::from_utf8_lossy(&head[..n]).into_owned();
            if !head_text.to_ascii_lowercase().contains("upgrade: websocket") {
                serve_http(stream, &head_text, token.as_deref()).await;
                return;
            }
            let expected = token.clone();
            let callback = move |req: &tokio_tungstenite::tungstenite::handshake::server::Request,
                                 resp: tokio_tungstenite::tungstenite::handshake::server::Response| {
                let Some(expected) = expected.as_deref() else { return Ok(resp) };
                let header_ok = req
                    .headers()
                    .get("authorization")
                    .and_then(|v| v.to_str().ok())
                    .map(|v| v.strip_prefix("Bearer ").unwrap_or(v) == expected)
                    .unwrap_or(false);
                let query_ok = req
                    .uri()
                    .query()
                    .map(|q| q.split('&').any(|kv| kv == format!("token={expected}")))
                    .unwrap_or(false);
                if header_ok || query_ok {
                    Ok(resp)
                } else {
                    let denied = tokio_tungstenite::tungstenite::http::Response::builder()
                        .status(401)
                        .body(Some("unauthorized".to_owned()))
                        .expect("static response");
                    Err(denied)
                }
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
            tokio::spawn(async move {
                while let Some(Ok(frame)) = source.next().await {
                    if let tokio_tungstenite::tungstenite::Message::Text(t) = frame {
                        if in_tx.send(t.to_string()).await.is_err() {
                            break;
                        }
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
            serve_connection(hub, in_rx, out_tx).await;
        });
    }
}

/// Minimal HTTP for the dashboard. GET / with a matching token serves the
/// page; anything else is 401 or 404. Requests are read no further than
/// the head we already peeked.
async fn serve_http(mut stream: tokio::net::TcpStream, head: &str, token: Option<&str>) {
    let mut buf = vec![0u8; 8192];
    let _ = tokio::time::timeout(std::time::Duration::from_secs(2), stream.read(&mut buf)).await;
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
        let ok = match token {
            None => true,
            Some(t) => query.split('&').any(|kv| kv == format!("token={t}")),
        };
        if ok {
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

pub async fn serve_connection(hub: Arc<Hub>, mut inbound: mpsc::Receiver<String>, out: mpsc::Sender<String>) {
    let conn = Arc::new(Conn {
        id: uuid::Uuid::now_v7().to_string(),
        name: StdMutex::new(String::new()),
        out,
        subs: StdMutex::new(HashSet::new()),
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
                        conn.send(&Message::notification(
                            "_acpmux/lagged",
                            json!({"dropped": n}),
                        ));
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
                    let result = handle_request(&hub, &conn, &m, params.unwrap_or(Value::Null)).await;
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
    tracing::debug!(conn = %conn.id, "client disconnected");
}

/// Turn a hub record into client notifications for one connection.
fn deliver(hub: &Hub, conn: &Conn, ev: HubEvent) {
    let rec = &ev.record;
    let watching = conn.watch_all.load(Ordering::SeqCst);
    let attached = conn.subscribed(&ev.session_id);
    if !watching && !attached {
        return;
    }
    if attached && rec.dir != "peer" {
        // Agent -> client updates as standard ACP notifications.
        if rec.dir == "in" && !rec.kind.ends_with(".replay") {
            if let Some(m) = rec.msg.get("method").and_then(Value::as_str) {
                if m == method::SESSION_UPDATE {
                    let mut params = rec.msg.get("params").cloned().unwrap_or(json!({}));
                    params["sessionId"] = Value::String(ev.session_id.clone());
                    params["_meta"] = json!({"acpmux": {"seq": rec.seq, "at": rec.at}});
                    conn.send(&Message::notification(method::SESSION_UPDATE, params));
                }
            }
        }
        if rec.dir == "mux" {
            conn.send(&Message::notification(method::MUX_EVENT, event_value(&ev.session_id, rec)));
            if rec.kind == "permission_request" {
                let mut p = rec.msg.clone();
                p["sessionId"] = Value::String(ev.session_id.clone());
                conn.send(&Message::notification(method::MUX_PERMISSION_PENDING, p));
            }
        }
    }
    if watching {
        if let Some(remote) = &ev.remote {
            // Peers already filter to the interesting kinds and send a summary.
            if rec.dir == "peer" {
                conn.send(&Message::notification(
                    method::MUX_SESSION_CHANGED,
                    json!({"session": remote.summary, "kind": rec.kind, "seq": rec.seq, "peer": remote.peer}),
                ));
            }
            return;
        }
        if rec.dir == "mux"
            && matches!(
                rec.kind.as_str(),
                "status" | "created" | "user_message" | "turn_end" | "turn_error" | "renamed" | "forked" | "imported" | "permission_request" | "permission_decision" | "mode" | "model" | "config" | "policy"
            )
        {
            if let Ok(s) = hub.resolve(&ev.session_id) {
                conn.send(&Message::notification(
                    method::MUX_SESSION_CHANGED,
                    json!({"session": hub.session_summary(&s), "kind": rec.kind, "seq": rec.seq}),
                ));
            }
        }
    }
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

fn mux_meta<'a>(params: &'a Value) -> Option<&'a Value> {
    params.get("_meta").and_then(|m| m.get("acpmux"))
}

fn iso(ms: u64) -> String {
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

async fn handle_notification(hub: &Arc<Hub>, conn: &Arc<Conn>, m: &str, params: Value) {
    match m {
        method::SESSION_CANCEL => {
            if let Ok(key) = session_key(&params) {
                if let Ok(s) = hub.resolve(key) {
                    if let Err(e) = hub.cancel(&s).await {
                        tracing::warn!(conn = %conn.id, "cancel failed: {e}");
                    }
                } else if let Some((peer, id, _)) = hub.resolve_remote(key) {
                    let _ = peer.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await;
                }
            }
        }
        method::CANCEL_REQUEST => {}
        _ => tracing::debug!(conn = %conn.id, "ignored notification {m}"),
    }
}

const SESSION_SCOPED_EXCLUDED: &[&str] = &[
    method::INITIALIZE,
    method::AUTHENTICATE,
    method::SESSION_NEW,
    method::SESSION_LIST,
    method::MUX_STATUS,
    method::MUX_SESSIONS,
    method::MUX_AGENTS,
    method::MUX_WATCH,
    method::MUX_IMPORT,
    method::MUX_SHUTDOWN,
    "_acpmux/peers",
    "_acpmux/models",
    "_acpmux/peer_add",
    "_acpmux/peer_remove",
];

async fn handle_request(hub: &Arc<Hub>, conn: &Arc<Conn>, m: &str, params: Value) -> Result<Value, RpcError> {
    // A session that lives on a peer: forward the whole request there.
    if !SESSION_SCOPED_EXCLUDED.contains(&m) {
        if let Ok(key) = session_key(&params) {
            if hub.resolve(key).is_err() {
                if let Some((peer, id, _)) = hub.resolve_remote(key) {
                    let mut p = if params.is_null() { json!({}) } else { params.clone() };
                    if let Some(obj) = p.as_object_mut() {
                        obj.remove("session");
                        obj.remove("name");
                        obj.insert("sessionId".into(), Value::String(id.clone()));
                    }
                    if matches!(m, method::MUX_ATTACH | method::SESSION_PROMPT | method::SESSION_LOAD | method::SESSION_RESUME | method::SESSION_FORK) {
                        conn.subscribe(&id);
                        if peer.mark_attached(&id) && m != method::MUX_ATTACH {
                            let _ = peer.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await;
                        }
                    }
                    let mut result = peer.request(m, p).await?;
                    if m == method::SESSION_FORK {
                        if let Some(new_id) = result.get("sessionId").and_then(Value::as_str) {
                            conn.subscribe(new_id);
                            peer.mark_attached(new_id);
                        }
                    }
                    if let Some(obj) = result.as_object_mut() {
                        obj.insert("peer".into(), Value::String(peer.name.clone()));
                    }
                    return Ok(result);
                }
            }
        }
    }
    match m {
        method::INITIALIZE => {
            if let Some(name) = params.pointer("/clientInfo/name").and_then(Value::as_str) {
                *conn.name.lock().unwrap() = name.to_owned();
            }
            Ok(json!({
                "protocolVersion": 1,
                "agentInfo": {"name": "acpmux", "title": "acpmux", "version": VERSION},
                "agentCapabilities": {
                    "loadSession": true,
                    "promptCapabilities": {"image": true, "audio": false, "embeddedContext": true},
                    "sessionCapabilities": {"list": {}, "fork": {}, "close": {}, "delete": {}},
                },
                "authMethods": [],
                "_meta": {"acpmux": {"version": VERSION, "extensions": [
                    method::MUX_STATUS, method::MUX_SESSIONS, method::MUX_AGENTS, method::MUX_ATTACH,
                    method::MUX_DETACH, method::MUX_WATCH, method::MUX_RENAME, method::MUX_KILL,
                    method::MUX_INFO, method::MUX_EVENTS, method::MUX_PERMISSION_RESPOND,
                    method::MUX_SET_POLICY, method::MUX_EXPORT, method::MUX_IMPORT, method::MUX_SHUTDOWN,
                ]}}
            }))
        }
        method::AUTHENTICATE => Ok(json!({})),
        method::SESSION_NEW => {
            // A peer name in _meta.acpmux.peer creates the session on that daemon.
            if let Some(peer_name) = mux_meta(&params).and_then(|m| m.get("peer")).and_then(Value::as_str) {
                if !peer_name.is_empty() {
                    let peer = hub.peer_by_name(peer_name).ok_or_else(|| RpcError::not_found(format!("no peer {peer_name:?}")))?;
                    let mut p = params.clone();
                    if let Some(m) = p.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
                        m.remove("peer");
                    }
                    let mut result = peer.request(method::SESSION_NEW, p).await?;
                    if let Some(id) = result.get("sessionId").and_then(Value::as_str) {
                        conn.subscribe(id);
                        peer.mark_attached(id);
                    }
                    if let Some(obj) = result.as_object_mut() {
                        obj.insert("peer".into(), Value::String(peer.name.clone()));
                    }
                    return Ok(result);
                }
            }
            let cwd = str_param(&params, "cwd").map(PathBuf::from).unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
            let meta = mux_meta(&params);
            let agent = meta
                .and_then(|m| m.get("agent"))
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| params.get("agent").and_then(Value::as_str).map(str::to_owned));
            let agent = match agent {
                Some(a) => a,
                None => hub
                    .config
                    .read()
                    .await
                    .default_agent
                    .clone()
                    .ok_or_else(|| RpcError::invalid_params("no agents configured; add one to config.json"))?,
            };
            let name = meta
                .and_then(|m| m.get("name"))
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| params.get("name").and_then(Value::as_str).map(str::to_owned));
            let policy = meta
                .and_then(|m| m.get("policy"))
                .and_then(Value::as_str)
                .or_else(|| params.get("policy").and_then(Value::as_str))
                .map(|p| p.parse::<PermissionPolicy>().map_err(RpcError::invalid_params))
                .transpose()?;
            let s = hub.new_session(&agent, name, cwd, policy).await?;
            conn.subscribe(&s.id);
            let meta = s.meta();
            Ok(json!({
                "sessionId": s.id,
                "modes": meta.modes,
                "configOptions": meta.config_options,
                "_meta": {"acpmux": hub.session_summary(&s)},
            }))
        }
        method::SESSION_LOAD | method::SESSION_RESUME => {
            let s = hub.resolve(session_key(&params)?)?;
            conn.subscribe(&s.id);
            // Replay history as ACP updates, then answer.
            let events = hub.events(&s.id, 0, 100_000).map_err(|e| RpcError::internal(e.to_string()))?;
            for rec in events {
                if rec.dir == "mux" && rec.kind == "user_message" {
                    let text = rec.msg.get("text").and_then(Value::as_str).unwrap_or("");
                    conn.send(&Message::notification(
                        method::SESSION_UPDATE,
                        json!({"sessionId": s.id, "update": {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": text}}, "_meta": {"acpmux": {"seq": rec.seq, "at": rec.at, "replay": true}}}),
                    ));
                } else if rec.dir == "in" && !rec.kind.ends_with(".replay") {
                    if rec.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE) {
                        let mut p = rec.msg.get("params").cloned().unwrap_or(json!({}));
                        p["sessionId"] = Value::String(s.id.clone());
                        p["_meta"] = json!({"acpmux": {"seq": rec.seq, "at": rec.at, "replay": true}});
                        conn.send(&Message::notification(method::SESSION_UPDATE, p));
                    }
                }
            }
            let meta = s.meta();
            Ok(json!({"modes": meta.modes, "configOptions": meta.config_options, "_meta": {"acpmux": hub.session_summary(&s)}}))
        }
        method::SESSION_LIST => {
            let sessions: Vec<Value> = hub
                .all_session_summaries()
                .into_iter()
                .map(|s| {
                    json!({
                        "sessionId": s.get("sessionId").cloned().unwrap_or(Value::Null),
                        "cwd": s.get("cwd").cloned().unwrap_or(Value::Null),
                        "title": s.get("title").and_then(Value::as_str).map(str::to_owned).or_else(|| s.get("name").and_then(Value::as_str).map(str::to_owned)),
                        "updatedAt": iso(s.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)),
                        "_meta": {"acpmux": s},
                    })
                })
                .collect();
            Ok(json!({"sessions": sessions}))
        }
        method::SESSION_PROMPT => {
            let s = hub.resolve(session_key(&params)?)?;
            conn.subscribe(&s.id);
            let blocks = params
                .get("prompt")
                .and_then(Value::as_array)
                .cloned()
                .or_else(|| params.get("text").and_then(Value::as_str).map(|t| vec![json!({"type": "text", "text": t})]))
                .ok_or_else(|| RpcError::invalid_params("prompt must be an array of content blocks"))?;
            let steer = mux_meta(&params)
                .and_then(|m| m.get("steer"))
                .and_then(Value::as_bool)
                .or_else(|| params.get("steer").and_then(Value::as_bool))
                .unwrap_or(false);
            hub.prompt(&s, blocks, &conn.label(), steer).await
        }
        method::SESSION_FORK => {
            let s = hub.resolve(session_key(&params)?)?;
            let cwd = str_param(&params, "cwd").map(PathBuf::from);
            let name = mux_meta(&params)
                .and_then(|m| m.get("name"))
                .and_then(Value::as_str)
                .or_else(|| params.get("name").and_then(Value::as_str))
                .map(str::to_owned);
            let new = hub.fork(&s, name, cwd).await?;
            conn.subscribe(&new.id);
            let meta = new.meta();
            Ok(json!({"sessionId": new.id, "modes": meta.modes, "configOptions": meta.config_options, "_meta": {"acpmux": hub.session_summary(&new)}}))
        }
        method::SESSION_SET_MODE => {
            let s = hub.resolve(session_key(&params)?)?;
            let mode = str_param(&params, "modeId").ok_or_else(|| RpcError::invalid_params("modeId is required"))?;
            hub.set_mode(&s, mode).await
        }
        method::SESSION_SET_CONFIG_OPTION => {
            let s = hub.resolve(session_key(&params)?)?;
            let id = str_param(&params, "configId").ok_or_else(|| RpcError::invalid_params("configId is required"))?;
            let value = params.get("value").cloned().ok_or_else(|| RpcError::invalid_params("value is required"))?;
            hub.set_config(&s, id, value).await
        }
        method::SESSION_SET_MODEL => {
            let s = hub.resolve(session_key(&params)?)?;
            let model = str_param(&params, "modelId").ok_or_else(|| RpcError::invalid_params("modelId is required"))?;
            hub.set_model(&s, model).await
        }
        method::SESSION_CLOSE => {
            let s = hub.resolve(session_key(&params)?)?;
            hub.kill(&s, false).await?;
            Ok(json!({}))
        }
        method::SESSION_DELETE => {
            let s = hub.resolve(session_key(&params)?)?;
            hub.kill(&s, true).await?;
            Ok(json!({}))
        }
        // ------------------------------------------------ acpmux extensions
        method::MUX_STATUS => Ok(hub.status().await),
        method::MUX_SESSIONS => Ok(json!({"sessions": hub.all_session_summaries()})),
        "_acpmux/peers" => Ok(json!({"peers": hub.peers()})),
        "_acpmux/models" => {
            let mut cat = hub.models_catalog().await;
            // Remote harnesses, labelled peer/agent, from each connected peer.
            for peer in hub.connected_peers() {
                if let Ok(remote) = peer.request("_acpmux/models", json!({})).await {
                    if let Some(hs) = remote.get("harnesses").and_then(Value::as_array) {
                        for h in hs {
                            let mut h = h.clone();
                            let agent = h.get("agent").and_then(Value::as_str).unwrap_or("").to_owned();
                            h["agent"] = Value::String(format!("{}/{}", peer.name, agent));
                            h["peer"] = Value::String(peer.name.clone());
                            h["isDefault"] = Value::Bool(false);
                            if let Some(arr) = cat.get_mut("harnesses").and_then(Value::as_array_mut) {
                                arr.push(h);
                            }
                        }
                    }
                }
            }
            Ok(cat)
        }
        "_acpmux/peer_add" => {
            let name = str_param(&params, "name").ok_or_else(|| RpcError::invalid_params("name is required"))?;
            let url = str_param(&params, "url").ok_or_else(|| RpcError::invalid_params("url is required"))?;
            let token = str_param(&params, "token").map(str::to_owned);
            hub.add_peer(name, url, token).await?;
            Ok(json!({"peers": hub.peers()}))
        }
        "_acpmux/peer_remove" => {
            let name = str_param(&params, "name").ok_or_else(|| RpcError::invalid_params("name is required"))?;
            hub.remove_peer(name).await?;
            Ok(json!({"peers": hub.peers()}))
        }
        method::MUX_AGENTS => {
            let cfg = hub.config.read().await;
            Ok(json!({"agents": cfg.agents, "defaultAgent": cfg.default_agent}))
        }
        method::MUX_INFO => {
            let s = hub.resolve(session_key(&params)?)?;
            Ok(hub.session_detail(&s))
        }
        method::MUX_ATTACH => {
            let s = hub.resolve(session_key(&params)?)?;
            conn.subscribe(&s.id);
            let after = params.get("afterSeq").and_then(Value::as_u64);
            let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(2000) as usize;
            let detail = hub.session_detail(&s);
            let events = match after {
                Some(a) => hub.events(&s.id, a, limit).map_err(|e| RpcError::internal(e.to_string()))?,
                None => {
                    // Last `limit` records.
                    let last = s.meta().last_seq;
                    let from = last.saturating_sub(limit as u64);
                    hub.events(&s.id, from, limit).map_err(|e| RpcError::internal(e.to_string()))?
                }
            };
            let events: Vec<Value> = events.iter().map(|r| event_value(&s.id, r)).collect();
            Ok(json!({"session": detail, "events": events}))
        }
        method::MUX_DETACH => {
            let s = hub.resolve(session_key(&params)?)?;
            conn.subs.lock().unwrap().remove(&s.id);
            Ok(json!({}))
        }
        method::MUX_WATCH => {
            let on = params.get("enabled").and_then(Value::as_bool).unwrap_or(true);
            conn.watch_all.store(on, Ordering::SeqCst);
            Ok(json!({"sessions": hub.all_session_summaries()}))
        }
        method::MUX_EVENTS => {
            let s = hub.resolve(session_key(&params)?)?;
            let after = params.get("afterSeq").and_then(Value::as_u64).unwrap_or(0);
            let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(5000) as usize;
            let events = hub.events(&s.id, after, limit).map_err(|e| RpcError::internal(e.to_string()))?;
            Ok(json!({"events": events.iter().map(|r| event_value(&s.id, r)).collect::<Vec<_>>()}))
        }
        method::MUX_RENAME => {
            let s = hub.resolve(session_key(&params)?)?;
            let name = str_param(&params, "newName").or_else(|| str_param(&params, "to")).ok_or_else(|| RpcError::invalid_params("newName is required"))?;
            crate::session_name::validate(name).map_err(RpcError::invalid_params)?;
            hub.rename(&s, name.to_owned()).await?;
            Ok(hub.session_summary(&s))
        }
        method::MUX_KILL => {
            let s = hub.resolve(session_key(&params)?)?;
            let purge = params.get("purge").and_then(Value::as_bool).unwrap_or(false);
            hub.kill(&s, purge).await?;
            Ok(json!({"sessionId": s.id, "purged": purge}))
        }
        method::MUX_PERMISSION_RESPOND => {
            let s = hub.resolve(session_key(&params)?)?;
            let pid = str_param(&params, "permissionId").ok_or_else(|| RpcError::invalid_params("permissionId is required"))?;
            let option = str_param(&params, "optionId").map(str::to_owned);
            let answers = params.get("answers").cloned();
            hub.respond_permission(&s, pid, option, answers)?;
            Ok(json!({}))
        }
        method::MUX_SET_POLICY => {
            let s = hub.resolve(session_key(&params)?)?;
            let policy: PermissionPolicy = str_param(&params, "policy")
                .ok_or_else(|| RpcError::invalid_params("policy is required"))?
                .parse()
                .map_err(RpcError::invalid_params)?;
            hub.set_policy(&s, policy).await;
            Ok(hub.session_summary(&s))
        }
        method::MUX_EXPORT => {
            let s = hub.resolve(session_key(&params)?)?;
            let dest = str_param(&params, "dest").map(PathBuf::from).unwrap_or_else(|| crate::config::home().join("bundles"));
            let path = hub.export(&s, &dest).map_err(|e| RpcError::internal(e.to_string()))?;
            Ok(json!({"path": path}))
        }
        method::MUX_IMPORT => {
            let path = str_param(&params, "path").map(PathBuf::from).ok_or_else(|| RpcError::invalid_params("path is required"))?;
            let name = str_param(&params, "name").map(str::to_owned);
            let s = hub.import(&path, name).await?;
            conn.subscribe(&s.id);
            Ok(hub.session_summary(&s))
        }
        method::MUX_SHUTDOWN => {
            hub.shutdown.notify_waiters();
            hub.shutdown.notify_one();
            Ok(json!({}))
        }
        // Anything else that names a session goes to the agent untouched.
        other => {
            if let Ok(key) = session_key(&params) {
                let s = hub.resolve(key)?;
                return hub.forward(&s, other, params).await;
            }
            Err(RpcError::method_not_found(other))
        }
    }
}
