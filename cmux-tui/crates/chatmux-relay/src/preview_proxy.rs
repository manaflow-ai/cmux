//! Relay-owned preview proxy (relay wire v6 `preview_open` /
//! `preview_console_tail`; pinned contract in chatmux
//! pane-primitives-plan.md "Preview proxy contract"):
//!
//! - reverse proxy of the target dev-server port, streaming, with
//!   `<script src="/__chatmux__/target.js"></script>` injected into
//!   text/html responses (before `</head>`, else at the start of `<body>`;
//!   skipped when `x-chatmux-no-inject: 1` rides the request or response);
//! - GET  /__chatmux__/target.js  -> vendored chobitsu bundle + connector;
//! - WS   /__chatmux__/page       -> the inspected page's CDP frames;
//! - WS   /__chatmux__/devtools   -> the DevTools frontend; the proxy pipes
//!   page<->devtools frames; one page target (latest page connection wins,
//!   the earlier one gets a close frame);
//! - GET  /__chatmux__/status     -> {"targetConnected": bool}, answering
//!   credentialed cross-origin fetches (ACAO=<origin> + ACAC=true — the
//!   web devtools drawer polls it cross-origin and hangs without this);
//! - console/network CDP events tee into a bounded ring served by the
//!   `preview_console_tail` verb (Pi-readable).

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::Value;

use crate::relay_wire as wire;
use crate::workspace::{Refusal, cap_utf16};

/// Vendored chobitsu (CDP-in-page) bundle. Version: 1.8.6, from
/// https://registry.npmjs.org/chobitsu/-/chobitsu-1.8.6.tgz (dist/
/// chobitsu.js, sha256 fa64f74311def21dce25f048fa66d2ef74edcdf6f6978bcd2a
/// 3bbf0ee2bb2795). Never edit; re-vendor to upgrade.
const CHOBITSU_JS: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/chobitsu.js"));
const CONNECTOR_JS: &str =
    include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/assets/preview-connector.js"));

fn target_js() -> &'static str {
    static BUNDLE: OnceLock<String> = OnceLock::new();
    BUNDLE.get_or_init(|| format!("{CHOBITSU_JS}\n;\n{CONNECTOR_JS}\n"))
}

/// preview_console_tail ring bounds (WORKSPACE_CONSOLE_* in chatmux
/// packages/protocol).
pub const CONSOLE_MAX_EVENTS: usize = 500;
pub const CONSOLE_MAX_TEXT_UNITS: usize = 4_000;
const NETWORK_URL_MAX_UNITS: usize = 2_048;
const NETWORK_METHOD_MAX_UNITS: usize = 16;
/// Most in-flight network requests remembered while their response is
/// pending (requestWillBeSent -> responseReceived/loadingFailed join).
const PENDING_REQUEST_CAP: usize = 512;
/// Bound browser/devtools CDP messages before tungstenite allocates them.
const PREVIEW_WS_MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;
/// Limit queued frames per peer. A browser/devtools socket that stops
/// reading must not make the relay retain an unbounded stream of CDP data.
const PREVIEW_WS_QUEUE_CAPACITY: usize = 64;
const PREVIEW_WS_QUEUE_BYTES: usize = 64 * 1024 * 1024;
/// Maximum number of target-port listeners retained by one relay.
/// Opening another target evicts the least-recently-used listener.
pub const PREVIEW_PROXY_CAP: usize = 32;

/// CDP command ids the proxy mints for its own enables; responses with
/// these ids are swallowed instead of piped to the DevTools frontend.
const PROXY_CDP_ID_BASE: i64 = 900_000_000;

// ---------------------------------------------------------------------------
// Console/network ring (shared by every proxy; one page target in v1)
// ---------------------------------------------------------------------------

struct RingInner {
    events: VecDeque<wire::PreviewEvent>,
    dropped: i64,
    pending: HashMap<String, (String, String)>,
    pending_order: VecDeque<String>,
}

pub struct ConsoleRing {
    inner: Mutex<RingInner>,
}

impl ConsoleRing {
    fn new() -> ConsoleRing {
        ConsoleRing {
            inner: Mutex::new(RingInner {
                events: VecDeque::new(),
                dropped: 0,
                pending: HashMap::new(),
                pending_order: VecDeque::new(),
            }),
        }
    }

    fn push(&self, event: wire::PreviewEvent) {
        let Ok(mut inner) = self.inner.lock() else { return };
        if inner.events.len() >= CONSOLE_MAX_EVENTS {
            inner.events.pop_front();
            inner.dropped += 1;
        }
        inner.events.push_back(event);
    }

    fn remember_request(&self, request_id: String, method: String, url: String) {
        let Ok(mut inner) = self.inner.lock() else { return };
        // A request id can be reused by CDP redirects/retries. Remove its
        // previous queue entry before replacing the map value, otherwise the
        // order deque grows without bound and later eviction can discard the
        // wrong request.
        inner.pending_order.retain(|id| id != &request_id);
        if inner.pending.len() >= PENDING_REQUEST_CAP
            && let Some(oldest) = inner.pending_order.pop_front()
        {
            inner.pending.remove(&oldest);
        }
        inner.pending_order.push_back(request_id.clone());
        inner.pending.insert(request_id, (method, url));
    }

    fn take_request(&self, request_id: &str) -> Option<(String, String)> {
        let Ok(mut inner) = self.inner.lock() else { return None };
        inner.pending_order.retain(|id| id != request_id);
        inner.pending.remove(request_id)
    }

    /// Most recent events, oldest-first, plus the ring's total discard
    /// count.
    fn tail(&self, max_events: usize) -> (Vec<wire::PreviewEvent>, i64) {
        let Ok(inner) = self.inner.lock() else { return (Vec::new(), 0) };
        let skip = inner.events.len().saturating_sub(max_events);
        (inner.events.iter().skip(skip).cloned().collect(), inner.dropped)
    }
}

fn now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as f64)
        .unwrap_or_default()
}

fn console_level(kind: &str) -> wire::PreviewConsoleLevel {
    match kind {
        "debug" => wire::PreviewConsoleLevel::Debug,
        "info" => wire::PreviewConsoleLevel::Info,
        "warning" => wire::PreviewConsoleLevel::Warn,
        "error" | "assert" => wire::PreviewConsoleLevel::Error,
        _ => wire::PreviewConsoleLevel::Log,
    }
}

/// One console argument (a CDP RemoteObject) rendered to text.
fn render_remote_object(argument: &Value) -> String {
    if let Some(value) = argument.get("value") {
        return match value {
            Value::String(text) => text.clone(),
            other => other.to_string(),
        };
    }
    if let Some(text) = argument.get("unserializableValue").and_then(Value::as_str) {
        return text.to_owned();
    }
    if let Some(text) = argument.get("description").and_then(Value::as_str) {
        return text.to_owned();
    }
    argument.get("type").and_then(Value::as_str).unwrap_or("undefined").to_owned()
}

fn cap_units(text: &str, max: usize) -> String {
    cap_utf16(text, max).0.to_owned()
}

/// Tee one page->proxy CDP frame into the ring. Returns the frame's
/// response id when it answers a proxy-minted command (the caller swallows
/// those instead of piping them to DevTools).
fn tee_cdp_frame(ring: &ConsoleRing, raw: &str) -> Option<i64> {
    let frame: Value = serde_json::from_str(raw).ok()?;
    if let Some(id) = frame.get("id").and_then(Value::as_i64) {
        return (id >= PROXY_CDP_ID_BASE).then_some(id);
    }
    let method = frame.get("method").and_then(Value::as_str)?;
    let params = frame.get("params").unwrap_or(&Value::Null);
    match method {
        "Runtime.consoleAPICalled" => {
            let kind = params.get("type").and_then(Value::as_str).unwrap_or("log");
            let empty = Vec::new();
            let arguments = params.get("args").and_then(Value::as_array).unwrap_or(&empty);
            let text = arguments.iter().map(render_remote_object).collect::<Vec<_>>().join(" ");
            ring.push(wire::PreviewEvent::Console(wire::PreviewConsoleEvent {
                kind: wire::TagConsole::Console,
                level: console_level(kind),
                text: cap_units(&text, CONSOLE_MAX_TEXT_UNITS),
                at: now_ms(),
            }));
        }
        "Runtime.exceptionThrown" => {
            let details = params.get("exceptionDetails").unwrap_or(&Value::Null);
            let text = details
                .get("exception")
                .and_then(|exception| exception.get("description"))
                .and_then(Value::as_str)
                .or_else(|| details.get("text").and_then(Value::as_str))
                .unwrap_or("Uncaught exception");
            ring.push(wire::PreviewEvent::Console(wire::PreviewConsoleEvent {
                kind: wire::TagConsole::Console,
                level: wire::PreviewConsoleLevel::Error,
                text: cap_units(text, CONSOLE_MAX_TEXT_UNITS),
                at: now_ms(),
            }));
        }
        "Network.requestWillBeSent" => {
            let request_id = params.get("requestId").and_then(Value::as_str)?;
            let request = params.get("request").unwrap_or(&Value::Null);
            let method = request.get("method").and_then(Value::as_str).unwrap_or("GET");
            let url = request.get("url").and_then(Value::as_str).unwrap_or_default();
            ring.remember_request(
                request_id.to_owned(),
                cap_units(method, NETWORK_METHOD_MAX_UNITS),
                cap_units(url, NETWORK_URL_MAX_UNITS),
            );
        }
        "Network.responseReceived" => {
            let request_id = params.get("requestId").and_then(Value::as_str)?;
            let (method, url) = ring.take_request(request_id)?;
            let status = params
                .get("response")
                .and_then(|response| response.get("status"))
                .and_then(Value::as_i64);
            ring.push(wire::PreviewEvent::Network(wire::PreviewNetworkEvent {
                kind: wire::TagNetwork::Network,
                method,
                url,
                status,
                ok: status.is_some_and(|status| status < 400),
                at: now_ms(),
            }));
        }
        "Network.loadingFailed" => {
            let request_id = params.get("requestId").and_then(Value::as_str)?;
            let (method, url) = ring.take_request(request_id)?;
            ring.push(wire::PreviewEvent::Network(wire::PreviewNetworkEvent {
                kind: wire::TagNetwork::Network,
                method,
                url,
                status: None,
                ok: false,
                at: now_ms(),
            }));
        }
        _ => {}
    }
    None
}

// ---------------------------------------------------------------------------
// Registry: one proxy per target port, alive for the process lifetime
// (reconnects keep the tunnel-exposed proxy port valid)
// ---------------------------------------------------------------------------

pub struct PreviewRegistry {
    ring: Arc<ConsoleRing>,
    proxies: tokio::sync::Mutex<HashMap<i64, ProxyRuntime>>,
    order: tokio::sync::Mutex<VecDeque<i64>>,
}

struct ProxyRuntime {
    port: u16,
    shutdown: tokio::sync::watch::Sender<bool>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for ProxyRuntime {
    fn drop(&mut self) {
        let _ = self.shutdown.send(true);
        self.task.abort();
    }
}

impl Default for PreviewRegistry {
    fn default() -> PreviewRegistry {
        PreviewRegistry::new()
    }
}

impl PreviewRegistry {
    pub fn new() -> PreviewRegistry {
        PreviewRegistry {
            ring: Arc::new(ConsoleRing::new()),
            proxies: tokio::sync::Mutex::new(HashMap::new()),
            order: tokio::sync::Mutex::new(VecDeque::new()),
        }
    }

    /// Start (or reuse) the injecting proxy for one target port; answers
    /// the local port the proxy listens on.
    pub async fn open(&self, target_port: i64) -> Result<wire::WorkspaceResultBody, Refusal> {
        if !(1..=65_535).contains(&target_port) {
            return Err(Refusal::failed(format!("invalid target port {target_port}")));
        }
        let mut proxies = self.proxies.lock().await;
        let proxy_port = match proxies.get(&target_port) {
            Some(runtime) if !runtime.task.is_finished() => runtime.port,
            Some(_) => {
                // The accept loop can terminate on a listener error. Do not
                // hand out the stale port from a finished runtime.
                proxies.remove(&target_port);
                let target = u16::try_from(target_port).unwrap_or_default();
                let runtime = spawn_proxy(target, Arc::clone(&self.ring)).await?;
                let port = runtime.port;
                proxies.insert(target_port, runtime);
                port
            }
            None => {
                let target = u16::try_from(target_port).unwrap_or_default();
                let runtime = spawn_proxy(target, Arc::clone(&self.ring)).await?;
                let port = runtime.port;
                proxies.insert(target_port, runtime);
                let mut order = self.order.lock().await;
                order.retain(|port| *port != target_port);
                order.push_back(target_port);
                if order.len() > PREVIEW_PROXY_CAP
                    && let Some(evicted_port) = order.pop_front()
                    && let Some(mut evicted) = proxies.remove(&evicted_port)
                {
                    let _ = evicted.shutdown.send(true);
                    evicted.task.abort();
                    let _ = (&mut evicted.task).await;
                }
                port
            }
        };
        if proxies.contains_key(&target_port) {
            let mut order = self.order.lock().await;
            order.retain(|port| *port != target_port);
            order.push_back(target_port);
        }
        Ok(wire::WorkspaceResultBody::PreviewOpen(wire::PreviewOpenResult {
            op: wire::TagPreviewOpen::PreviewOpen,
            proxy_port: i64::from(proxy_port),
        }))
    }

    /// Stop all preview listeners and owned connection tasks. Safe to call
    /// repeatedly. This makes registry lifetime explicit for tests and
    /// graceful relay shutdown.
    pub async fn shutdown(&self) {
        let mut proxies = self.proxies.lock().await;
        let runtimes = proxies.drain().map(|(_, runtime)| runtime).collect::<Vec<_>>();
        self.order.lock().await.clear();
        drop(proxies);
        for mut runtime in runtimes {
            let _ = runtime.shutdown.send(true);
            runtime.task.abort();
            let _ = (&mut runtime.task).await;
        }
    }

    pub fn tail(&self, max_events: Option<i64>) -> Result<wire::WorkspaceResultBody, Refusal> {
        let cap = max_events
            .map(|requested| requested.clamp(1, CONSOLE_MAX_EVENTS as i64))
            .map(|requested| usize::try_from(requested).unwrap_or(CONSOLE_MAX_EVENTS))
            .unwrap_or(CONSOLE_MAX_EVENTS);
        let (events, dropped) = self.ring.tail(cap);
        Ok(wire::WorkspaceResultBody::PreviewConsoleTail(wire::PreviewConsoleTailResult {
            op: wire::TagPreviewConsoleTail::PreviewConsoleTail,
            events,
            dropped,
        }))
    }
}

// ---------------------------------------------------------------------------
// One proxy: hyper http1 server on 127.0.0.1:<ephemeral>
// ---------------------------------------------------------------------------

struct Peer {
    id: u64,
    tx: tokio::sync::mpsc::Sender<tungstenite::Message>,
    queued_bytes: Arc<std::sync::atomic::AtomicUsize>,
    cancel: tokio::sync::watch::Sender<bool>,
}

struct ProxyShared {
    target_port: u16,
    ring: Arc<ConsoleRing>,
    page: Mutex<Option<Peer>>,
    devtools: Mutex<Option<Peer>>,
    target_connected: AtomicBool,
    next_peer_id: AtomicU64,
    next_cdp_id: AtomicI64,
    shutdown: tokio::sync::watch::Receiver<bool>,
    upgrades: Mutex<Vec<tokio::task::JoinHandle<()>>>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum PeerRole {
    Page,
    Devtools,
}

type BoxError = Box<dyn std::error::Error + Send + Sync>;
type ProxyBody = http_body_util::combinators::BoxBody<bytes::Bytes, BoxError>;

fn full_body(bytes: impl Into<bytes::Bytes>) -> ProxyBody {
    use http_body_util::BodyExt as _;
    http_body_util::Full::new(bytes.into()).map_err(|never| match never {}).boxed()
}

fn passthrough_body(body: hyper::body::Incoming) -> ProxyBody {
    use http_body_util::BodyExt as _;
    body.map_err(|error| Box::new(error) as BoxError).boxed()
}

fn text_response(status: u16, message: &str) -> hyper::Response<ProxyBody> {
    let mut response = hyper::Response::new(full_body(message.as_bytes().to_vec()));
    *response.status_mut() =
        hyper::StatusCode::from_u16(status).unwrap_or(hyper::StatusCode::BAD_GATEWAY);
    response
}

async fn spawn_proxy(target_port: u16, ring: Arc<ConsoleRing>) -> Result<ProxyRuntime, Refusal> {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.map_err(|error| {
        Refusal::new(
            wire::WorkspaceErrorCode::PortUnavailable,
            format!("could not bind a proxy port: {error}"),
        )
    })?;
    let proxy_port = listener
        .local_addr()
        .map_err(|error| {
            Refusal::new(
                wire::WorkspaceErrorCode::PortUnavailable,
                format!("could not read the proxy port: {error}"),
            )
        })?
        .port();
    let (shutdown, mut stopped) = tokio::sync::watch::channel(false);
    let shared = Arc::new(ProxyShared {
        target_port,
        ring,
        page: Mutex::new(None),
        devtools: Mutex::new(None),
        target_connected: AtomicBool::new(false),
        next_peer_id: AtomicU64::new(1),
        next_cdp_id: AtomicI64::new(PROXY_CDP_ID_BASE),
        shutdown: stopped.clone(),
        upgrades: Mutex::new(Vec::new()),
    });
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
    let task = tokio::spawn(async move {
        let mut connections = tokio::task::JoinSet::new();
        let _ = ready_tx.send(());
        loop {
            // Reap every connection that finished since the previous
            // accept. `try_join_next` is non-blocking, so a busy listener
            // cannot accumulate completed JoinSet entries indefinitely.
            // Bound cleanup per turn so a stream of immediately-completing
            // connections cannot starve the listener or shutdown signal.
            for _ in 0..32 {
                if connections.try_join_next().is_none() {
                    break;
                }
            }
            tokio::select! {
                _ = stopped.changed() => break,
                accepted = listener.accept() => {
                    let Ok((stream, _peer)) = accepted else { break };
                    let shared = Arc::clone(&shared);
                    connections.spawn(async move {
                        let io = hyper_util::rt::TokioIo::new(stream);
                        let service = hyper::service::service_fn(move |request| {
                            let shared = Arc::clone(&shared);
                            async move { Ok::<_, std::convert::Infallible>(handle_request(shared, request).await) }
                        });
                        let _ = hyper::server::conn::http1::Builder::new().serve_connection(io, service).with_upgrades().await;
                    });
                }
            }
        }
        connections.abort_all();
        while connections.join_next().await.is_some() {}
        let upgrades = shared
            .upgrades
            .lock()
            .map(|mut tasks| tasks.drain(..).collect::<Vec<_>>())
            .unwrap_or_default();
        for task in upgrades {
            task.abort();
            let _ = task.await;
        }
    });
    // Do not publish the port until the accept loop has started. This avoids
    // clients racing the task scheduler immediately after preview_open.
    let _ = ready_rx.await;
    Ok(ProxyRuntime { port: proxy_port, shutdown, task })
}

fn wants_websocket(request: &hyper::Request<hyper::body::Incoming>) -> bool {
    request
        .headers()
        .get(hyper::header::UPGRADE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.eq_ignore_ascii_case("websocket"))
}

async fn handle_request(
    shared: Arc<ProxyShared>,
    request: hyper::Request<hyper::body::Incoming>,
) -> hyper::Response<ProxyBody> {
    match request.uri().path() {
        "/__chatmux__/status" => status_response(&shared, &request),
        "/__chatmux__/target.js" => {
            let mut response = hyper::Response::new(full_body(target_js().as_bytes().to_vec()));
            response.headers_mut().insert(
                hyper::header::CONTENT_TYPE,
                hyper::header::HeaderValue::from_static("application/javascript; charset=utf-8"),
            );
            response.headers_mut().insert(
                hyper::header::CACHE_CONTROL,
                hyper::header::HeaderValue::from_static("no-store"),
            );
            response
        }
        "/__chatmux__/page" if wants_websocket(&request) => {
            accept_websocket(shared, request, PeerRole::Page)
        }
        "/__chatmux__/devtools" if wants_websocket(&request) => {
            accept_websocket(shared, request, PeerRole::Devtools)
        }
        "/__chatmux__/page" | "/__chatmux__/devtools" => {
            text_response(400, "websocket upgrade required")
        }
        _ if wants_websocket(&request) => forward_upgrade(shared, request).await,
        _ => forward_plain(shared, request).await,
    }
}

/// {"targetConnected": bool}, answering credentialed cross-origin fetches:
/// the web devtools drawer polls this from the chatmux origin with
/// credentials, so the reply must echo the origin and allow credentials
/// (a wildcard would be rejected by the browser).
fn status_response(
    shared: &ProxyShared,
    request: &hyper::Request<hyper::body::Incoming>,
) -> hyper::Response<ProxyBody> {
    let connected = shared.target_connected.load(Ordering::Relaxed);
    let body = if request.method() == hyper::Method::OPTIONS {
        full_body(Vec::new())
    } else {
        full_body(format!("{{\"targetConnected\":{connected}}}").into_bytes())
    };
    let mut response = hyper::Response::new(body);
    if request.method() == hyper::Method::OPTIONS {
        *response.status_mut() = hyper::StatusCode::NO_CONTENT;
    }
    let headers = response.headers_mut();
    headers.insert(
        hyper::header::CONTENT_TYPE,
        hyper::header::HeaderValue::from_static("application/json"),
    );
    headers.insert(hyper::header::VARY, hyper::header::HeaderValue::from_static("Origin"));
    if let Some(origin) = request.headers().get(hyper::header::ORIGIN) {
        headers.insert(hyper::header::ACCESS_CONTROL_ALLOW_ORIGIN, origin.clone());
        headers.insert(
            hyper::header::ACCESS_CONTROL_ALLOW_CREDENTIALS,
            hyper::header::HeaderValue::from_static("true"),
        );
        headers.insert(
            hyper::header::ACCESS_CONTROL_ALLOW_METHODS,
            hyper::header::HeaderValue::from_static("GET, OPTIONS"),
        );
        if let Some(requested) =
            request.headers().get(hyper::header::ACCESS_CONTROL_REQUEST_HEADERS)
        {
            headers.insert(hyper::header::ACCESS_CONTROL_ALLOW_HEADERS, requested.clone());
        }
    }
    response
}

// ---------------------------------------------------------------------------
// /__chatmux__/page and /__chatmux__/devtools websocket peers
// ---------------------------------------------------------------------------

/// Close code sent to a page/devtools connection displaced by a newer one
/// ("latest connection wins" in the pinned contract).
const REPLACED_CLOSE_CODE: u16 = 4001;
/// Bound cleanup when a displaced peer's TCP writer is stuck.
const REPLACED_WRITER_FLUSH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(1);

fn accept_websocket(
    shared: Arc<ProxyShared>,
    request: hyper::Request<hyper::body::Incoming>,
    role: PeerRole,
) -> hyper::Response<ProxyBody> {
    let Some(key) = request.headers().get(hyper::header::SEC_WEBSOCKET_KEY).cloned() else {
        return text_response(400, "missing sec-websocket-key");
    };
    let accept = tungstenite::handshake::derive_accept_key(key.as_bytes());
    let mut shutdown = shared.shutdown.clone();
    tokio::spawn(async move {
        if let Ok(upgraded) = hyper::upgrade::on(request).await {
            let io = hyper_util::rt::TokioIo::new(upgraded);
            let socket = tokio_tungstenite::WebSocketStream::from_raw_socket(
                io,
                tungstenite::protocol::Role::Server,
                Some(
                    tungstenite::protocol::WebSocketConfig::default()
                        .max_message_size(Some(PREVIEW_WS_MAX_MESSAGE_BYTES))
                        .max_frame_size(Some(PREVIEW_WS_MAX_MESSAGE_BYTES))
                        .max_write_buffer_size(PREVIEW_WS_QUEUE_BYTES),
                ),
            )
            .await;
            let peer_shutdown = shutdown.clone();
            tokio::select! {
                _ = shutdown.changed() => {}
                _ = run_peer(shared, socket, role, peer_shutdown) => {}
            }
        }
    });
    let mut response = hyper::Response::new(full_body(Vec::new()));
    *response.status_mut() = hyper::StatusCode::SWITCHING_PROTOCOLS;
    let headers = response.headers_mut();
    headers.insert(hyper::header::UPGRADE, hyper::header::HeaderValue::from_static("websocket"));
    headers.insert(hyper::header::CONNECTION, hyper::header::HeaderValue::from_static("Upgrade"));
    if let Ok(accept) = hyper::header::HeaderValue::from_str(&accept) {
        headers.insert(hyper::header::SEC_WEBSOCKET_ACCEPT, accept);
    }
    response
}

fn peer_slot(shared: &ProxyShared, role: PeerRole) -> &Mutex<Option<Peer>> {
    match role {
        PeerRole::Page => &shared.page,
        PeerRole::Devtools => &shared.devtools,
    }
}

fn send_to_slot(shared: &ProxyShared, role: PeerRole, text: String) {
    if let Ok(mut slot) = peer_slot(shared, role).lock()
        && let Some(peer) = slot.as_ref()
        && enqueue_message(&peer.tx, &peer.queued_bytes, tungstenite::Message::text(text)).is_err()
    {
        // A saturated peer is no longer coherent. Remove it instead of
        // silently dropping a CDP frame, then let its writer terminate.
        let _ = slot.take();
        if role == PeerRole::Page {
            shared.target_connected.store(false, Ordering::Relaxed);
        }
    }
}

fn message_len(message: &tungstenite::Message) -> usize {
    match message {
        tungstenite::Message::Text(v) => v.len(),
        tungstenite::Message::Binary(v)
        | tungstenite::Message::Ping(v)
        | tungstenite::Message::Pong(v) => v.len(),
        _ => 64,
    }
}

fn enqueue_message(
    tx: &tokio::sync::mpsc::Sender<tungstenite::Message>,
    queued: &std::sync::atomic::AtomicUsize,
    message: tungstenite::Message,
) -> Result<(), tokio::sync::mpsc::error::TrySendError<tungstenite::Message>> {
    let bytes = message_len(&message);
    let prior = queued.fetch_add(bytes, Ordering::AcqRel);
    if prior.saturating_add(bytes) > PREVIEW_WS_QUEUE_BYTES {
        queued.fetch_sub(bytes, Ordering::AcqRel);
        return Err(tokio::sync::mpsc::error::TrySendError::Full(message));
    }
    match tx.try_send(message) {
        Ok(()) => Ok(()),
        Err(error) => {
            queued.fetch_sub(bytes, Ordering::AcqRel);
            Err(error)
        }
    }
}

async fn run_peer<S>(
    shared: Arc<ProxyShared>,
    socket: tokio_tungstenite::WebSocketStream<S>,
    role: PeerRole,
    mut shutdown: tokio::sync::watch::Receiver<bool>,
) where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    use futures_util::{SinkExt as _, StreamExt as _};
    use tokio_tungstenite::tungstenite::Message;
    let (mut sink, mut stream) = socket.split();
    let (tx, mut rx) = tokio::sync::mpsc::channel::<Message>(PREVIEW_WS_QUEUE_CAPACITY);
    let queued_bytes = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let (cancel, mut cancelled) = tokio::sync::watch::channel(false);
    let peer_id = shared.next_peer_id.fetch_add(1, Ordering::Relaxed);
    if let Ok(mut slot) = peer_slot(&shared, role).lock()
        && let Some(previous) = slot.replace(Peer {
            id: peer_id,
            tx: tx.clone(),
            queued_bytes: Arc::clone(&queued_bytes),
            cancel: cancel.clone(),
        })
    {
        let _ = enqueue_message(
            &previous.tx,
            &previous.queued_bytes,
            Message::Close(Some(tungstenite::protocol::CloseFrame {
                code: REPLACED_CLOSE_CODE.into(),
                reason: "replaced by a newer connection".into(),
            })),
        );
        let _ = previous.cancel.send(true);
    }
    if role == PeerRole::Page {
        shared.target_connected.store(true, Ordering::Relaxed);
        // Enable the domains the ring tees even before any DevTools
        // frontend connects; responses to these ids are swallowed.
        for method in ["Runtime.enable", "Network.enable", "Page.enable"] {
            let id = shared.next_cdp_id.fetch_add(1, Ordering::Relaxed);
            let message = Message::text(format!("{{\"id\":{id},\"method\":\"{method}\"}}"));
            if enqueue_message(&tx, &queued_bytes, message).is_err() {
                if let Ok(mut slot) = peer_slot(&shared, role).lock()
                    && slot.as_ref().is_some_and(|peer| peer.id == peer_id)
                {
                    *slot = None;
                }
                shared.target_connected.store(false, Ordering::Relaxed);
                return;
            }
        }
    }
    let writer_queued_bytes = Arc::clone(&queued_bytes);
    let mut writer = tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            writer_queued_bytes.fetch_sub(message_len(&message), Ordering::AcqRel);
            let closing = matches!(message, Message::Close(_));
            if sink.send(message).await.is_err() || closing {
                break;
            }
        }
        let _ = sink.close().await;
    });
    let mut replaced = false;
    loop {
        let message = tokio::select! {
            _ = shutdown.changed() => break,
            _ = cancelled.changed() => { replaced = true; break },
            message = stream.next() => message,
        };
        let Some(Ok(message)) = message else { break };
        match message {
            Message::Text(text) => {
                let text = text.as_str().to_owned();
                match role {
                    PeerRole::Page => {
                        let proxy_response_id = tee_cdp_frame(&shared.ring, &text);
                        if proxy_response_id.is_none() {
                            send_to_slot(&shared, PeerRole::Devtools, text);
                        }
                    }
                    PeerRole::Devtools => send_to_slot(&shared, PeerRole::Page, text),
                }
            }
            Message::Ping(payload) => {
                match enqueue_message(&tx, &queued_bytes, Message::Pong(payload)) {
                    Ok(()) => {}
                    Err(_) => break,
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }
    // Only the peer that still owns the slot clears it (a replaced peer
    // must not clear its successor).
    if let Ok(mut slot) = peer_slot(&shared, role).lock()
        && slot.as_ref().is_some_and(|peer| peer.id == peer_id)
    {
        *slot = None;
        if role == PeerRole::Page {
            shared.target_connected.store(false, Ordering::Relaxed);
        }
    }
    // Give a displaced peer's queued close frame a bounded chance to flush,
    // then abort a writer stuck behind a non-reading socket. Other exits
    // abort immediately because the read side has already ended.
    if replaced {
        if tokio::time::timeout(REPLACED_WRITER_FLUSH_TIMEOUT, &mut writer).await.is_err() {
            writer.abort();
            let _ = writer.await;
        }
    } else {
        writer.abort();
        let _ = writer.await;
    }
}

// ---------------------------------------------------------------------------
// Reverse proxy to the target port
// ---------------------------------------------------------------------------

const INJECT_TAG: &[u8] = b"<script src=\"/__chatmux__/target.js\"></script>";
const NO_INJECT_HEADER: &str = "x-chatmux-no-inject";
/// HTML responses are buffered only for injection, so bound both memory and
/// time spent waiting on a target that never finishes its response.
const PREVIEW_HTML_BODY_MAX_BYTES: usize = 8 * 1024 * 1024;
const PREVIEW_HTML_BODY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

async fn connect_target(
    shared: &ProxyShared,
) -> Result<
    (hyper::client::conn::http1::SendRequest<hyper::body::Incoming>, tokio::task::JoinHandle<()>),
    Box<hyper::Response<ProxyBody>>,
> {
    let stream = tokio::net::TcpStream::connect(("127.0.0.1", shared.target_port)).await.map_err(
        |error| {
            Box::new(text_response(502, &format!("preview target port is not reachable: {error}")))
        },
    )?;
    let io = hyper_util::rt::TokioIo::new(stream);
    let (sender, connection) =
        hyper::client::conn::http1::handshake(io).await.map_err(|error| {
            Box::new(text_response(502, &format!("target handshake failed: {error}")))
        })?;
    let driver = tokio::spawn(async move {
        let _ = connection.with_upgrades().await;
    });
    Ok((sender, driver))
}

/// Copy the inbound request head for the target hop: same method, path,
/// and headers; accept-encoding stripped so an HTML answer arrives
/// uncompressed for injection. The Host header passes through unchanged —
/// the TCP-level tunnel this proxy fronts forwarded it verbatim, so
/// dev-server host allowlists keep working identically.
fn copy_request(
    parts: &http::request::Parts,
    body: hyper::body::Incoming,
) -> Result<hyper::Request<hyper::body::Incoming>, String> {
    let uri = parts.uri.path_and_query().map(|value| value.as_str()).unwrap_or("/");
    let mut builder = hyper::Request::builder().method(parts.method.clone()).uri(uri);
    if let Some(headers) = builder.headers_mut() {
        for (name, value) in &parts.headers {
            if name == hyper::header::ACCEPT_ENCODING {
                continue;
            }
            headers.append(name.clone(), value.clone());
        }
    }
    builder.body(body).map_err(|error| format!("could not rebuild the proxied request: {error}"))
}

fn header_is_one(headers: &hyper::HeaderMap, name: &str) -> bool {
    headers.get(name).and_then(|value| value.to_str().ok()).is_some_and(|value| value.trim() == "1")
}

/// Non-websocket requests: stream through, injecting the chobitsu tag into
/// text/html answers (unless x-chatmux-no-inject rides either direction).
async fn forward_plain(
    shared: Arc<ProxyShared>,
    request: hyper::Request<hyper::body::Incoming>,
) -> hyper::Response<ProxyBody> {
    let (mut sender, _driver) = match connect_target(&shared).await {
        Ok(ready) => ready,
        Err(response) => return *response,
    };
    let skip_inject = header_is_one(request.headers(), NO_INJECT_HEADER);
    let (parts, body) = request.into_parts();
    let outbound = match copy_request(&parts, body) {
        Ok(outbound) => outbound,
        Err(message) => return text_response(502, &message),
    };
    let response = match sender.send_request(outbound).await {
        Ok(response) => response,
        Err(error) => return text_response(502, &format!("target request failed: {error}")),
    };
    let is_html = response
        .headers()
        .get(hyper::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.trim_start().to_ascii_lowercase().starts_with("text/html"));
    let inject = !skip_inject
        && !header_is_one(response.headers(), NO_INJECT_HEADER)
        && is_html
        && response.status().is_success();
    if !inject {
        return response.map(passthrough_body);
    }
    let (mut parts, body) = response.into_parts();
    use http_body_util::BodyExt as _;
    let limited = http_body_util::Limited::new(body, PREVIEW_HTML_BODY_MAX_BYTES);
    let collected = match tokio::time::timeout(PREVIEW_HTML_BODY_TIMEOUT, limited.collect()).await {
        Ok(Ok(collected)) => collected.to_bytes(),
        Ok(Err(error)) if error.downcast_ref::<http_body_util::LengthLimitError>().is_some() => {
            return text_response(
                502,
                &format!(
                    "target HTML response exceeds the {PREVIEW_HTML_BODY_MAX_BYTES} byte limit",
                ),
            );
        }
        Ok(Err(error)) => return text_response(502, &format!("target body failed: {error}")),
        Err(_) => return text_response(502, "target HTML body timed out"),
    };
    let injected = inject_into_html(&collected);
    parts.headers.remove(hyper::header::CONTENT_LENGTH);
    parts.headers.remove(hyper::header::CONTENT_ENCODING);
    parts.headers.remove(hyper::header::TRANSFER_ENCODING);
    if let Ok(length) = hyper::header::HeaderValue::from_str(&injected.len().to_string()) {
        parts.headers.insert(hyper::header::CONTENT_LENGTH, length);
    }
    hyper::Response::from_parts(parts, full_body(injected))
}

/// Websocket (or any other upgrade) requests for the target itself — a dev
/// server's HMR socket, for example: complete both upgrades and pipe bytes.
async fn forward_upgrade(
    shared: Arc<ProxyShared>,
    request: hyper::Request<hyper::body::Incoming>,
) -> hyper::Response<ProxyBody> {
    let (mut sender, _driver) = match connect_target(&shared).await {
        Ok(ready) => ready,
        Err(response) => return *response,
    };
    let (mut parts, body) = request.into_parts();
    let Some(server_upgrade) = parts.extensions.remove::<hyper::upgrade::OnUpgrade>() else {
        return text_response(502, "upgrade requested without an upgradable connection");
    };
    let outbound = match copy_request(&parts, body) {
        Ok(outbound) => outbound,
        Err(message) => return text_response(502, &message),
    };
    let mut response = match sender.send_request(outbound).await {
        Ok(response) => response,
        Err(error) => return text_response(502, &format!("target request failed: {error}")),
    };
    if response.status() != hyper::StatusCode::SWITCHING_PROTOCOLS {
        return response.map(passthrough_body);
    }
    let client_upgrade = hyper::upgrade::on(&mut response);
    let task = tokio::spawn(async move {
        let (Ok(client), Ok(server)) = tokio::join!(client_upgrade, server_upgrade) else {
            return;
        };
        let mut client_io = hyper_util::rt::TokioIo::new(client);
        let mut server_io = hyper_util::rt::TokioIo::new(server);
        let _ = tokio::io::copy_bidirectional(&mut server_io, &mut client_io).await;
    });
    if let Ok(mut upgrades) = shared.upgrades.lock() {
        // Finished handles no longer need to be retained. Tokio guarantees
        // task destruction has completed once `is_finished` is true.
        upgrades.retain(|task| !task.is_finished());
        upgrades.push(task);
    } else {
        task.abort();
    }
    let (parts, _body) = response.into_parts();
    hyper::Response::from_parts(parts, full_body(Vec::new()))
}

// ---------------------------------------------------------------------------
// HTML injection
// ---------------------------------------------------------------------------

fn find_ascii_case_insensitive(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window.iter().zip(needle).all(|(a, b)| a.eq_ignore_ascii_case(b)))
}

/// Inject the target.js script tag: before `</head>`, else right after the
/// `<body ...>` opening tag, else prepended (pinned contract).
fn inject_into_html(html: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(html.len() + INJECT_TAG.len());
    if let Some(head_end) = find_ascii_case_insensitive(html, b"</head>") {
        out.extend_from_slice(&html[..head_end]);
        out.extend_from_slice(INJECT_TAG);
        out.extend_from_slice(&html[head_end..]);
        return out;
    }
    if let Some(body_start) = find_ascii_case_insensitive(html, b"<body")
        && let Some(tag_close) =
            html[body_start..].iter().position(|byte| *byte == b'>').map(|at| body_start + at + 1)
    {
        out.extend_from_slice(&html[..tag_close]);
        out.extend_from_slice(INJECT_TAG);
        out.extend_from_slice(&html[tag_close..]);
        return out;
    }
    out.extend_from_slice(INJECT_TAG);
    out.extend_from_slice(html);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::{SinkExt as _, StreamExt as _};
    use serde_json::Value;
    use tokio_tungstenite::tungstenite::Message;

    #[test]
    fn duplicate_request_ids_replace_order_entry() {
        let ring = ConsoleRing::new();
        ring.remember_request("same".to_owned(), "GET".to_owned(), "https://first".to_owned());
        ring.remember_request("other".to_owned(), "POST".to_owned(), "https://other".to_owned());
        ring.remember_request("same".to_owned(), "PUT".to_owned(), "https://latest".to_owned());

        let mut inner = ring.inner.lock().expect("ring lock");
        assert_eq!(inner.pending_order, VecDeque::from(["other".to_owned(), "same".to_owned()]));
        assert_eq!(inner.pending.len(), 2);
        assert_eq!(
            inner.pending.remove("same"),
            Some(("PUT".to_owned(), "https://latest".to_owned()))
        );
    }

    /// Tiny dev-server double: "/" is HTML with a head, "/body-only" has no
    /// head, "/plain" is not HTML, "/opt-out" answers with the no-inject
    /// response header.
    async fn spawn_target() -> u16 {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.expect("target bind");
        let port = listener.local_addr().expect("target addr").port();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else { break };
                tokio::spawn(async move {
                    let io = hyper_util::rt::TokioIo::new(stream);
                    let service = hyper::service::service_fn(|request| async move {
                        if request.uri().path() == "/oversized" {
                            let mut response = hyper::Response::new(full_body(vec![
                                b'x';
                                PREVIEW_HTML_BODY_MAX_BYTES
                                    + 1
                            ]));
                            response.headers_mut().insert(
                                hyper::header::CONTENT_TYPE,
                                hyper::header::HeaderValue::from_static("text/html"),
                            );
                            return Ok::<_, std::convert::Infallible>(response);
                        }
                        let (body, content_type, opt_out) = match request.uri().path() {
                            "/body-only" => ("<body><p>hi</p></body>", "text/html", false),
                            "/plain" => ("no tags here", "text/plain", false),
                            "/opt-out" => {
                                ("<html><head></head><body></body></html>", "text/html", true)
                            }
                            _ => (
                                "<html><head><title>t</title></head><body></body></html>",
                                "text/html; charset=utf-8",
                                false,
                            ),
                        };
                        let mut response =
                            hyper::Response::new(full_body(body.as_bytes().to_vec()));
                        response.headers_mut().insert(
                            hyper::header::CONTENT_TYPE,
                            hyper::header::HeaderValue::from_str(content_type).expect("ct"),
                        );
                        if opt_out {
                            response.headers_mut().insert(
                                NO_INJECT_HEADER,
                                hyper::header::HeaderValue::from_static("1"),
                            );
                        }
                        Ok::<_, std::convert::Infallible>(response)
                    });
                    let _ = hyper::server::conn::http1::Builder::new()
                        .serve_connection(io, service)
                        .await;
                });
            }
        });
        port
    }

    async fn open_proxy(registry: &PreviewRegistry, target_port: u16) -> u16 {
        match registry.open(i64::from(target_port)).await.expect("preview_open") {
            wire::WorkspaceResultBody::PreviewOpen(result) => {
                u16::try_from(result.proxy_port).expect("port range")
            }
            other => panic!("wrong body: {other:?}"),
        }
    }

    async fn http_get(
        port: u16,
        path: &str,
        headers: &[(&str, &str)],
    ) -> (reqwest::StatusCode, reqwest::header::HeaderMap, String) {
        // reqwest's rustls-no-provider build needs the process default
        // provider, exactly like main() installs it.
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::Client::new();
        let mut request = client.get(format!("http://127.0.0.1:{port}{path}"));
        for (name, value) in headers {
            request = request.header(*name, *value);
        }
        let response = request.send().await.expect("http response");
        let status = response.status();
        let headers = response.headers().clone();
        (status, headers, response.text().await.expect("body"))
    }

    #[tokio::test]
    async fn injects_into_html_and_honors_the_opt_outs() {
        let registry = PreviewRegistry::new();
        let target = spawn_target().await;
        let proxy = open_proxy(&registry, target).await;
        let tag = std::str::from_utf8(INJECT_TAG).expect("tag utf8");

        let (status, _, body) = http_get(proxy, "/", &[]).await;
        assert_eq!(status, 200);
        let tag_at = body.find(tag).expect("tag injected");
        let head_at = body.find("</head>").expect("head kept");
        assert!(tag_at < head_at, "before </head>");

        let (_, _, body) = http_get(proxy, "/body-only", &[]).await;
        let tag_at = body.find(tag).expect("tag injected");
        assert!(body[..tag_at].contains("<body>"), "after the <body> tag");

        let (_, _, body) = http_get(proxy, "/plain", &[]).await;
        assert!(!body.contains(tag), "non-HTML passes through");

        let (_, _, body) = http_get(proxy, "/opt-out", &[]).await;
        assert!(!body.contains(tag), "response header opts out");

        let (status, _, body) = http_get(proxy, "/oversized", &[]).await;
        assert_eq!(status, 502);
        assert!(body.contains("target HTML response exceeds"));

        let (_, _, body) = http_get(proxy, "/", &[(NO_INJECT_HEADER, "1")]).await;
        assert!(!body.contains(tag), "request header opts out");

        // Reuse: the same target port keeps its proxy port.
        assert_eq!(open_proxy(&registry, target).await, proxy);
        registry.shutdown().await;
        assert!(tokio::net::TcpStream::connect(("127.0.0.1", proxy)).await.is_err());
    }

    #[tokio::test]
    async fn status_answers_credentialed_cross_origin_fetches() {
        let registry = PreviewRegistry::new();
        let target = spawn_target().await;
        let proxy = open_proxy(&registry, target).await;
        let origin = "https://chatmux.dev";
        let (status, headers, body) =
            http_get(proxy, "/__chatmux__/status", &[("origin", origin)]).await;
        assert_eq!(status, 200);
        assert_eq!(body, "{\"targetConnected\":false}");
        assert_eq!(
            headers.get("access-control-allow-origin").and_then(|value| value.to_str().ok()),
            Some(origin),
        );
        assert_eq!(
            headers.get("access-control-allow-credentials").and_then(|value| value.to_str().ok()),
            Some("true"),
        );
        assert_eq!(headers.get("vary").and_then(|value| value.to_str().ok()), Some("Origin"));
        // Same-origin probes (no Origin header) stay plain.
        let (_, headers, _) = http_get(proxy, "/__chatmux__/status", &[]).await;
        assert!(headers.get("access-control-allow-origin").is_none());
        // The served bundle is the vendored chobitsu + connector.
        let (status, headers, body) = http_get(proxy, "/__chatmux__/target.js", &[]).await;
        assert_eq!(status, 200);
        assert!(
            headers
                .get("content-type")
                .and_then(|value| value.to_str().ok())
                .is_some_and(|value| value.starts_with("application/javascript")),
        );
        assert!(body.contains("chobitsu"));
        assert!(body.contains("/__chatmux__/page"));
    }

    async fn connect_ws(
        port: u16,
        path: &str,
    ) -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>
    {
        let (socket, _) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}{path}"))
            .await
            .expect("ws connect");
        socket
    }

    async fn next_text<S>(socket: &mut S, what: &str) -> String
    where
        S: futures_util::Stream<Item = Result<Message, tungstenite::Error>> + Unpin,
    {
        loop {
            let message = tokio::time::timeout(std::time::Duration::from_secs(10), socket.next())
                .await
                .unwrap_or_else(|_| panic!("no {what} within 10s"))
                .unwrap_or_else(|| panic!("{what}: socket ended"))
                .unwrap_or_else(|error| panic!("{what}: {error}"));
            match message {
                Message::Text(text) => return text.as_str().to_owned(),
                Message::Close(frame) => panic!("{what}: closed early: {frame:?}"),
                _ => {}
            }
        }
    }

    #[tokio::test]
    async fn pipes_page_and_devtools_tees_the_ring_and_replaces_stale_pages() {
        let registry = PreviewRegistry::new();
        let target = spawn_target().await;
        let proxy = open_proxy(&registry, target).await;

        // Fake CDP page peer: the proxy enables its tee domains first.
        let mut page = connect_ws(proxy, "/__chatmux__/page").await;
        let mut enabled = Vec::new();
        for _ in 0..3 {
            let frame: Value = serde_json::from_str(&next_text(&mut page, "enable command").await)
                .expect("enable json");
            assert!(frame["id"].as_i64().expect("id") >= PROXY_CDP_ID_BASE);
            enabled.push(frame["method"].as_str().unwrap_or_default().to_owned());
            page.send(Message::text(format!("{{\"id\":{},\"result\":{{}}}}", frame["id"])))
                .await
                .expect("ack enable");
        }
        assert!(enabled.contains(&"Runtime.enable".to_owned()));
        assert!(enabled.contains(&"Network.enable".to_owned()));

        // The status endpoint now reports the page.
        let (_, _, body) = http_get(proxy, "/__chatmux__/status", &[]).await;
        assert_eq!(body, "{\"targetConnected\":true}");

        // DevTools frontend speaks through the proxy to the page...
        let mut devtools = connect_ws(proxy, "/__chatmux__/devtools").await;
        devtools
            .send(Message::text("{\"id\":1,\"method\":\"Runtime.evaluate\"}"))
            .await
            .expect("devtools send");
        let seen = next_text(&mut page, "piped devtools command").await;
        assert!(seen.contains("Runtime.evaluate"));
        // ...and answers flow back (the proxy's own enable acks never do).
        page.send(Message::text("{\"id\":1,\"result\":{\"value\":7}}")).await.expect("page reply");
        let reply = next_text(&mut devtools, "piped page reply").await;
        assert!(reply.contains("\"value\":7"));

        // Console + network events tee into the preview_console_tail ring.
        let console = serde_json::json!({
            "method": "Runtime.consoleAPICalled",
            "params": {"type": "error", "args": [
                {"type": "string", "value": "boom"},
                {"type": "object", "description": "Error: bad"},
            ]},
        });
        page.send(Message::text(console.to_string())).await.expect("console event");
        let network_sent = serde_json::json!({
            "method": "Network.requestWillBeSent",
            "params": {"requestId": "r1", "request": {"method": "GET", "url": "http://x/api"}},
        });
        let network_done = serde_json::json!({
            "method": "Network.responseReceived",
            "params": {"requestId": "r1", "response": {"status": 500}},
        });
        page.send(Message::text(network_sent.to_string())).await.expect("network sent");
        page.send(Message::text(network_done.to_string())).await.expect("network done");
        // Both also pipe to devtools (console first).
        assert!(next_text(&mut devtools, "console pipe").await.contains("consoleAPICalled"));
        let tail = tokio::time::timeout(std::time::Duration::from_secs(10), async {
            loop {
                let body = registry.tail(None).expect("tail");
                let wire::WorkspaceResultBody::PreviewConsoleTail(result) = &body else {
                    panic!("wrong body");
                };
                if result.events.len() >= 2 {
                    break result.events.clone();
                }
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
        })
        .await
        .expect("ring filled");
        let has_console = tail.iter().any(|event| match event {
            wire::PreviewEvent::Console(console) => {
                console.text.contains("boom") && console.text.contains("Error: bad")
            }
            wire::PreviewEvent::Network(_) => false,
        });
        let has_network = tail.iter().any(|event| match event {
            wire::PreviewEvent::Network(network) => {
                network.url == "http://x/api" && network.status == Some(500) && !network.ok
            }
            wire::PreviewEvent::Console(_) => false,
        });
        assert!(has_console, "console teed: {tail:?}");
        assert!(has_network, "network teed: {tail:?}");

        // Latest page connection wins; the earlier one gets a close frame.
        let mut replacement = connect_ws(proxy, "/__chatmux__/page").await;
        let closed = tokio::time::timeout(std::time::Duration::from_secs(10), async {
            loop {
                match page.next().await {
                    Some(Ok(Message::Close(frame))) => break frame,
                    Some(Ok(_)) => {}
                    other => panic!("stale page ended without a close frame: {other:?}"),
                }
            }
        })
        .await
        .expect("close frame within 10s")
        .expect("close carries a frame");
        assert_eq!(u16::from(closed.code), REPLACED_CLOSE_CODE);
        // The replacement is now the live page (it gets fresh enables).
        let fresh: Value = serde_json::from_str(&next_text(&mut replacement, "enable").await)
            .expect("enable json");
        assert!(fresh["id"].as_i64().expect("id") >= PROXY_CDP_ID_BASE);
    }

    #[tokio::test]
    async fn bounds_preview_listeners_and_evicts_oldest_target() {
        let registry = PreviewRegistry::new();
        for target_port in 1..=i64::try_from(PREVIEW_PROXY_CAP).unwrap() + 1 {
            registry.open(target_port).await.expect("preview open");
        }
        assert_eq!(registry.proxies.lock().await.len(), PREVIEW_PROXY_CAP);
        assert!(!registry.proxies.lock().await.contains_key(&1));
        assert!(registry.proxies.lock().await.contains_key(&(PREVIEW_PROXY_CAP as i64 + 1)));
        registry.shutdown().await;
        assert!(registry.proxies.lock().await.is_empty());
        assert!(registry.order.lock().await.is_empty());
    }
}
