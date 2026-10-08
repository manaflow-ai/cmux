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
//! - GET  /__chatmux__/status     -> {"targetConnected": bool}; the
//!   credentialed cross-origin grant (ACAO=<origin> + ACAC=true) needs the
//!   per-preview capability plus the devtools origin admission — the web
//!   devtools drawer polls it cross-origin, presenting the capability
//!   `preview_open` handed it;
//! - console/network CDP events tee into a bounded ring served by the
//!   `preview_console_tail` verb (Pi-readable).
//!
//! Access (every request, before any byte reaches the dev server):
//!
//! - `Host` must be a loopback name (`localhost`, `*.localhost`), an
//!   address literal, or a name under one of the registry's public preview
//!   suffixes (the tunnel forwards its `<name>.preview.chatmux.dev` Host
//!   verbatim). Every other name is a DNS-rebound page and gets a 403.
//! - Proxied paths and upstream WebSocket upgrades need the per-preview
//!   capability: the `__chatmux_preview_<proxy port>` cookie, the
//!   `x-chatmux-capability` header, or a one-time
//!   `?__chatmux_capability=` navigation, which answers a 302 that sets the
//!   HttpOnly cookie and drops the parameter from the URL. The proxy strips
//!   the credential before it forwards. A missing or wrong one gets a 401.

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
/// Longest CDP `requestId` the pending-request join remembers. Real ids are
/// short counters; a frame can carry up to PREVIEW_WS_MAX_MESSAGE_BYTES, and
/// PENDING_REQUEST_CAP copies of such an id would pin gigabytes.
const NETWORK_REQUEST_ID_MAX_BYTES: usize = 256;
/// Most in-flight network requests remembered while their response is
/// pending (requestWillBeSent -> responseReceived/loadingFailed join).
const PENDING_REQUEST_CAP: usize = 512;
/// Bound browser/devtools CDP messages before tungstenite allocates them.
const PREVIEW_WS_MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;
/// Limit queued frames per peer. A browser/devtools socket that stops
/// reading must not make the relay retain an unbounded stream of CDP data.
const PREVIEW_WS_QUEUE_CAPACITY: usize = 64;
const PREVIEW_WS_QUEUE_BYTES: usize = 64 * 1024 * 1024;
/// Maximum number of live client connections retained by one preview proxy.
pub const PREVIEW_PROXY_CONNECTION_CAP: usize = 128;
/// Maximum number of target upgrade copy tasks retained by one preview proxy.
/// Upgraded sockets outlive their HTTP connection task, so they need a
/// separate admission bound from the client connection cap.
pub const PREVIEW_PROXY_UPGRADE_CAP: usize = 64;
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
            if request_id.len() > NETWORK_REQUEST_ID_MAX_BYTES {
                return None;
            }
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
    public_host_suffixes: Arc<[String]>,
    proxies: tokio::sync::Mutex<HashMap<i64, ProxyRuntime>>,
    order: tokio::sync::Mutex<VecDeque<i64>>,
}

struct ProxyRuntime {
    port: u16,
    capability: String,
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

/// The public preview domain the chatmux tunnel serves proxies under.
pub const DEFAULT_PUBLIC_HOST_SUFFIX: &str = "preview.chatmux.dev";
/// Comma-separated extra public preview suffixes (self-hosted tunnels).
pub const PUBLIC_HOST_SUFFIXES_ENV: &str = "CHATMUX_PREVIEW_HOST_SUFFIXES";

impl PreviewRegistry {
    /// A registry whose proxies accept the default public preview suffix
    /// plus any listed in `CHATMUX_PREVIEW_HOST_SUFFIXES`.
    pub fn new() -> PreviewRegistry {
        let mut suffixes = vec![DEFAULT_PUBLIC_HOST_SUFFIX.to_owned()];
        if let Ok(extra) = std::env::var(PUBLIC_HOST_SUFFIXES_ENV) {
            suffixes.extend(extra.split(',').map(str::to_owned));
        }
        PreviewRegistry::with_public_host_suffixes(suffixes)
    }

    /// A registry whose proxies accept `Host` names equal to or under
    /// exactly these suffixes (besides loopback names and address
    /// literals).
    pub fn with_public_host_suffixes(
        suffixes: impl IntoIterator<Item = impl Into<String>>,
    ) -> PreviewRegistry {
        let mut normalized: Vec<String> = Vec::new();
        for suffix in suffixes {
            let suffix: String = suffix.into();
            let suffix = suffix.trim().trim_matches('.').to_ascii_lowercase();
            if !suffix.is_empty() && !normalized.contains(&suffix) {
                normalized.push(suffix);
            }
        }
        PreviewRegistry {
            ring: Arc::new(ConsoleRing::new()),
            public_host_suffixes: normalized.into(),
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
                let runtime = spawn_proxy(
                    target,
                    Arc::clone(&self.ring),
                    Arc::clone(&self.public_host_suffixes),
                )
                .await?;
                let port = runtime.port;
                proxies.insert(target_port, runtime);
                port
            }
            None => {
                let target = u16::try_from(target_port).unwrap_or_default();
                let runtime = spawn_proxy(
                    target,
                    Arc::clone(&self.ring),
                    Arc::clone(&self.public_host_suffixes),
                )
                .await?;
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
            capability: proxies
                .get(&target_port)
                .map(|runtime| runtime.capability.clone())
                .expect("preview runtime retained after open"),
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
    capability: String,
    /// Name of the HttpOnly cookie that carries the capability. Cookies are
    /// not port-scoped, so the proxy port keeps loopback proxies apart.
    capability_cookie: String,
    public_host_suffixes: Arc<[String]>,
    ring: Arc<ConsoleRing>,
    page: Mutex<Option<Peer>>,
    devtools: Mutex<Option<Peer>>,
    target_connected: AtomicBool,
    next_peer_id: AtomicU64,
    next_cdp_id: AtomicI64,
    shutdown: tokio::sync::watch::Receiver<bool>,
    upgrade_slots: Arc<tokio::sync::Semaphore>,
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

async fn spawn_proxy(
    target_port: u16,
    ring: Arc<ConsoleRing>,
    public_host_suffixes: Arc<[String]>,
) -> Result<ProxyRuntime, Refusal> {
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
    let capability = mint_preview_capability()?;
    let shared = Arc::new(ProxyShared {
        target_port,
        capability: capability.clone(),
        capability_cookie: format!("{CAPABILITY_COOKIE_PREFIX}{proxy_port}"),
        public_host_suffixes,
        ring,
        page: Mutex::new(None),
        devtools: Mutex::new(None),
        target_connected: AtomicBool::new(false),
        next_peer_id: AtomicU64::new(1),
        next_cdp_id: AtomicI64::new(PROXY_CDP_ID_BASE),
        shutdown: stopped.clone(),
        upgrade_slots: Arc::new(tokio::sync::Semaphore::new(PREVIEW_PROXY_UPGRADE_CAP)),
        upgrades: Mutex::new(Vec::new()),
    });
    let connection_slots = Arc::new(tokio::sync::Semaphore::new(PREVIEW_PROXY_CONNECTION_CAP));
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
    let task = tokio::spawn(async move {
        let mut connections = tokio::task::JoinSet::new();
        let _ = ready_tx.send(());
        loop {
            // Reap every connection that has finished since the previous
            // accept. `try_join_next` is non-blocking, and no new connection
            // is spawned during this drain, so the loop always reaches an
            // empty set before accepting the next stream.
            while connections.try_join_next().is_some() {}
            tokio::select! {
                _ = stopped.changed() => break,
                accepted = listener.accept() => {
                    let Ok((stream, _peer)) = accepted else { break };
                    let Ok(connection_slot) = connection_slots.clone().try_acquire_owned() else {
                        // This listener is local-only. Drop excess clients before
                        // creating a task, so a connection flood cannot grow the
                        // Tokio task set or consume all file descriptors.
                        continue;
                    };
                    let shared = Arc::clone(&shared);
                    connections.spawn(async move {
                        let _connection_slot = connection_slot;
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
        connections.shutdown().await;
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
    Ok(ProxyRuntime { port: proxy_port, capability, shutdown, task })
}

fn mint_preview_capability() -> Result<String, Refusal> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|error| {
        Refusal::failed(format!("could not allocate preview capability: {error}"))
    })?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
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
    if !request_host_allowed(request.headers(), &shared.public_host_suffixes) {
        return text_response(403, "host not allowed");
    }
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
            accept_control_websocket(shared, request, PeerRole::Page)
        }
        "/__chatmux__/devtools" if wants_websocket(&request) => {
            accept_control_websocket(shared, request, PeerRole::Devtools)
        }
        "/__chatmux__/page" | "/__chatmux__/devtools" => {
            text_response(400, "websocket upgrade required")
        }
        _ => match proxied_access(&shared, &request) {
            ProxiedAccess::Denied => text_response(401, "preview capability required"),
            ProxiedAccess::Bootstrap
                if !wants_websocket(&request)
                    && matches!(*request.method(), hyper::Method::GET | hyper::Method::HEAD) =>
            {
                bootstrap_response(&shared, &request)
            }
            ProxiedAccess::Granted | ProxiedAccess::Bootstrap => {
                if wants_websocket(&request) {
                    forward_upgrade(shared, request).await
                } else {
                    forward_plain(shared, request).await
                }
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Access: Host allowlist and the proxied-path capability
// ---------------------------------------------------------------------------

const CAPABILITY_QUERY: &str = "__chatmux_capability";
const CAPABILITY_HEADER: &str = "x-chatmux-capability";
const CAPABILITY_COOKIE_PREFIX: &str = "__chatmux_preview_";

/// The `Host` rule (module docs). Exactly one `Host` value; it must be a
/// bare `name[:port]` (no userinfo, path or whitespace). Address literals
/// pass: a rebound page always sends the domain name it loaded from.
fn request_host_allowed(headers: &hyper::HeaderMap, public_suffixes: &[String]) -> bool {
    let mut values = headers.get_all(hyper::header::HOST).iter();
    let (Some(value), None) = (values.next(), values.next()) else { return false };
    let Ok(value) = value.to_str() else { return false };
    let value = value.trim();
    if value.is_empty()
        || value.bytes().any(|byte| {
            matches!(byte, b'/' | b'\\' | b'@' | b'?' | b'#' | b'%') || byte.is_ascii_whitespace()
        })
    {
        return false;
    }
    let Ok(url) = url::Url::parse(&format!("http://{value}/")) else { return false };
    match url.host() {
        Some(url::Host::Ipv4(_) | url::Host::Ipv6(_)) => true,
        Some(url::Host::Domain(name)) => {
            let name = name.trim_end_matches('.').to_ascii_lowercase();
            name == "localhost"
                || name.ends_with(".localhost")
                || public_suffixes.iter().any(|suffix| {
                    name.strip_suffix(suffix.as_str())
                        .is_some_and(|rest| rest.is_empty() || rest.ends_with('.'))
                })
        }
        None => false,
    }
}

enum ProxiedAccess {
    /// A valid cookie or header.
    Granted,
    /// A valid `?__chatmux_capability=` (and nothing invalid).
    Bootstrap,
    Denied,
}

fn capability_matches(presented: &str, expected: &str) -> bool {
    use subtle::ConstantTimeEq as _;
    !expected.is_empty() && bool::from(presented.as_bytes().ct_eq(expected.as_bytes()))
}

/// Raw `name=value` items of a query (no decoding: the capability is hex).
fn query_items(query: &str) -> impl Iterator<Item = (&str, &str)> {
    query
        .split('&')
        .filter(|item| !item.is_empty())
        .map(|item| item.split_once('=').unwrap_or((item, "")))
}

/// `name=value` items of every `Cookie` header.
fn cookie_items(headers: &hyper::HeaderMap) -> impl Iterator<Item = (&str, &str)> {
    headers
        .get_all(hyper::header::COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(';'))
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(|item| {
            item.split_once('=')
                .map(|(name, value)| (name.trim(), value.trim()))
                .unwrap_or((item, ""))
        })
}

fn proxied_access(
    shared: &ProxyShared,
    request: &hyper::Request<hyper::body::Incoming>,
) -> ProxiedAccess {
    let expected = shared.capability.as_str();
    // A presented query capability must be right: a wrong one never falls
    // back to a cookie, so a link cannot carry a stale or forged value.
    let mut query_presented = false;
    for (name, value) in query_items(request.uri().query().unwrap_or_default()) {
        if name == CAPABILITY_QUERY {
            if !capability_matches(value, expected) {
                return ProxiedAccess::Denied;
            }
            query_presented = true;
        }
    }
    let header_ok = request
        .headers()
        .get_all(CAPABILITY_HEADER)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .any(|value| capability_matches(value.trim(), expected));
    let cookie_ok = cookie_items(request.headers()).any(|(name, value)| {
        name == shared.capability_cookie && capability_matches(value, expected)
    });
    if header_ok || cookie_ok {
        ProxiedAccess::Granted
    } else if query_presented {
        ProxiedAccess::Bootstrap
    } else {
        ProxiedAccess::Denied
    }
}

/// The request's path and query without the capability parameter.
fn path_without_capability(uri: &hyper::Uri) -> String {
    let path = uri.path();
    let Some(query) = uri.query() else { return path.to_owned() };
    let kept = query
        .split('&')
        .filter(|item| !item.is_empty() && item.split('=').next() != Some(CAPABILITY_QUERY))
        .collect::<Vec<_>>();
    if kept.is_empty() { path.to_owned() } else { format!("{path}?{}", kept.join("&")) }
}

/// 302 to the same URL without the capability, setting the HttpOnly
/// cookie. `Secure` rides public (tunnel) names, which are always https.
fn bootstrap_response(
    shared: &ProxyShared,
    request: &hyper::Request<hyper::body::Incoming>,
) -> hyper::Response<ProxyBody> {
    let secure = request
        .headers()
        .get(hyper::header::HOST)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| url::Url::parse(&format!("http://{value}/")).ok())
        .is_some_and(|url| match url.host() {
            Some(url::Host::Domain(name)) => {
                let name = name.trim_end_matches('.').to_ascii_lowercase();
                name != "localhost" && !name.ends_with(".localhost")
            }
            _ => false,
        });
    let cookie = format!(
        "{}={}; Path=/; HttpOnly; SameSite=Lax{}",
        shared.capability_cookie,
        shared.capability,
        if secure { "; Secure" } else { "" },
    );
    let mut response = hyper::Response::new(full_body(Vec::new()));
    *response.status_mut() = hyper::StatusCode::FOUND;
    let headers = response.headers_mut();
    if let (Ok(location), Ok(cookie)) = (
        hyper::header::HeaderValue::from_str(&path_without_capability(request.uri())),
        hyper::header::HeaderValue::from_str(&cookie),
    ) {
        headers.insert(hyper::header::LOCATION, location);
        headers.insert(hyper::header::SET_COOKIE, cookie);
    }
    headers
        .insert(hyper::header::CACHE_CONTROL, hyper::header::HeaderValue::from_static("no-store"));
    headers.insert(
        hyper::header::REFERRER_POLICY,
        hyper::header::HeaderValue::from_static("no-referrer"),
    );
    response
}

/// {"targetConnected": bool}. The web devtools drawer polls this endpoint
/// cross-origin with credentials, so a granted reply must echo the origin
/// and allow credentials (a wildcard would be rejected by the browser).
/// The grant itself is deny-by-default: it needs the per-preview
/// capability from `preview_open` plus the same origin admission as the
/// devtools socket, so an arbitrary website cannot read preview state.
/// Requests without an Origin answer plainly, with no cross-origin grant.
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
    let granted = request_capability_allowed(request, &shared.capability)
        && control_origin_allowed(request.headers(), PeerRole::Devtools);
    if granted && let Some(origin) = request.headers().get(hyper::header::ORIGIN) {
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

/// Browsers attach an `Origin` to every WebSocket handshake but apply no
/// same-origin policy to it, so any page the user visits can dial the
/// proxy's loopback port and drive the preview page over CDP. Admission:
///
/// - no Origin: a non-browser client (the tunnel health checks, tests);
/// - loopback Host (direct local access): the Origin must be a loopback
///   origin too, which refuses every public website;
/// - public Host (the TLS tunnel forwards Host verbatim): the Origin must be
///   https, which refuses DNS-rebinding pages (they cannot present TLS for
///   the rebound name). The page connector dials its own host, so the page
///   channel must also be same-origin. The DevTools frontend is served by
///   the chatmux web app, whose origin this relay is not told. The status
///   endpoint's cross-origin read grant reuses the Devtools admission.
fn control_origin_allowed(headers: &hyper::HeaderMap, role: PeerRole) -> bool {
    let Some(origin) = headers.get(hyper::header::ORIGIN) else {
        return true;
    };
    let Some(origin) = origin.to_str().ok().and_then(|value| url::Url::parse(value).ok()) else {
        return false;
    };
    if !matches!(origin.scheme(), "http" | "https") {
        return false;
    }
    let Some(host) = headers
        .get(hyper::header::HOST)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| url::Url::parse(&format!("https://{value}")).ok())
    else {
        return false;
    };
    let (Some(origin_host), Some(request_host)) = (origin.host(), host.host()) else {
        return false;
    };
    if is_loopback_host(&request_host) {
        return is_loopback_host(&origin_host);
    }
    if origin.scheme() != "https" {
        return false;
    }
    match role {
        PeerRole::Page => {
            origin_host == request_host
                && origin.port_or_known_default() == host.port_or_known_default()
        }
        PeerRole::Devtools => true,
    }
}

fn is_loopback_host(host: &url::Host<&str>) -> bool {
    match host {
        url::Host::Domain(name) => {
            let name = name.trim_end_matches('.');
            name.eq_ignore_ascii_case("localhost")
                || name.to_ascii_lowercase().ends_with(".localhost")
        }
        url::Host::Ipv4(address) => address.is_loopback(),
        url::Host::Ipv6(address) => address.is_loopback(),
    }
}

fn accept_control_websocket(
    shared: Arc<ProxyShared>,
    request: hyper::Request<hyper::body::Incoming>,
    role: PeerRole,
) -> hyper::Response<ProxyBody> {
    if !request_capability_allowed(&request, &shared.capability)
        || !control_origin_allowed(request.headers(), role)
    {
        return text_response(403, "origin not allowed");
    }
    accept_websocket(shared, request, role)
}

/// A control request proves it belongs to this preview by presenting the
/// capability `preview_open` returned (the injected connector receives it
/// in its script URL, the devtools frontend over the relay wire). Values
/// are compared in constant time so a guesser learns nothing from
/// response latency; the length is public (64 hex characters).
fn request_capability_allowed(
    request: &hyper::Request<hyper::body::Incoming>,
    expected: &str,
) -> bool {
    use subtle::ConstantTimeEq as _;
    request.uri().query().is_some_and(|query| {
        url::form_urlencoded::parse(query.as_bytes()).any(|(name, value)| {
            name == "capability" && bool::from(value.as_bytes().ct_eq(expected.as_bytes()))
        })
    })
}

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

const NO_INJECT_HEADER: &str = "x-chatmux-no-inject";
/// HTML responses are buffered only for injection, so bound both memory and
/// time spent waiting on a target that never finishes its response.
const PREVIEW_HTML_BODY_MAX_BYTES: usize = 8 * 1024 * 1024;
const PREVIEW_HTML_BODY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

async fn connect_target(
    shared: &ProxyShared,
) -> Result<
    (hyper::client::conn::http1::SendRequest<hyper::body::Incoming>, tokio::task::JoinHandle<()>),
    hyper::Response<ProxyBody>,
> {
    let stream = tokio::net::TcpStream::connect(("127.0.0.1", shared.target_port)).await.map_err(
        |error| text_response(502, &format!("preview target port is not reachable: {error}")),
    )?;
    let io = hyper_util::rt::TokioIo::new(stream);
    let (sender, connection) = hyper::client::conn::http1::handshake(io)
        .await
        .map_err(|error| text_response(502, &format!("target handshake failed: {error}")))?;
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
    shared: &ProxyShared,
    parts: &http::request::Parts,
    body: hyper::body::Incoming,
) -> Result<hyper::Request<hyper::body::Incoming>, String> {
    // The preview capability never reaches the dev server: not in the
    // query, the capability header, or the Cookie header.
    let uri = path_without_capability(&parts.uri);
    let mut builder = hyper::Request::builder().method(parts.method.clone()).uri(uri);
    if let Some(headers) = builder.headers_mut() {
        for (name, value) in &parts.headers {
            if name == hyper::header::ACCEPT_ENCODING
                || name == CAPABILITY_HEADER
                || name == hyper::header::COOKIE
            {
                continue;
            }
            headers.append(name.clone(), value.clone());
        }
        let kept = parts
            .headers
            .get_all(hyper::header::COOKIE)
            .iter()
            .filter_map(|value| value.to_str().ok())
            .flat_map(|value| value.split(';'))
            .map(str::trim)
            .filter(|item| {
                !item.is_empty()
                    && item.split('=').next().map(str::trim) != Some(&shared.capability_cookie)
            })
            .collect::<Vec<_>>();
        if !kept.is_empty()
            && let Ok(cookie) = hyper::header::HeaderValue::from_str(&kept.join("; "))
        {
            headers.insert(hyper::header::COOKIE, cookie);
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
        Err(response) => return response,
    };
    let skip_inject = header_is_one(request.headers(), NO_INJECT_HEADER);
    let (parts, body) = request.into_parts();
    let outbound = match copy_request(&shared, &parts, body) {
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
    let injected = inject_into_html(&collected, &shared.capability);
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
    let Ok(upgrade_slot) = Arc::clone(&shared.upgrade_slots).try_acquire_owned() else {
        return text_response(503, "preview upgrade capacity exhausted");
    };
    let (mut sender, _driver) = match connect_target(&shared).await {
        Ok(ready) => ready,
        Err(response) => return response,
    };
    let (mut parts, body) = request.into_parts();
    let Some(server_upgrade) = parts.extensions.remove::<hyper::upgrade::OnUpgrade>() else {
        return text_response(502, "upgrade requested without an upgradable connection");
    };
    let outbound = match copy_request(&shared, &parts, body) {
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
        let _upgrade_slot = upgrade_slot;
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
fn inject_into_html(html: &[u8], capability: &str) -> Vec<u8> {
    let inject_tag =
        format!("<script src=\"/__chatmux__/target.js?capability={capability}\"></script>");
    let inject_tag = inject_tag.as_bytes();
    let mut out = Vec::with_capacity(html.len() + inject_tag.len());
    if let Some(head_end) = find_ascii_case_insensitive(html, b"</head>") {
        out.extend_from_slice(&html[..head_end]);
        out.extend_from_slice(inject_tag);
        out.extend_from_slice(&html[head_end..]);
        return out;
    }
    if let Some(body_start) = find_ascii_case_insensitive(html, b"<body")
        && let Some(tag_close) =
            html[body_start..].iter().position(|byte| *byte == b'>').map(|at| body_start + at + 1)
    {
        out.extend_from_slice(&html[..tag_close]);
        out.extend_from_slice(inject_tag);
        out.extend_from_slice(&html[tag_close..]);
        return out;
    }
    out.extend_from_slice(inject_tag);
    out.extend_from_slice(html);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::{SinkExt as _, StreamExt as _};
    use serde_json::Value;
    use std::io;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
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
                        if request.uri().path() == "/echo" {
                            // What the dev server sees of the request: the
                            // query, every Cookie value and the capability
                            // header, one per line.
                            let mut seen =
                                format!("query={}\n", request.uri().query().unwrap_or_default());
                            for value in request.headers().get_all(hyper::header::COOKIE) {
                                seen.push_str(&format!(
                                    "cookie={}\n",
                                    value.to_str().unwrap_or_default()
                                ));
                            }
                            for value in request.headers().get_all("x-chatmux-capability") {
                                seen.push_str(&format!(
                                    "header={}\n",
                                    value.to_str().unwrap_or_default()
                                ));
                            }
                            let mut response = hyper::Response::new(full_body(seen.into_bytes()));
                            response.headers_mut().insert(
                                hyper::header::CONTENT_TYPE,
                                hyper::header::HeaderValue::from_static("text/plain"),
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

    async fn spawn_upgrade_target() -> u16 {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.expect("target bind");
        let port = listener.local_addr().expect("target addr").port();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else { break };
                tokio::spawn(async move {
                    let io = hyper_util::rt::TokioIo::new(stream);
                    let service = hyper::service::service_fn(|request| async move {
                        let on_upgrade = hyper::upgrade::on(request);
                        let response = hyper::Response::builder()
                            .status(hyper::StatusCode::SWITCHING_PROTOCOLS)
                            .header(hyper::header::UPGRADE, "websocket")
                            .header(hyper::header::CONNECTION, "Upgrade")
                            .body(full_body(Vec::new()))
                            .expect("upgrade response");
                        tokio::spawn(async move {
                            if let Ok(upgraded) = on_upgrade.await {
                                let _ = tokio::time::sleep(Duration::from_secs(30)).await;
                                drop(upgraded);
                            }
                        });
                        Ok::<_, std::convert::Infallible>(response)
                    });
                    let _ = hyper::server::conn::http1::Builder::new()
                        .serve_connection(io, service)
                        .with_upgrades()
                        .await;
                });
            }
        });
        port
    }

    async fn open_proxy(registry: &PreviewRegistry, target_port: u16) -> u16 {
        open_proxy_credentials(registry, target_port).await.0
    }

    async fn open_proxy_credentials(registry: &PreviewRegistry, target_port: u16) -> (u16, String) {
        match registry.open(i64::from(target_port)).await.expect("preview_open") {
            wire::WorkspaceResultBody::PreviewOpen(result) => {
                (u16::try_from(result.proxy_port).expect("port range"), result.capability)
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

    async fn open_upgrade(port: u16, key: &str, capability: &str) -> tokio::net::TcpStream {
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .expect("connect preview proxy");
        let request = format!(
            "GET /hmr HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n{CAPABILITY_HEADER}: {capability}\r\n\r\n"
        );
        stream.write_all(request.as_bytes()).await.expect("write upgrade request");
        let mut response = Vec::new();
        let mut chunk = [0_u8; 512];
        loop {
            let read = tokio::time::timeout(Duration::from_secs(2), stream.read(&mut chunk))
                .await
                .expect("upgrade response timeout")
                .expect("read upgrade response");
            assert!(read > 0, "upgrade response ended before headers");
            response.extend_from_slice(&chunk[..read]);
            if response.windows(4).any(|window| window == b"\r\n\r\n") {
                break;
            }
            assert!(response.len() < 8192, "upgrade response headers too large");
        }
        assert!(response.starts_with(b"HTTP/1.1 101"), "upgrade response: {response:?}");
        stream
    }

    #[tokio::test]
    async fn injects_into_html_and_honors_the_opt_outs() {
        let registry = PreviewRegistry::new();
        let target = spawn_target().await;
        let (proxy, capability) = open_proxy_credentials(&registry, target).await;
        let (status, _, body) = http_get(proxy, "/", &[(CAPABILITY_HEADER, &capability)]).await;
        assert_eq!(status, 200);
        let tag_at =
            body.find("<script src=\"/__chatmux__/target.js?capability=").expect("tag injected");
        assert!(body[tag_at..].contains(&format!("capability={capability}")));
        let head_at = body.find("</head>").expect("head kept");
        assert!(tag_at < head_at, "before </head>");

        let (_, _, body) = http_get(proxy, "/body-only", &[(CAPABILITY_HEADER, &capability)]).await;
        let tag_at =
            body.find("<script src=\"/__chatmux__/target.js?capability=").expect("tag injected");
        assert!(body[..tag_at].contains("<body>"), "after the <body> tag");

        let (_, _, body) = http_get(proxy, "/plain", &[(CAPABILITY_HEADER, &capability)]).await;
        assert!(!body.contains("/__chatmux__/target.js?capability="), "non-HTML passes through");

        let (_, _, body) = http_get(proxy, "/opt-out", &[(CAPABILITY_HEADER, &capability)]).await;
        assert!(!body.contains("/__chatmux__/target.js?capability="), "response header opts out");

        let (status, _, body) =
            http_get(proxy, "/oversized", &[(CAPABILITY_HEADER, &capability)]).await;
        assert_eq!(status, 502);
        assert!(body.contains("target HTML response exceeds"));

        let (_, _, body) =
            http_get(proxy, "/", &[(NO_INJECT_HEADER, "1"), (CAPABILITY_HEADER, &capability)])
                .await;
        assert!(!body.contains("/__chatmux__/target.js?capability="), "request header opts out");

        // Reuse: the same target port keeps its proxy port.
        let (reused_proxy, reused_capability) = open_proxy_credentials(&registry, target).await;
        assert_eq!(reused_proxy, proxy);
        assert_eq!(reused_capability, capability);
        registry.shutdown().await;
        assert!(registry.proxies.lock().await.is_empty(), "shutdown drops every proxy");
    }

    #[tokio::test]
    async fn rejects_preview_connections_after_the_active_connection_cap() {
        let registry = PreviewRegistry::new();
        let target = spawn_target().await;
        let proxy = open_proxy(&registry, target).await;
        let mut held = Vec::with_capacity(PREVIEW_PROXY_CONNECTION_CAP);
        for _ in 0..PREVIEW_PROXY_CONNECTION_CAP {
            let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", proxy))
                .await
                .expect("connect preview proxy");
            stream
                .write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\n")
                .await
                .expect("hold preview request open");
            held.push(stream);
        }
        tokio::task::yield_now().await;

        let mut rejected = tokio::net::TcpStream::connect(("127.0.0.1", proxy))
            .await
            .expect("connect over-cap preview client");
        rejected
            .write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .await
            .expect("write over-cap preview request");
        let mut response = [0_u8; 1];
        let read = tokio::time::timeout(Duration::from_secs(1), rejected.read(&mut response))
            .await
            .expect("over-cap preview client did not close");
        match read {
            Ok(0) => {}
            Err(error) => assert!(matches!(
                error.kind(),
                io::ErrorKind::ConnectionReset | io::ErrorKind::UnexpectedEof
            )),
            Ok(bytes) => panic!("over-cap preview client received {bytes} bytes"),
        }
        drop(held);
        registry.shutdown().await;
    }

    #[tokio::test]
    async fn rejects_upgrades_after_the_copy_task_cap() {
        let registry = PreviewRegistry::new();
        let target = spawn_upgrade_target().await;
        let (proxy, capability) = open_proxy_credentials(&registry, target).await;
        let mut held = Vec::with_capacity(PREVIEW_PROXY_UPGRADE_CAP);
        for index in 0..PREVIEW_PROXY_UPGRADE_CAP {
            held.push(
                open_upgrade(proxy, &format!("dGhlIHNhbXBsZSA{index:02}"), &capability).await,
            );
        }

        let mut over_cap = tokio::net::TcpStream::connect(("127.0.0.1", proxy))
            .await
            .expect("connect over-cap upgrade");
        over_cap
            .write_all(
                format!(
                    "GET /hmr HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSA2NA==\r\nSec-WebSocket-Version: 13\r\n{CAPABILITY_HEADER}: {capability}\r\n\r\n"
                )
                .as_bytes(),
            )
            .await
            .expect("write over-cap upgrade");
        let mut response = [0_u8; 512];
        let bytes = tokio::time::timeout(Duration::from_secs(2), over_cap.read(&mut response))
            .await
            .expect("over-cap response timeout")
            .expect("read over-cap response");
        assert!(
            std::str::from_utf8(&response[..bytes])
                .expect("response utf8")
                .starts_with("HTTP/1.1 503")
        );

        drop(held);
        registry.shutdown().await;
    }

    /// One raw HTTP/1.1 exchange against the proxy, returning the response
    /// head (status line plus headers) lowercased. Lets a test pin the Host
    /// header, which reqwest always derives from the URL.
    async fn raw_response_head(port: u16, request: &str) -> String {
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .expect("connect preview proxy");
        stream.write_all(request.as_bytes()).await.expect("write raw request");
        let mut response = Vec::new();
        let mut chunk = [0_u8; 1024];
        loop {
            let read = tokio::time::timeout(Duration::from_secs(2), stream.read(&mut chunk))
                .await
                .expect("raw response timeout")
                .expect("read raw response");
            if read == 0 {
                break;
            }
            response.extend_from_slice(&chunk[..read]);
            if let Some(end) = response.windows(4).position(|window| window == b"\r\n\r\n") {
                response.truncate(end);
                break;
            }
            assert!(response.len() < 16_384, "raw response head too large");
        }
        String::from_utf8(response).expect("raw response utf8").to_ascii_lowercase()
    }

    #[tokio::test]
    async fn status_cors_grant_requires_the_preview_capability() {
        let registry = PreviewRegistry::with_public_host_suffixes(["preview.test"]);
        let target = spawn_target().await;
        let (proxy, capability) = open_proxy_credentials(&registry, target).await;
        let origin = "http://localhost:3000";

        // An Origin without the preview capability gets no cross-origin
        // read grant: an arbitrary website must not learn preview state.
        let (status, headers, _) =
            http_get(proxy, "/__chatmux__/status", &[("origin", origin)]).await;
        assert_eq!(status, 200);
        assert!(headers.get("access-control-allow-origin").is_none());
        assert!(headers.get("access-control-allow-credentials").is_none());

        // A guessed value of the right shape is refused the same way.
        let wrong = "0".repeat(capability.len());
        let (_, headers, _) = http_get(
            proxy,
            &format!("/__chatmux__/status?capability={wrong}"),
            &[("origin", origin)],
        )
        .await;
        assert!(headers.get("access-control-allow-origin").is_none());

        // The devtools drawer presents the capability preview_open handed
        // it and keeps its credentialed cross-origin poll.
        let (status, headers, body) = http_get(
            proxy,
            &format!("/__chatmux__/status?capability={capability}"),
            &[("origin", origin)],
        )
        .await;
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

        // Even with the capability, an origin the devtools admission
        // refuses (a public website against the loopback listener) gets no
        // grant.
        let (_, headers, _) = http_get(
            proxy,
            &format!("/__chatmux__/status?capability={capability}"),
            &[("origin", "https://evil.example")],
        )
        .await;
        assert!(headers.get("access-control-allow-origin").is_none());

        // Same-origin probes (no Origin header) stay plain.
        let (status, headers, body) = http_get(proxy, "/__chatmux__/status", &[]).await;
        assert_eq!(status, 200);
        assert_eq!(body, "{\"targetConnected\":false}");
        assert!(headers.get("access-control-allow-origin").is_none());

        // The tunneled drawer (public Host, https Origin) keeps its grant
        // when it presents the capability...
        let head = raw_response_head(
            proxy,
            &format!(
                "GET /__chatmux__/status?capability={capability} HTTP/1.1\r\nHost: p1.preview.test\r\nOrigin: https://chatmux.dev\r\nConnection: close\r\n\r\n"
            ),
        )
        .await;
        assert!(head.contains("access-control-allow-origin: https://chatmux.dev"), "{head}");
        // ...and a preflight is gated exactly like the read.
        let head = raw_response_head(
            proxy,
            &format!(
                "OPTIONS /__chatmux__/status?capability={capability} HTTP/1.1\r\nHost: localhost\r\nOrigin: {origin}\r\nAccess-Control-Request-Headers: x-requested-with\r\nConnection: close\r\n\r\n"
            ),
        )
        .await;
        assert!(head.starts_with("http/1.1 204"), "{head}");
        assert!(head.contains(&format!("access-control-allow-origin: {origin}")), "{head}");
        assert!(head.contains("access-control-allow-headers: x-requested-with"), "{head}");
        let head = raw_response_head(
            proxy,
            &format!(
                "OPTIONS /__chatmux__/status HTTP/1.1\r\nHost: localhost\r\nOrigin: {origin}\r\nConnection: close\r\n\r\n"
            ),
        )
        .await;
        assert!(head.starts_with("http/1.1 204"), "{head}");
        assert!(!head.contains("access-control-allow-origin"), "{head}");
        registry.shutdown().await;
    }

    #[tokio::test]
    async fn serves_the_vendored_connector_bundle() {
        let registry = PreviewRegistry::new();
        let target = spawn_target().await;
        let proxy = open_proxy(&registry, target).await;
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
        assert!(body.contains("searchParams.get('capability')"));
        registry.shutdown().await;
    }

    async fn connect_ws(
        port: u16,
        path: &str,
        capability: &str,
    ) -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>
    {
        let (socket, _) = tokio_tungstenite::connect_async(format!(
            "ws://127.0.0.1:{port}{path}?capability={capability}"
        ))
        .await
        .expect("ws connect");
        socket
    }

    async fn next_text<S>(socket: &mut S, what: &str) -> String
    where
        S: futures_util::Stream<Item = Result<Message, tungstenite::Error>> + Unpin,
    {
        loop {
            let message = tokio::time::timeout(Duration::from_secs(10), socket.next())
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
        let (proxy, capability) = open_proxy_credentials(&registry, target).await;

        // Fake CDP page peer: the proxy enables its tee domains first.
        let mut page = connect_ws(proxy, "/__chatmux__/page", &capability).await;
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
        let mut devtools = connect_ws(proxy, "/__chatmux__/devtools", &capability).await;
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
        let tail = tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let body = registry.tail(None).expect("tail");
                let wire::WorkspaceResultBody::PreviewConsoleTail(result) = &body else {
                    panic!("wrong body");
                };
                if result.events.len() >= 2 {
                    break result.events.clone();
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
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
        let mut replacement = connect_ws(proxy, "/__chatmux__/page", &capability).await;
        let closed = tokio::time::timeout(Duration::from_secs(10), async {
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

    type TestSocket = tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >;

    async fn ws_handshake(
        port: u16,
        path: &str,
        capability: Option<&str>,
        headers: &[(&str, &str)],
    ) -> Result<TestSocket, tungstenite::Error> {
        use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
        let path = capability
            .map(|capability| format!("{path}?capability={capability}"))
            .unwrap_or_else(|| path.to_owned());
        let mut request =
            format!("ws://127.0.0.1:{port}{path}").into_client_request().expect("ws request");
        for (name, value) in headers {
            request.headers_mut().insert(
                hyper::header::HeaderName::from_bytes(name.as_bytes()).expect("header name"),
                hyper::header::HeaderValue::from_str(value).expect("header value"),
            );
        }
        tokio_tungstenite::connect_async(request).await.map(|(socket, _)| socket)
    }

    fn refused_with_forbidden(outcome: Result<TestSocket, tungstenite::Error>) -> bool {
        matches!(outcome, Err(tungstenite::Error::Http(response)) if response.status() == 403)
    }

    #[tokio::test]
    async fn control_sockets_refuse_cross_site_browser_origins() {
        let registry = PreviewRegistry::with_public_host_suffixes(["preview.test"]);
        let target = spawn_target().await;
        let (proxy, capability) = open_proxy_credentials(&registry, target).await;

        // A public web page the user visits can dial the loopback port; its
        // browser stamps the page's Origin on the handshake.
        for path in ["/__chatmux__/page", "/__chatmux__/devtools"] {
            for origin in ["https://evil.example", "http://evil.example", "null"] {
                let outcome =
                    ws_handshake(proxy, path, Some(&capability), &[("origin", origin)]).await;
                assert!(refused_with_forbidden(outcome), "{path} accepted Origin {origin}");
            }
        }
        // DNS rebinding: a plain-http page whose name now resolves to
        // loopback. Its Host is its own name, and it cannot present TLS.
        let rebinding_host = format!("rebind.example:{proxy}");
        let rebinding_origin = format!("http://{rebinding_host}");
        let outcome = ws_handshake(
            proxy,
            "/__chatmux__/devtools",
            Some(&capability),
            &[("host", &rebinding_host), ("origin", &rebinding_origin)],
        )
        .await;
        assert!(refused_with_forbidden(outcome), "rebinding origin accepted");
        // Through the TLS tunnel the page channel stays same-origin only.
        let outcome = ws_handshake(
            proxy,
            "/__chatmux__/page",
            Some(&capability),
            &[("host", "p1.preview.test"), ("origin", "https://chatmux.dev")],
        )
        .await;
        assert!(refused_with_forbidden(outcome), "cross-origin page accepted");
        // A sibling preview can present a valid HTTPS Origin, but cannot know
        // this preview's capability and therefore cannot attach its DevTools.
        let outcome = ws_handshake(
            proxy,
            "/__chatmux__/devtools",
            None,
            &[("host", "p1.preview.test"), ("origin", "https://q1.preview.test")],
        )
        .await;
        assert!(refused_with_forbidden(outcome), "sibling preview attached without capability");
        // A guessed capability of the right shape is refused on both
        // control sockets.
        let wrong_capability = "0".repeat(capability.len());
        for path in ["/__chatmux__/page", "/__chatmux__/devtools"] {
            let outcome = ws_handshake(proxy, path, Some(&wrong_capability), &[]).await;
            assert!(refused_with_forbidden(outcome), "{path} accepted a guessed capability");
        }

        // The legitimate peers still connect: the injected connector on the
        // proxy's own origin, a local DevTools frontend, the tunneled page,
        // the chatmux web app's DevTools drawer, and non-browser clients.
        let local_origin = format!("http://127.0.0.1:{proxy}");
        ws_handshake(proxy, "/__chatmux__/page", Some(&capability), &[("origin", &local_origin)])
            .await
            .expect("same-origin loopback page");
        ws_handshake(
            proxy,
            "/__chatmux__/devtools",
            Some(&capability),
            &[("origin", "http://localhost:3000")],
        )
        .await
        .expect("loopback devtools");
        ws_handshake(
            proxy,
            "/__chatmux__/page",
            Some(&capability),
            &[("host", "p1.preview.test"), ("origin", "https://p1.preview.test")],
        )
        .await
        .expect("tunneled same-origin page");
        ws_handshake(
            proxy,
            "/__chatmux__/devtools",
            Some(&capability),
            &[("host", "p1.preview.test"), ("origin", "https://chatmux.dev")],
        )
        .await
        .expect("tunneled devtools drawer");
        ws_handshake(proxy, "/__chatmux__/devtools", Some(&capability), &[])
            .await
            .expect("originless client");
        registry.shutdown().await;
    }

    /// The full raw HTTP/1.1 response (head and body) of one request that
    /// asks the proxy to close the connection.
    async fn raw_exchange(port: u16, request: &str) -> String {
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .expect("connect preview proxy");
        stream.write_all(request.as_bytes()).await.expect("write raw request");
        let mut response = Vec::new();
        tokio::time::timeout(Duration::from_secs(5), stream.read_to_end(&mut response))
            .await
            .expect("raw exchange timeout")
            .expect("read raw exchange");
        String::from_utf8(response).expect("raw exchange utf8")
    }

    fn get_request(path: &str, host: &str, extra: &str) -> String {
        format!("GET {path} HTTP/1.1\r\nHost: {host}\r\n{extra}Connection: close\r\n\r\n")
    }

    fn upgrade_request(path: &str, host: &str, extra: &str) -> String {
        format!(
            "GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n{extra}\r\n"
        )
    }

    #[tokio::test]
    async fn proxied_requests_and_upgrades_require_the_preview_capability() {
        let registry = PreviewRegistry::new();
        let target = spawn_target().await;
        let (proxy, capability) = open_proxy_credentials(&registry, target).await;
        let host = format!("localhost:{proxy}");
        let cookie = format!("__chatmux_preview_{proxy}");
        let wrong = "0".repeat(capability.len());

        // Missing and wrong capabilities: no byte of the dev server leaks.
        for extra in [
            String::new(),
            format!("x-chatmux-capability: {wrong}\r\n"),
            format!("Cookie: {cookie}={wrong}\r\n"),
        ] {
            let response = raw_exchange(proxy, &get_request("/", &host, &extra)).await;
            assert!(response.starts_with("HTTP/1.1 401"), "{extra:?}: {response}");
            assert!(!response.contains("<title>t</title>"), "{extra:?} leaked the page");
        }
        let response = raw_exchange(
            proxy,
            &get_request(&format!("/?__chatmux_capability={wrong}"), &host, ""),
        )
        .await;
        assert!(response.starts_with("HTTP/1.1 401"), "wrong bootstrap: {response}");

        // A valid header passes.
        let response = raw_exchange(
            proxy,
            &get_request("/", &host, &format!("x-chatmux-capability: {capability}\r\n")),
        )
        .await;
        assert!(response.starts_with("HTTP/1.1 200"), "header: {response}");
        assert!(response.contains("<title>t</title>"));

        // The navigation bootstrap trades the query capability for an
        // HttpOnly cookie and drops it from the visible URL.
        let response = raw_exchange(
            proxy,
            &get_request(&format!("/app?__chatmux_capability={capability}&x=1"), &host, ""),
        )
        .await;
        let lower = response.to_ascii_lowercase();
        assert!(lower.starts_with("http/1.1 302"), "bootstrap: {response}");
        assert!(lower.contains("\r\nlocation: /app?x=1\r\n"), "bootstrap: {response}");
        let set_cookie = lower
            .lines()
            .find(|line| line.starts_with("set-cookie:"))
            .expect("bootstrap sets a cookie")
            .to_owned();
        assert!(set_cookie.contains(&format!("{cookie}={capability}")), "{set_cookie}");
        assert!(set_cookie.contains("httponly"), "{set_cookie}");
        assert!(set_cookie.contains("path=/"), "{set_cookie}");

        // The cookie passes, and the dev server never sees the credential
        // (other cookies of the app still reach it).
        let response = raw_exchange(
            proxy,
            &get_request("/", &host, &format!("Cookie: {cookie}={capability}\r\n")),
        )
        .await;
        assert!(response.starts_with("HTTP/1.1 200"), "cookie: {response}");
        let response = raw_exchange(
            proxy,
            &get_request(
                "/echo?a=1",
                &host,
                &format!(
                    "Cookie: app=1; {cookie}={capability}; theme=dark\r\nx-chatmux-capability: {capability}\r\n"
                ),
            ),
        )
        .await;
        assert!(response.starts_with("HTTP/1.1 200"), "echo: {response}");
        assert!(!response.contains(&capability), "the dev server saw the capability: {response}");
        assert!(response.contains("cookie=app=1; theme=dark"), "{response}");
        assert!(response.contains("query=a=1"), "{response}");

        // Upstream WebSocket upgrades (a dev server's HMR socket) need it too.
        let upgrade_target = spawn_upgrade_target().await;
        let (upgrade_proxy, upgrade_capability) =
            open_proxy_credentials(&registry, upgrade_target).await;
        let upgrade_host = format!("localhost:{upgrade_proxy}");
        let upgrade_cookie = format!("__chatmux_preview_{upgrade_proxy}");
        for extra in [String::new(), format!("Cookie: {upgrade_cookie}={wrong}\r\n")] {
            let head =
                raw_response_head(upgrade_proxy, &upgrade_request("/hmr", &upgrade_host, &extra))
                    .await;
            assert!(head.starts_with("http/1.1 401"), "upgrade {extra:?}: {head}");
        }
        let head = raw_response_head(
            upgrade_proxy,
            &upgrade_request(
                "/hmr",
                &upgrade_host,
                &format!("Cookie: {upgrade_cookie}={upgrade_capability}\r\n"),
            ),
        )
        .await;
        assert!(head.starts_with("http/1.1 101"), "upgrade with cookie: {head}");
        registry.shutdown().await;
    }

    #[tokio::test]
    async fn a_rebinding_host_is_refused_on_every_path() {
        let registry = PreviewRegistry::new();
        let target = spawn_target().await;
        let (proxy, capability) = open_proxy_credentials(&registry, target).await;
        let cookie = format!("__chatmux_preview_{proxy}");
        let credential = format!("x-chatmux-capability: {capability}\r\n");
        let rebinding = format!("rebind.example:{proxy}");

        // A DNS-rebound page sends its own name as Host. Even a request that
        // carries the capability (a cookie the browser would not send to
        // that name anyway) is refused on proxied and control paths.
        for path in ["/", "/plain", "/__chatmux__/status", "/__chatmux__/target.js"] {
            let response = raw_exchange(proxy, &get_request(path, &rebinding, &credential)).await;
            assert!(response.starts_with("HTTP/1.1 403"), "{path}: {response}");
        }
        for host in ["rebind.example", "localhost.rebind.example", "evil@localhost"] {
            let response = raw_exchange(proxy, &get_request("/", host, &credential)).await;
            assert!(response.starts_with("HTTP/1.1 403"), "{host}: {response}");
        }
        let response = raw_exchange(
            proxy,
            &format!("GET / HTTP/1.1\r\n{credential}Connection: close\r\n\r\n"),
        )
        .await;
        assert!(!response.starts_with("HTTP/1.1 200"), "a request without Host: {response}");

        // Rebinding on a WebSocket upgrade: the dev server's HMR socket and
        // both control sockets (an originless handshake included).
        let upgrade_target = spawn_upgrade_target().await;
        let (upgrade_proxy, upgrade_capability) =
            open_proxy_credentials(&registry, upgrade_target).await;
        let head = raw_response_head(
            upgrade_proxy,
            &upgrade_request(
                "/hmr",
                &format!("rebind.example:{upgrade_proxy}"),
                &format!("Cookie: __chatmux_preview_{upgrade_proxy}={upgrade_capability}\r\n"),
            ),
        )
        .await;
        assert!(head.starts_with("http/1.1 403"), "hmr upgrade: {head}");
        for path in ["/__chatmux__/page", "/__chatmux__/devtools"] {
            let outcome =
                ws_handshake(proxy, path, Some(&capability), &[("host", &rebinding)]).await;
            assert!(refused_with_forbidden(outcome), "{path} accepted a rebinding Host");
        }

        // Loopback names and address literals stay allowed.
        for host in [
            format!("localhost:{proxy}"),
            format!("app.localhost:{proxy}"),
            format!("127.0.0.1:{proxy}"),
            format!("[::1]:{proxy}"),
            "localhost.".to_owned(),
            format!("10.0.0.5:{proxy}"),
        ] {
            let response = raw_exchange(
                proxy,
                &get_request("/", &host, &format!("Cookie: {cookie}={capability}\r\n")),
            )
            .await;
            assert!(response.starts_with("HTTP/1.1 200"), "{host}: {response}");
        }
        registry.shutdown().await;
    }

    #[tokio::test]
    async fn public_preview_hosts_pass_only_under_the_configured_suffixes() {
        let registry = PreviewRegistry::with_public_host_suffixes([".Preview.Test."]);
        let target = spawn_target().await;
        let (proxy, capability) = open_proxy_credentials(&registry, target).await;
        let credential = format!("{CAPABILITY_HEADER}: {capability}\r\n");
        for host in ["p1.preview.test", "P1.Preview.Test:443", "preview.test", "p1.preview.test."] {
            let response = raw_exchange(proxy, &get_request("/", host, &credential)).await;
            assert!(response.starts_with("HTTP/1.1 200"), "{host}: {response}");
        }
        for host in ["xpreview.test", "p1.preview.test.evil.example", "preview.chatmux.dev"] {
            let response = raw_exchange(proxy, &get_request("/", host, &credential)).await;
            assert!(response.starts_with("HTTP/1.1 403"), "{host}: {response}");
        }
        // The tunnel bootstrap marks the cookie Secure (the tunnel is https).
        let response = raw_exchange(
            proxy,
            &get_request(&format!("/?{CAPABILITY_QUERY}={capability}"), "p1.preview.test", ""),
        )
        .await
        .to_ascii_lowercase();
        assert!(response.starts_with("http/1.1 302"), "{response}");
        assert!(response.contains("\r\nlocation: /\r\n"), "{response}");
        let set_cookie =
            response.lines().find(|line| line.starts_with("set-cookie:")).expect("cookie");
        assert!(set_cookie.contains("; secure"), "{set_cookie}");
        assert!(set_cookie.contains("samesite=lax"), "{set_cookie}");
        registry.shutdown().await;
        // The default registry serves the chatmux tunnel's domain.
        let registry = PreviewRegistry::new();
        let (proxy, capability) = open_proxy_credentials(&registry, target).await;
        let response = raw_exchange(
            proxy,
            &get_request(
                "/",
                "abc.preview.chatmux.dev",
                &format!("{CAPABILITY_HEADER}: {capability}\r\n"),
            ),
        )
        .await;
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        registry.shutdown().await;
    }

    #[test]
    fn control_origin_policy_table() {
        let cases: &[(Option<&str>, &str, PeerRole, bool)] = &[
            (None, "127.0.0.1:5000", PeerRole::Devtools, true),
            (Some("http://127.0.0.1:5000"), "127.0.0.1:5000", PeerRole::Page, true),
            (Some("http://[::1]:9"), "localhost:5000", PeerRole::Devtools, true),
            (Some("http://app.localhost:3000"), "127.0.0.1:5000", PeerRole::Devtools, true),
            (Some("https://evil.example"), "127.0.0.1:5000", PeerRole::Devtools, false),
            (Some("null"), "127.0.0.1:5000", PeerRole::Page, false),
            (Some("chrome-extension://abc"), "127.0.0.1:5000", PeerRole::Page, false),
            (Some("https://p.preview.test"), "p.preview.test", PeerRole::Page, true),
            (Some("https://p.preview.test"), "p.preview.test:443", PeerRole::Page, true),
            (Some("https://q.preview.test"), "p.preview.test", PeerRole::Page, false),
            (Some("https://chatmux.dev"), "p.preview.test", PeerRole::Devtools, true),
            (Some("http://rebind.example:5000"), "rebind.example:5000", PeerRole::Page, false),
            (Some("http://rebind.example:5000"), "rebind.example:5000", PeerRole::Devtools, false),
        ];
        for (origin, host, role, allowed) in cases {
            let mut headers = hyper::HeaderMap::new();
            headers.insert(hyper::header::HOST, host.parse().expect("host"));
            if let Some(origin) = origin {
                headers.insert(hyper::header::ORIGIN, origin.parse().expect("origin"));
            }
            assert_eq!(
                control_origin_allowed(&headers, *role),
                *allowed,
                "origin {origin:?} host {host}",
            );
        }
    }

    #[test]
    fn oversized_cdp_request_ids_are_not_retained() {
        let ring = ConsoleRing::new();
        let request_id = "r".repeat(1024 * 1024);
        let frame = serde_json::json!({
            "method": "Network.requestWillBeSent",
            "params": {"requestId": request_id, "request": {"method": "GET", "url": "http://x/"}},
        });
        assert_eq!(tee_cdp_frame(&ring, &frame.to_string()), None);
        let inner = ring.inner.lock().expect("ring lock");
        assert!(inner.pending.is_empty(), "an oversized request id was retained");
        assert!(inner.pending_order.is_empty(), "an oversized request id was queued");
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
