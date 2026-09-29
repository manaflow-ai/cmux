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
    fn subscribe(&self, session_id: &str) -> bool {
        self.subs.lock().unwrap().insert(session_id.to_owned())
    }
    fn unsubscribe(&self, session_id: &str) -> bool {
        self.subs.lock().unwrap().remove(session_id)
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

const INDEX_HTML: &str = include_str!("../../web/index.html");

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
                    if let tokio_tungstenite::tungstenite::Message::Text(t) = frame
                        && in_tx.send(t.to_string()).await.is_err() {
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
    // Every attachment this connection held ends with it.
    let subs: Vec<String> = conn.subs.lock().unwrap().drain().collect();
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
    let attached = conn.subscribed(&ev.session_id);
    if !watching && !attached {
        return;
    }
    if attached && rec.dir != "peer" {
        // Agent -> client updates as standard ACP notifications.
        if rec.dir == "in" && !rec.kind.ends_with(".replay")
            && let Some(m) = rec.msg.get("method").and_then(Value::as_str)
                && m == method::SESSION_UPDATE {
                    let mut params = rec.msg.get("params").cloned().unwrap_or(json!({}));
                    params["sessionId"] = Value::String(ev.session_id.clone());
                    params["_meta"] = json!({"acpmux": {"seq": rec.seq, "at": rec.at}});
                    conn.send(&Message::notification(method::SESSION_UPDATE, params));
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
        if rec.dir == "mux" && rec.kind == "purged" {
            conn.send(&Message::notification(method::MUX_SESSION_CHANGED, json!({"session": {"sessionId": ev.session_id}, "kind": "purged", "seq": rec.seq})));
            return;
        }
        if rec.dir == "mux"
            && matches!(
                rec.kind.as_str(),
                "status" | "created" | "user_message" | "turn_end" | "turn_error" | "renamed" | "forked" | "imported" | "permission_request" | "permission_decision" | "mode" | "model" | "config" | "policy" | "rules" | "tags" | "turn_started" | "turn_result"
            )
            && let Ok(s) = hub.resolve(&ev.session_id) {
                conn.send(&Message::notification(
                    method::MUX_SESSION_CHANGED,
                    json!({"session": hub.session_summary(&s), "kind": rec.kind, "seq": rec.seq}),
                ));
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

fn mux_meta(params: &Value) -> Option<&Value> {
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

mod requests;
mod wait;
use requests::{handle_notification, handle_request};
