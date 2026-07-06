use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use serde_json::{json, Value};
use tungstenite::client::IntoClientRequest;
use tungstenite::{client, Error as WsError, Message, WebSocket};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreencastFrame {
    pub session_id: String,
    pub data_b64: String,
    pub css_width: u32,
    pub css_height: u32,
    pub ack_id: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TargetInfo {
    pub session_id: Option<String>,
    pub target_id: String,
    pub title: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TargetCreated {
    pub target_id: String,
    pub opener_id: Option<String>,
    pub target_type: String,
    pub title: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NavigationEntry {
    pub id: u64,
    pub url: String,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NavigationHistory {
    pub current_index: usize,
    pub entries: Vec<NavigationEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CdpEvent {
    ScreencastFrame(ScreencastFrame),
    TargetCreated(TargetCreated),
    TargetInfoChanged(TargetInfo),
    Other { method: String, params: Value, session_id: Option<String> },
    Closed(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CdpKeyEvent<'a> {
    pub event_type: &'a str,
    pub key: &'a str,
    pub code: &'a str,
    pub windows_virtual_key_code: u32,
    pub modifiers: u32,
    pub text: Option<&'a str>,
}

fn cdp_debug() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("CMUX_MUX_CDP_DEBUG").is_some())
}

#[derive(Clone)]
pub struct CdpClient {
    inner: Arc<Inner>,
}

struct Inner {
    ws: Mutex<WebSocket<TcpStream>>,
    pending: Mutex<HashMap<u64, Sender<Result<Value, String>>>>,
    events: Sender<CdpEvent>,
    next_id: AtomicU64,
    closed: AtomicBool,
    timeout: Duration,
}

impl CdpClient {
    pub fn connect(web_socket_url: &str, events: Sender<CdpEvent>) -> anyhow::Result<Self> {
        let endpoint = WsEndpoint::parse(web_socket_url)?;
        let mut addrs = (endpoint.host.as_str(), endpoint.port).to_socket_addrs()?;
        let addr = addrs.next().ok_or_else(|| {
            anyhow::anyhow!("no socket address for {}:{}", endpoint.host, endpoint.port)
        })?;
        let stream = TcpStream::connect_timeout(&addr, Duration::from_secs(5))?;
        stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        let request = web_socket_url.into_client_request()?;
        let (ws, _) = client(request, stream)?;
        // The reader loop holds the ws mutex for the whole read poll
        // (sync tungstenite cannot split read/write halves), so this
        // window is also the worst-case wait for every outgoing call.
        // Keep it short: writers stall at most ~20ms, and the idle
        // wakeup cost (one timed-out read per window) is negligible.
        ws.get_ref().set_read_timeout(Some(Duration::from_millis(20)))?;
        ws.get_ref().set_write_timeout(Some(Duration::from_secs(5)))?;
        let client = CdpClient {
            inner: Arc::new(Inner {
                ws: Mutex::new(ws),
                pending: Mutex::new(HashMap::new()),
                events,
                next_id: AtomicU64::new(1),
                closed: AtomicBool::new(false),
                timeout: Duration::from_secs(30),
            }),
        };
        client.spawn_reader()?;
        Ok(client)
    }

    fn spawn_reader(&self) -> anyhow::Result<()> {
        let weak = Arc::downgrade(&self.inner);
        std::thread::Builder::new().name("mux-cdp-reader".into()).spawn(move || {
            reader_loop(weak);
        })?;
        Ok(())
    }

    /// JSON-RPC call. Page-scoped commands pass a flat-session
    /// `session_id`, which is emitted as the top-level CDP `sessionId`.
    pub fn call(
        &self,
        method: &str,
        params: Value,
        session_id: Option<&str>,
    ) -> anyhow::Result<Value> {
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = channel();
        self.inner.pending.lock().unwrap().insert(id, tx);

        let mut msg = json!({
            "id": id,
            "method": method,
            "params": params,
        });
        if let Some(session_id) = session_id {
            msg["sessionId"] = json!(session_id);
        }
        if let Err(e) = self.send_value(&msg) {
            self.inner.pending.lock().unwrap().remove(&id);
            return Err(e);
        }

        match rx.recv_timeout(self.inner.timeout) {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(e)) => anyhow::bail!("{e}"),
            Err(_) => {
                self.inner.pending.lock().unwrap().remove(&id);
                anyhow::bail!("CDP call {method} timed out")
            }
        }
    }

    pub fn set_discover_targets(&self, discover: bool) -> anyhow::Result<()> {
        self.call("Target.setDiscoverTargets", json!({ "discover": discover }), None).map(|_| ())
    }

    pub fn create_target(&self, url: &str) -> anyhow::Result<String> {
        let result = self.call("Target.createTarget", json!({ "url": url }), None)?;
        result
            .get("targetId")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or_else(|| anyhow::anyhow!("Target.createTarget response missing targetId"))
    }

    pub fn attach_to_target(&self, target_id: &str) -> anyhow::Result<String> {
        let result = self.call(
            "Target.attachToTarget",
            json!({ "targetId": target_id, "flatten": true }),
            None,
        )?;
        result
            .get("sessionId")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or_else(|| anyhow::anyhow!("Target.attachToTarget response missing sessionId"))
    }

    pub fn close_target(&self, target_id: &str) -> anyhow::Result<()> {
        self.call("Target.closeTarget", json!({ "targetId": target_id }), None).map(|_| ())
    }

    pub fn page_enable(&self, session_id: &str) -> anyhow::Result<()> {
        self.call("Page.enable", json!({}), Some(session_id)).map(|_| ())
    }

    pub fn start_screencast(
        &self,
        session_id: &str,
        max_width: u32,
        max_height: u32,
    ) -> anyhow::Result<()> {
        self.call(
            "Page.startScreencast",
            json!({
                "format": "png",
                "maxWidth": max_width,
                "maxHeight": max_height,
                "everyNthFrame": 1,
            }),
            Some(session_id),
        )
        .map(|_| ())
    }

    pub fn stop_screencast(&self, session_id: &str) -> anyhow::Result<()> {
        self.call("Page.stopScreencast", json!({}), Some(session_id)).map(|_| ())
    }

    pub fn navigate(&self, session_id: &str, url: &str) -> anyhow::Result<Option<String>> {
        let result = self.call("Page.navigate", json!({ "url": url }), Some(session_id))?;
        Ok(result
            .get("errorText")
            .and_then(|value| value.as_str())
            .filter(|error| !error.is_empty())
            .map(ToOwned::to_owned))
    }

    pub fn navigation_history(&self, session_id: &str) -> anyhow::Result<NavigationHistory> {
        let result = self.call("Page.getNavigationHistory", json!({}), Some(session_id))?;
        let current_index = result
            .get("currentIndex")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| anyhow::anyhow!("Page.getNavigationHistory missing currentIndex"))?
            as usize;
        let entries = result
            .get("entries")
            .and_then(|v| v.as_array())
            .ok_or_else(|| anyhow::anyhow!("Page.getNavigationHistory missing entries"))?
            .iter()
            .filter_map(|entry| {
                Some(NavigationEntry {
                    id: entry.get("id")?.as_u64()?,
                    url: entry.get("url").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
                    title: entry
                        .get("title")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default()
                        .to_string(),
                })
            })
            .collect();
        Ok(NavigationHistory { current_index, entries })
    }

    pub fn navigate_to_history_entry(&self, session_id: &str, entry_id: u64) -> anyhow::Result<()> {
        self.call("Page.navigateToHistoryEntry", json!({ "entryId": entry_id }), Some(session_id))
            .map(|_| ())
    }

    pub fn reload(&self, session_id: &str) -> anyhow::Result<()> {
        self.call("Page.reload", json!({}), Some(session_id)).map(|_| ())
    }

    pub fn activate_target(&self, target_id: &str, session_id: &str) -> anyhow::Result<()> {
        self.call("Target.activateTarget", json!({ "targetId": target_id }), None)?;
        let _ = self.call("Page.bringToFront", json!({}), Some(session_id));
        Ok(())
    }

    pub fn handle_javascript_dialog(&self, session_id: &str, accept: bool) -> anyhow::Result<()> {
        self.call("Page.handleJavaScriptDialog", json!({ "accept": accept }), Some(session_id))
            .map(|_| ())
    }

    pub fn set_device_metrics(
        &self,
        session_id: &str,
        width: u32,
        height: u32,
    ) -> anyhow::Result<()> {
        self.call(
            "Emulation.setDeviceMetricsOverride",
            json!({
                "width": width.max(1),
                "height": height.max(1),
                "deviceScaleFactor": 1,
                "mobile": false,
            }),
            Some(session_id),
        )
        .map(|_| ())
    }

    pub fn dispatch_mouse_event(
        &self,
        session_id: &str,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
    ) -> anyhow::Result<()> {
        let mut params = json!({
            "type": event_type,
            "x": x,
            "y": y,
        });
        if let Some(button) = button {
            params["button"] = json!(button);
        }
        if let Some(click_count) = click_count {
            params["clickCount"] = json!(click_count);
        }
        self.call("Input.dispatchMouseEvent", params, Some(session_id)).map(|_| ())
    }

    pub fn dispatch_wheel(
        &self,
        session_id: &str,
        x: f64,
        y: f64,
        delta_y: f64,
    ) -> anyhow::Result<()> {
        self.call(
            "Input.dispatchMouseEvent",
            json!({
                "type": "mouseWheel",
                "x": x,
                "y": y,
                "deltaX": 0,
                "deltaY": delta_y,
            }),
            Some(session_id),
        )
        .map(|_| ())
    }

    pub fn dispatch_key_event(
        &self,
        session_id: &str,
        event: CdpKeyEvent<'_>,
    ) -> anyhow::Result<()> {
        let mut params = json!({
            "type": event.event_type,
            "key": event.key,
            "code": event.code,
            "windowsVirtualKeyCode": event.windows_virtual_key_code,
            "nativeVirtualKeyCode": event.windows_virtual_key_code,
            "modifiers": event.modifiers,
        });
        if let Some(text) = event.text {
            params["text"] = json!(text);
            params["unmodifiedText"] = json!(text);
        }
        self.call("Input.dispatchKeyEvent", params, Some(session_id)).map(|_| ())
    }

    pub fn insert_text(&self, session_id: &str, text: &str) -> anyhow::Result<()> {
        self.call("Input.insertText", json!({ "text": text }), Some(session_id)).map(|_| ())
    }

    fn send_value(&self, value: &Value) -> anyhow::Result<()> {
        if self.inner.closed.load(Ordering::Acquire) {
            anyhow::bail!("CDP connection is closed");
        }
        let text = serde_json::to_string(value)?;
        if cdp_debug() {
            eprintln!("cdp-> {text}");
        }
        let mut ws = self.inner.ws.lock().unwrap();
        ws.send(Message::Text(text))?;
        Ok(())
    }
}

pub fn resolve_browser_ws_url(input: &str) -> anyhow::Result<String> {
    let trimmed = input.trim();
    if trimmed.starts_with("ws://") {
        return Ok(trimmed.to_string());
    }
    if trimmed.starts_with("http://") {
        let endpoint = HttpEndpoint::parse(trimmed)?;
        return fetch_json_version(&endpoint.host, endpoint.port);
    }
    anyhow::bail!("CDP URL must start with ws:// or http://, got {input:?}")
}

pub fn discover_browser_ws_url(ports: &[u16]) -> Option<String> {
    ports.iter().find_map(|port| fetch_json_version("127.0.0.1", *port).ok())
}

fn reader_loop(weak: Weak<Inner>) {
    loop {
        let Some(inner) = weak.upgrade() else { break };
        if inner.closed.load(Ordering::Acquire) {
            break;
        }
        let message = {
            let mut ws = inner.ws.lock().unwrap();
            ws.read()
        };
        match message {
            Ok(Message::Text(text)) => handle_text(&inner, &text),
            Ok(Message::Binary(bytes)) => {
                if let Ok(text) = String::from_utf8(bytes) {
                    handle_text(&inner, &text);
                }
            }
            Ok(Message::Close(_)) => {
                close_inner(&inner, "CDP socket closed");
                break;
            }
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) | Ok(Message::Frame(_)) => {}
            Err(WsError::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(e) => {
                close_inner(&inner, &format!("CDP socket error: {e}"));
                break;
            }
        }
    }
}

fn handle_text(inner: &Arc<Inner>, text: &str) {
    if cdp_debug() {
        eprintln!("cdp<- {}", &text[..text.len().min(300)]);
    }
    let Ok(value) = serde_json::from_str::<Value>(text) else { return };
    if let Some(id) = value.get("id").and_then(|v| v.as_u64()) {
        if let Some(tx) = inner.pending.lock().unwrap().remove(&id) {
            let response = if let Some(error) = value.get("error") {
                Err(error.to_string())
            } else {
                Ok(value.get("result").cloned().unwrap_or(Value::Null))
            };
            let _ = tx.send(response);
        }
        return;
    }

    let Some(method) = value.get("method").and_then(|v| v.as_str()) else { return };
    let params = value.get("params").cloned().unwrap_or(Value::Null);
    let session_id = value.get("sessionId").and_then(|v| v.as_str()).map(str::to_string);
    match method {
        "Page.screencastFrame" => {
            if let Some(target_session) = session_id.as_deref() {
                let Some(frame) = screencast_frame(&params, target_session) else { return };
                ack_screencast_frame(inner, target_session, frame.ack_id);
                let _ = inner.events.send(CdpEvent::ScreencastFrame(frame));
            }
        }
        "Target.targetCreated" => {
            if let Some(created) = target_created(&params) {
                let _ = inner.events.send(CdpEvent::TargetCreated(created));
            }
        }
        "Target.targetInfoChanged" => {
            if let Some(info) = target_info(&params, session_id.as_deref()) {
                let _ = inner.events.send(CdpEvent::TargetInfoChanged(info));
            }
        }
        _ => {
            let _ = inner.events.send(CdpEvent::Other {
                method: method.to_string(),
                params,
                session_id,
            });
        }
    }
}

fn ack_screencast_frame(inner: &Arc<Inner>, target_session: &str, frame_session: u64) {
    let id = inner.next_id.fetch_add(1, Ordering::Relaxed);
    let msg = json!({
        "id": id,
        "method": "Page.screencastFrameAck",
        "sessionId": target_session,
        "params": { "sessionId": frame_session },
    });
    let Ok(text) = serde_json::to_string(&msg) else { return };
    let _ = inner.ws.lock().unwrap().send(Message::Text(text));
}

fn screencast_frame(params: &Value, session_id: &str) -> Option<ScreencastFrame> {
    let data_b64 = params.get("data")?.as_str()?.to_string();
    let ack_id = params.get("sessionId")?.as_u64()?;
    let metadata = params.get("metadata").unwrap_or(&Value::Null);
    let css_width = metadata
        .get("deviceWidth")
        .and_then(|v| v.as_u64())
        .or_else(|| metadata.get("width").and_then(|v| v.as_u64()))
        .unwrap_or(0) as u32;
    let css_height = metadata
        .get("deviceHeight")
        .and_then(|v| v.as_u64())
        .or_else(|| metadata.get("height").and_then(|v| v.as_u64()))
        .unwrap_or(0) as u32;
    Some(ScreencastFrame {
        session_id: session_id.to_string(),
        data_b64,
        css_width,
        css_height,
        ack_id,
    })
}

fn target_info(params: &Value, session_id: Option<&str>) -> Option<TargetInfo> {
    let info = params.get("targetInfo")?;
    Some(TargetInfo {
        session_id: session_id.map(str::to_string),
        target_id: info.get("targetId")?.as_str()?.to_string(),
        title: info.get("title").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
        url: info.get("url").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
    })
}

fn target_created(params: &Value) -> Option<TargetCreated> {
    let info = params.get("targetInfo")?;
    Some(TargetCreated {
        target_id: info.get("targetId")?.as_str()?.to_string(),
        opener_id: info.get("openerId").and_then(|v| v.as_str()).map(str::to_string),
        target_type: info.get("type").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
        title: info.get("title").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
        url: info.get("url").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
    })
}

fn close_inner(inner: &Arc<Inner>, why: &str) {
    if inner.closed.swap(true, Ordering::AcqRel) {
        return;
    }
    for (_, tx) in inner.pending.lock().unwrap().drain() {
        let _ = tx.send(Err(why.to_string()));
    }
    let _ = inner.events.send(CdpEvent::Closed(why.to_string()));
}

struct WsEndpoint {
    host: String,
    port: u16,
}

struct HttpEndpoint {
    host: String,
    port: u16,
}

impl HttpEndpoint {
    fn parse(url: &str) -> anyhow::Result<Self> {
        let rest = url
            .strip_prefix("http://")
            .ok_or_else(|| anyhow::anyhow!("CDP discovery URL must be http://, got {url:?}"))?;
        let host_port = rest.split('/').next().unwrap_or(rest);
        let (host, port) = match host_port.rsplit_once(':') {
            Some((host, port)) => (host, port.parse::<u16>()?),
            None => (host_port, 80),
        };
        Ok(HttpEndpoint { host: host.trim_matches(['[', ']']).to_string(), port })
    }
}

fn fetch_json_version(host: &str, port: u16) -> anyhow::Result<String> {
    let mut addrs = (host, port).to_socket_addrs()?;
    let addr =
        addrs.next().ok_or_else(|| anyhow::anyhow!("no socket address for {host}:{port}"))?;
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(250))?;
    stream.set_read_timeout(Some(Duration::from_millis(500)))?;
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;
    write!(
        stream,
        "GET /json/version HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n\r\n"
    )?;
    stream.flush()?;
    let response = read_http_response(&mut stream)?;
    let body = response
        .split_once("\r\n\r\n")
        .map(|(_, body)| body)
        .ok_or_else(|| anyhow::anyhow!("bad /json/version response from {host}:{port}"))?;
    let value: Value = serde_json::from_str(body)?;
    value
        .get("webSocketDebuggerUrl")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .ok_or_else(|| anyhow::anyhow!("/json/version missing webSocketDebuggerUrl"))
}

fn read_http_response(stream: &mut TcpStream) -> anyhow::Result<String> {
    let mut bytes = Vec::new();
    let mut buf = [0u8; 1024];
    loop {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                bytes.extend_from_slice(&buf[..n]);
                if complete_http_response(&bytes) {
                    break;
                }
            }
            Err(e) if !bytes.is_empty() && e.kind() == std::io::ErrorKind::ConnectionReset => {
                break;
            }
            Err(e) => return Err(e.into()),
        }
    }
    Ok(String::from_utf8(bytes)?)
}

fn complete_http_response(bytes: &[u8]) -> bool {
    let Some(header_end) = bytes.windows(4).position(|window| window == b"\r\n\r\n") else {
        return false;
    };
    let headers = String::from_utf8_lossy(&bytes[..header_end]);
    let Some(content_len) = headers.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.eq_ignore_ascii_case("content-length").then(|| value.trim().parse::<usize>().ok())?
    }) else {
        return false;
    };
    bytes.len() >= header_end + 4 + content_len
}

impl WsEndpoint {
    fn parse(url: &str) -> anyhow::Result<Self> {
        let rest = url.strip_prefix("ws://").ok_or_else(|| {
            anyhow::anyhow!("CDP endpoint must be an unencrypted ws:// URL, got {url:?}")
        })?;
        let host_port = rest.split('/').next().unwrap_or(rest);
        let (host, port) = match host_port.rsplit_once(':') {
            Some((host, port)) => (host, port.parse::<u16>()?),
            None => (host_port, 80),
        };
        Ok(WsEndpoint { host: host.trim_matches(['[', ']']).to_string(), port })
    }
}
