//! Client-facing side. acpmux acts as an ACP agent to every connection and
//! adds the `_acpmux/*` extension methods. Transports: Unix socket lines and
//! WebSocket text frames. Both feed `serve_connection`.

use crate::config::PermissionPolicy;
use crate::hub::{EventFilter, Hub, HubEvent, VERSION};
use crate::no_panic::JsonExt;
use crate::no_panic::LockExt;
use crate::rpc::{Message, RpcError, method};
use crate::session_identity::SessionReceipt;
use anyhow::{Context, Result};
use cmux_local_auth::{ListenerPolicy, Refusal};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
#[cfg(unix)]
use tokio::net::UnixListener;
use tokio::sync::{broadcast, mpsc};
/// Windows: the daemon socket is `cmux::local_socket` (AF_UNIX with its
/// same-user checks), in `windows_socket.rs`.
#[cfg(windows)]
pub use windows_socket::{UnixListener, bind_unix, router_admin, serve_unix};

/// How one connection receives one attached session's live records.
#[derive(Debug, Clone, Default)]
pub struct SubOpts {
    /// Every record arrives as `_acpmux/event` (agent notifications nested
    /// in `msg`) instead of `session/update` plus `_acpmux/event`.
    pub event_stream: bool,
    /// With `event_stream`, only records this filter passes are sent.
    pub filter: EventFilter,
    /// Attached without showing the chat (`view.rs`).
    pub hidden: bool,
}

pub struct Conn {
    pub id: String,
    /// The listener this connection came in on.
    pub origin: Origin,
    /// The proof it presented (`conn_auth.rs`); what the mode rule reads.
    pub auth: ConnAuth,
    /// It reads session text raw (`peer_text.rs`): every origin but a peer.
    raw_text: bool,
    name: StdMutex<String>,
    out: mpsc::Sender<String>,
    /// Number of notifications rejected because the reader fell behind.
    outbound_dropped: AtomicU64,
    /// A gap marker is already queued (or waiting for one queue slot).
    outbound_gap_pending: AtomicBool,
    subs: StdMutex<HashMap<String, SubOpts>>,
    /// Server-derived mailbox identities for this connection's local attachments.
    mailbox_bindings: StdMutex<HashMap<String, SessionReceipt>>,
    watch_all: AtomicBool,
    watch_inventory: StdMutex<bool>,
    /// The unix socket peer's audit token, read at accept (macOS); what
    /// `_acpmux/person_enroll` checks. None for WebSocket connections.
    peer: Option<cmux_link::app_caller::PeerToken>,
    /// Requests seen so far (`hub/person.rs`: initialize first, the proof second).
    requests: std::sync::atomic::AtomicU64,
    /// Its first request was an `initialize` that got the person challenge.
    challenged: AtomicBool,
    /// This connection's challenge nonce (`hub/person.rs`).
    pub(super) nonce: String,
    /// It proved the person key for its challenge.
    person: AtomicBool,
    /// `_acpmux/person_holds` calls on this connection (`hub/person.rs`).
    pub(super) holds_calls: std::sync::atomic::AtomicU32,
    /// The acpmux session it runs in, proven at its first `initialize` (`hub/person.rs` (a)).
    caller: std::sync::OnceLock<String>,
    /// The session a first unix `initialize` named with a token that did not prove it.
    pub(super) unproven_caller: std::sync::OnceLock<String>,
    /// The peers this connection leased (`hub/peer_lease.rs`); None once it
    /// closed, so a lease that settles after the close ends at once.
    peer_leases: StdMutex<Option<Vec<crate::hub::PeerLease>>>,
    /// The ephemeral sessions it created, purged when it closes (`ephemeral.rs`);
    /// None once it closed.
    ephemeral: StdMutex<Option<Vec<String>>>,
    /// The media files it opened (`hub/media_read.rs`), closed when it closes.
    media: crate::hub::media_handles::Handles,
}

impl Conn {
    /// Whether this connection is the person (`hub/person.rs`).
    pub(super) fn is_person(&self) -> bool {
        self.person.load(Ordering::SeqCst)
    }

    /// The acpmux session this connection proved it runs in (`hub/person.rs` (a)).
    pub(super) fn caller(&self) -> Option<&str> {
        self.caller.get().map(String::as_str)
    }

    /// Whether this connection gets the person challenge: the unix socket or the proven local app.
    pub(super) fn challengeable(&self) -> bool {
        matches!(self.origin, Origin::Local | Origin::LocalApp)
    }

    /// The person binding (`hub/person.rs`), in order before the request
    /// runs. A `personKey` in any request is stripped and never read. A
    /// local connection whose FIRST request is `initialize` is challenged;
    /// its SECOND request, `_acpmux/person_prove`, makes it the person when
    /// the proof matches its own nonce and id. Nothing else ever does.
    fn bind_person(&self, hub: &Hub, m: &str, params: &mut Option<Value>) {
        let _ = params.as_mut().and_then(crate::hub::person::take_key);
        // Stripped from every request; read from a first unix `initialize` only (person.rs (a)).
        let caller = params.as_mut().and_then(crate::hub::person::take_caller);
        let n = self.requests.fetch_add(1, Ordering::SeqCst) + 1;
        if n == 1 && m == method::INITIALIZE && self.challengeable() {
            self.challenged.store(true, Ordering::SeqCst);
        }
        let first_local = n == 1 && m == method::INITIALIZE && self.origin == Origin::Local;
        if let Some((id, token)) = caller.filter(|_| first_local) {
            let proven = hub.proven_caller((id.clone(), token)).is_some();
            let _ = if proven { &self.caller } else { &self.unproven_caller }.set(id);
        }
        if n == 2 && m == method::MUX_PERSON_PROVE && self.challenged.load(Ordering::SeqCst) {
            let proof = params.as_ref().and_then(|p| p.get("proof")).and_then(Value::as_str);
            let transport = match self.origin {
                Origin::LocalApp => crate::hub::person::TRANSPORT_APP,
                _ => crate::hub::person::TRANSPORT_UNIX,
            };
            if proof.is_some_and(|p| hub.person.proves(transport, &self.nonce, &self.id, p)) {
                self.person.store(true, Ordering::SeqCst);
            }
        }
    }

    /// Hold `lease` until this connection closes; ended now if it already did.
    pub(super) fn hold_peer_lease(&self, hub: &Hub, lease: crate::hub::PeerLease) {
        let mut leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
        match leases.as_mut() {
            Some(held) => {
                // A renewal supersedes the earlier lease of its name, whose
                // end would be a no-op (another generation holds the name).
                held.retain(|old| old.name != lease.name);
                held.push(lease);
            }
            None => {
                drop(leases);
                hub.end_peer_lease(&lease);
            }
        }
    }

    /// The connection closed: every peer it leased stops.
    fn end_peer_leases(&self, hub: &Hub) {
        let held = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner()).take();
        for lease in held.unwrap_or_default() {
            hub.end_peer_lease(&lease);
        }
    }

    fn send(&self, msg: &Message) {
        let control = matches!(msg, Message::Response { .. });
        let masked = (!self.raw_text).then(|| peer_text::masked(msg)).flatten();
        let msg = masked.as_ref().unwrap_or(msg);
        // No message larger than one frame (`rpc::MAX_MESSAGE_BYTES`): a reply goes as its error,
        // a notification is left out and the client reads again from its last record.
        match msg.bounded_line() {
            Ok(line) => {
                enqueue_outbound(
                    &self.out,
                    line,
                    control,
                    &self.outbound_dropped,
                    &self.outbound_gap_pending,
                );
            }
            Err(bytes) => {
                tracing::warn!(conn = %self.id, method = ?msg.method(), bytes, "left out a notification too large to send");
                enqueue_outbound(
                    &self.out,
                    Message::notification(
                        "_acpmux/lagged",
                        json!({"dropped": 1, "reason": "message_too_large"}),
                    )
                    .to_line(),
                    false,
                    &self.outbound_dropped,
                    &self.outbound_gap_pending,
                );
            }
        }
    }
    fn sub_opts(&self, session_id: &str) -> Option<SubOpts> {
        self.subs.lock_or_recover().get(session_id).cloned()
    }
    pub(super) fn bind_mailbox_receipt(&self, receipt: SessionReceipt) {
        self.mailbox_bindings.lock_or_recover().insert(receipt.mux_session_id.clone(), receipt);
    }
    pub(super) fn mailbox_receipt(&self, session_id: &str) -> Option<SessionReceipt> {
        let key = session_id.strip_prefix("acp:").unwrap_or(session_id);
        self.mailbox_bindings
            .lock_or_recover()
            .values()
            .find(|receipt| key == receipt.mux_session_id || key == receipt.qualified_id())
            .cloned()
    }
    pub(super) fn unbind_mailbox_receipt(&self, session_id: &str) {
        self.mailbox_bindings.lock_or_recover().remove(session_id);
    }
    /// Subscribe with default options; keeps options already set.
    fn subscribe(&self, session_id: &str) -> bool {
        let mut subs = self.subs.lock_or_recover();
        if subs.contains_key(session_id) {
            return false;
        }
        subs.insert(session_id.to_owned(), SubOpts::default());
        true
    }
    /// Subscribe, replacing any options. True when the subscription is new.
    fn subscribe_with(&self, session_id: &str, opts: SubOpts) -> bool {
        self.subs.lock_or_recover().insert(session_id.to_owned(), opts).is_none()
    }
    fn label(&self) -> String {
        let n = self.name.lock_or_recover().clone();
        if n.is_empty() {
            self.id.clone()
        } else {
            format!("{n}#{}", self.id.get(..6).unwrap_or(self.id.as_str()))
        }
    }
}

/// Keep a small portion of the bounded queue available for replies and the
/// one gap marker that tells a reader to replay from its last cursor.
const OUTBOUND_CONTROL_RESERVE: usize = 2;

fn enqueue_outbound(
    out: &mpsc::Sender<String>,
    line: String,
    control: bool,
    dropped: &AtomicU64,
    gap_pending: &AtomicBool,
) {
    // Notifications are lossy by design when the reader is too slow, but the
    // final two permits are reserved for the response/control path and its
    // recovery marker.
    if !control && out.capacity() <= OUTBOUND_CONTROL_RESERVE {
        report_outbound_loss(out, dropped, gap_pending);
        return;
    }
    match out.try_send(line) {
        Ok(()) => {
            // Let a later queue-pressure episode produce a fresh marker once
            // the previous marker and backlog have drained.
            if gap_pending.load(Ordering::Acquire) && out.capacity() > OUTBOUND_CONTROL_RESERVE + 1
            {
                gap_pending.store(false, Ordering::Release);
            }
        }
        Err(mpsc::error::TrySendError::Full(_)) => report_outbound_loss(out, dropped, gap_pending),
        Err(mpsc::error::TrySendError::Closed(_)) => {}
    }
}

fn report_outbound_loss(out: &mpsc::Sender<String>, dropped: &AtomicU64, gap_pending: &AtomicBool) {
    let total = dropped.fetch_add(1, Ordering::Relaxed) + 1;
    if gap_pending.swap(true, Ordering::AcqRel) {
        return;
    }
    let marker = Message::notification(
        "_acpmux/lagged",
        json!({"dropped": total, "reason": "output_queue_full"}),
    )
    .to_line();
    if out.try_send(marker).is_err() {
        // No permit yet: keep the state retryable so the next dropped event
        // can publish the marker after the reader drains one frame.
        gap_pending.store(false, Ordering::Release);
    }
}

// ----------------------------------------------------------------- listen

pub async fn listen_unix(hub: Arc<Hub>, path: PathBuf) -> Result<()> {
    let listener = bind_unix(&path).await?;
    serve_unix(hub, listener).await
}

/// Bind the daemon socket (mode 0600), refusing to steal a live one.
#[cfg(unix)]
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

#[cfg(unix)]
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
            // Named by its audit token, read once here, never by pid.
            let peer = {
                use std::os::fd::AsRawFd;
                cmux_link::app_caller::peer_token(stream.as_raw_fd())
            };
            stream::serve_stream(hub, stream, peer).await;
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
/// `null`. An entry that does not parse is skipped with a warning. The Host
/// rule holds on every bind: a non-loopback `websocket.listen` also accepts
/// IP address literals, and the names clients use must be listed in
/// `websocket.allowed_hosts`.
pub fn listener_policy(
    address: std::net::SocketAddr,
    extra_origins: &[String],
    extra_hosts: &[String],
) -> ListenerPolicy {
    let mut policy =
        ListenerPolicy::for_bind_keeping_host_rule(address).with_origin(AGENT_PANE_ORIGIN);
    if !address.ip().is_loopback() && extra_hosts.is_empty() {
        tracing::warn!(
            "websocket.listen {address} is not loopback: clients may connect by IP address only; list host names in websocket.allowedHosts"
        );
    }
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
    serve_ws_with(hub, listener, token, WsAuth::default()).await
}

/// The proofs a WebSocket connection may present beyond the dashboard
/// token: this launch's LocalApp token (`local_app.rs`) and peer token
/// (`peer_auth.rs`). Without one, no connection gets that origin.
#[derive(Default, Clone)]
pub struct WsAuth {
    pub local_app: Option<Arc<local_app::LocalAppAuth>>,
    pub peer: Option<Arc<peer_auth::PeerAuth>>,
}

/// How long a connection may wait before its first frame decides whether it
/// is the local app (`local_app.rs`); after it, it is remote-origin.
const FIRST_FRAME: std::time::Duration = std::time::Duration::from_secs(10);

/// The largest WebSocket frame or message a connection reads. The app's agent pane sends a frame
/// of up to 32 MiB (`AcpmuxPaneMethods.maximumFrameBytes`); a prompt with a few screenshots is
/// past tungstenite's 16 MiB frame default, which ended the read with no log line and reset the
/// socket mid-send ("The agent connection was interrupted", 2026-10-20).
pub const WS_MAX_MESSAGE_BYTES: usize = 64 << 20;

/// The listener's and the peer client's WebSocket limits (`WS_MAX_MESSAGE_BYTES`).
pub fn ws_config() -> tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
    tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(WS_MAX_MESSAGE_BYTES))
        .max_frame_size(Some(WS_MAX_MESSAGE_BYTES))
}

/// `serve_ws` with this launch's LocalApp and peer tokens: a connection
/// that meets every LocalApp condition is served as `Origin::LocalApp`, one
/// that proves the peer token as `Origin::Peer`, any other as `Origin::Web`.
pub async fn serve_ws_with(
    hub: Arc<Hub>,
    listener: TcpListener,
    token: String,
    auth: WsAuth,
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
    // Each handshake checks the token current at that moment: a rotation
    // (`hub/web_token.rs`) applies from the next one on. The daemon set it
    // already; a caller that did not (tests) gets `token`.
    hub.web_token.set_if_unset(token);
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
        // Read and subscribed before the handshake, so a rotation during it
        // still closes a connection that presented the old token.
        let (token, rotated) = hub.web_token.watch();
        let policy = policy.clone();
        let local_app = auth.local_app.clone();
        let peer_auth = auth.peer.clone();
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
            let head_text = String::from_utf8_lossy(head.get(..n).unwrap_or(&head)).into_owned();
            if !head_text.to_ascii_lowercase().contains("upgrade: websocket") {
                serve_http(stream, &policy, &token, peer).await;
                return;
            }
            let expected = token.clone();
            // The upgrade request's Origin headers, for the LocalApp check.
            let seen_origins: Arc<StdMutex<Vec<String>>> = Arc::default();
            let record_origins = seen_origins.clone();
            // Its peer token headers, for the Peer check.
            let seen_peer: Arc<StdMutex<Vec<String>>> = Arc::default();
            let record_peer = seen_peer.clone();
            // A ticket or a paired machine's credential (`pairing.rs`).
            let admitted: Arc<StdMutex<pairing::Admitted>> = Arc::default();
            let (record_admitted, pairing_hub) = (admitted.clone(), hub.clone());
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
                    use tokio_tungstenite::tungstenite::http::{Response, StatusCode};
                    let mut response = Response::new(Some(refusal.reason().to_owned()));
                    *response.status_mut() =
                        StatusCode::from_u16(refusal.status()).unwrap_or(StatusCode::FORBIDDEN);
                    response
                };
                if let Err(refusal) = policy.check(&values("host"), &values("origin")) {
                    return Err(refuse(refusal));
                }
                *record_origins.lock().unwrap_or_else(|e| e.into_inner()) =
                    values("origin").into_iter().map(str::to_owned).collect();
                *record_peer.lock().unwrap_or_else(|e| e.into_inner()) =
                    values(peer_auth::HEADER).into_iter().map(str::to_owned).collect();
                let header = req
                    .headers()
                    .get("authorization")
                    .and_then(|v| v.to_str().ok())
                    .and_then(cmux_local_auth::bearer_token);
                let query = req.uri().query().and_then(cmux_local_auth::query_token);
                let tickets = values(crate::pairing::TICKET_HEADER);
                let proof = pairing::admit(&pairing_hub, peer, header.or(query), &tickets, &expected);
                *record_admitted.lock().unwrap_or_else(|e| e.into_inner()) = proof.map_err(refuse)?;
                Ok(resp)
            };
            let ws = match tokio_tungstenite::accept_hdr_async_with_config(
                stream,
                callback,
                Some(ws_config()),
            )
            .await
            {
                Ok(ws) => ws,
                Err(e) => {
                    tracing::warn!("ws handshake from {peer} rejected: {e}");
                    return;
                }
            };
            let admitted = std::mem::take(&mut *admitted.lock().unwrap_or_else(|e| e.into_inner()));
            let device = match admitted {
                pairing::Admitted::Ticket(secret) => {
                    return pairing::serve_redeem(hub, ws, secret).await;
                }
                pairing::Admitted::Device(device) => Some(device),
                pairing::Admitted::Dashboard => None,
            };
            let (mut sink, mut source) = ws.split();
            let (in_tx, in_rx) = mpsc::channel::<String>(256);
            let (out_tx, mut out_rx) = mpsc::channel::<String>(4096);
            // The handshake above checked the listener token: every
            // connection past it is authenticated (`conn_auth.rs`).
            let mut proof = ConnAuth::ListenerToken;
            // The first frame decides LocalApp; it reaches the protocol
            // handler without the token.
            let mut origin = Origin::Web;
            let mut first = None;
            let presented =
                std::mem::take(&mut *seen_peer.lock().unwrap_or_else(|e| e.into_inner()));
            if let Some(device) = &device {
                (origin, proof) = pairing::origin_of(device);
            } else if peer_auth.as_ref().is_some_and(|a| a.is_peer(peer, &presented)) {
                origin = Origin::Peer;
                proof = ConnAuth::PeerToken;
            } else if let Some(auth) = &local_app {
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
                    proof = ConnAuth::LocalApp;
                }
                first = frame.map(|f| local_app::strip_token(&f));
            }
            if let Some(first) = first
                && in_tx.send(first).await.is_err()
            {
                return;
            }
            let reader = tokio::spawn(async move {
                while let Some(frame) = source.next().await {
                    let frame = match frame {
                        Ok(frame) => frame,
                        // A read error ends the connection; say why, or the client sees only a reset.
                        Err(e) => {
                            tracing::warn!("closing a {origin:?} connection from {peer}: {e}");
                            break;
                        }
                    };
                    if let tokio_tungstenite::tungstenite::Message::Text(t) = frame
                        && in_tx.send(t.to_string()).await.is_err()
                    {
                        break;
                    }
                }
            });
            // Ends the writer when the server ends the connection itself:
            // other tasks may still hold a clone of `out_tx`.
            let (stop, mut stopped) = tokio::sync::oneshot::channel::<()>();
            tokio::spawn(async move {
                loop {
                    let line = tokio::select! {
                        line = out_rx.recv() => line,
                        _ = &mut stopped => None,
                    };
                    let Some(line) = line else { break };
                    let text = line.trim_end_matches('\n').to_owned();
                    if sink
                        .send(tokio_tungstenite::tungstenite::Message::Text(text.into()))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                // Say so with a Close frame.
                let _ = sink.close().await;
            });
            // A rotation ends a Web or Peer connection, which presented the
            // dashboard token; a revocation ends a paired machine's, which
            // presented its own. Ending its read half closes `in_rx`, so
            // `serve_connection_with` returns through its own cleanup
            // (detach counts, fan-out task) before the writer sends Close.
            // LocalApp also proved this launch's LocalApp token, so it stays.
            let _open = device.as_ref().map(|d| hub.pairing.opened(&d.id));
            let ends: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> =
                match &device {
                    Some(d) => Box::pin(hub.pairing.revoked(&d.id)),
                    None => Box::pin(rotated),
                };
            let watcher = matches!(origin, Origin::Web | Origin::Peer).then(|| {
                let read_half = reader.abort_handle();
                tokio::spawn(async move {
                    ends.await;
                    tracing::info!("closing a {origin:?} connection: its credential ended");
                    read_half.abort();
                })
            });
            serve_connection_authed(hub, in_rx, out_tx, origin, proof).await;
            if let Some(watcher) = watcher {
                watcher.abort();
            }
            let _ = stop.send(());
            // Its read half may wait on a silent client; the close is ours.
            reader.abort();
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
            head.extend_from_slice(chunk.get(..n).unwrap_or(&chunk));
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
    /// A peer acpmux daemon over the WebSocket listener, proven by this
    /// launch's peer token (`peer_auth.rs`). It has the Web's rights except
    /// the current-mode rule for prompts and permission answers.
    Peer,
}

impl Origin {
    /// Web or Peer: a connection held to the Web's rules.
    pub fn web_class(self) -> bool {
        matches!(self, Origin::Web | Origin::Peer)
    }
}

/// A connection from the local Unix socket.
pub async fn serve_connection(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
) {
    serve_connection_with(hub, inbound, out, Origin::Local).await
}

/// An in-process connection (tests, an embedding): the caller vouches for
/// the proof `origin` implies (`ConnAuth::proven_for`). A transport that
/// checks its own proof uses `serve_connection_authed`.
pub async fn serve_connection_with(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
) {
    serve_connection_authed(hub, inbound, out, origin, ConnAuth::proven_for(origin)).await
}

/// A connection with the proof its transport checked. `ConnAuth::None`
/// gets no sessions and no data: its first request is refused and the
/// connection ends (`conn_auth.rs`).
pub async fn serve_connection_authed(
    hub: Arc<Hub>,
    inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
    auth: ConnAuth,
) {
    serve_connection_from(hub, inbound, out, origin, auth, None).await
}

/// `serve_connection_authed` for a unix socket peer named by its audit token.
async fn serve_connection_from(
    hub: Arc<Hub>,
    mut inbound: mpsc::Receiver<String>,
    out: mpsc::Sender<String>,
    origin: Origin,
    auth: ConnAuth,
    peer: Option<cmux_link::app_caller::PeerToken>,
) {
    if !auth.authenticated() {
        refuse_unauthenticated(&mut inbound, &out, origin).await;
        return;
    }
    let raw_text = !peer_text::masks(origin);
    let conn = Arc::new(Conn {
        id: uuid::Uuid::now_v7().to_string(),
        origin,
        auth,
        raw_text,
        name: StdMutex::new(String::new()),
        out,
        outbound_dropped: AtomicU64::new(0),
        outbound_gap_pending: AtomicBool::new(false),
        subs: StdMutex::new(HashMap::new()),
        mailbox_bindings: StdMutex::new(HashMap::new()),
        watch_all: AtomicBool::new(false),
        watch_inventory: StdMutex::new(false),
        peer,
        requests: std::sync::atomic::AtomicU64::new(0),
        challenged: AtomicBool::new(false),
        nonce: crate::hub::person::new_nonce(),
        person: AtomicBool::new(false),
        holds_calls: std::sync::atomic::AtomicU32::new(0),
        caller: std::sync::OnceLock::new(),
        unproven_caller: std::sync::OnceLock::new(),
        peer_leases: StdMutex::new(Some(Vec::new())),
        ephemeral: StdMutex::new(Some(Vec::new())),
        media: crate::hub::media_handles::Handles::default(),
    });
    tracing::debug!(conn = %conn.id, "client connected");

    let fan = fanout::start(hub.clone(), conn.clone());

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
            Message::Request { id, method: m, mut params } => {
                // In order, before the request is spawned: a later request
                // on this connection sees the person decided.
                conn.bind_person(&hub, &m, &mut params);
                let hub = hub.clone();
                let conn = conn.clone();
                tokio::spawn(async move {
                    let result = chats::route(&hub, &conn, &m, params.unwrap_or(Value::Null)).await;
                    conn.send(&match result {
                        Ok(v) => Message::ok(id, v),
                        Err(e) => Message::err(id, e),
                    });
                });
            }
            // A read-only machine's notifications (a cancel) change nothing.
            Message::Notification { .. } if conn.auth == ConnAuth::ReadOnlyDevice => {}
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
    conn.media.close_all();
    view::release_all(&hub, &conn);
    // Leases first: ending one is cheap and synchronous, while the ephemeral
    // release awaits each session's kill. A leased peer must not keep
    // reconnecting to a forward port its bridge already closed, which another
    // process could bind (`hub/peer_lease.rs`).
    conn.end_peer_leases(&hub);
    ephemeral::release_all(&hub, &conn).await;
    tracing::debug!(conn = %conn.id, "client disconnected");
}

/// An unauthenticated connection: no hub subscription, no session, no
/// data. The first request gets the refusal, then the connection ends.
async fn refuse_unauthenticated(
    inbound: &mut mpsc::Receiver<String>,
    out: &mpsc::Sender<String>,
    origin: Origin,
) {
    tracing::warn!("refusing an unauthenticated {origin:?} connection");
    // Bounded: a client that never sends a request does not hold the task.
    let _ = tokio::time::timeout(FIRST_FRAME, async {
        while let Some(line) = inbound.recv().await {
            match Message::parse(&line) {
                Ok(Message::Request { id, .. }) => {
                    let _ = out.send(Message::err(id, conn_auth::refused()).to_line()).await;
                    return;
                }
                Ok(_) => continue,
                Err(_) if line.trim().is_empty() => continue,
                Err(_) => return,
            }
        }
    })
    .await;
}

/// Turn a hub record into client notifications for one connection.
fn deliver(hub: &Hub, conn: &Conn, ev: HubEvent) {
    if ev.record.kind == crate::hub::PEER_LAGGED {
        if conn.sub_opts(&ev.session_id).is_some() {
            conn.send(&Message::notification("_acpmux/lagged", ev.record.msg.clone()));
        }
        return;
    }
    chats::push_activity(hub, conn, &ev);
    processes::push_update(conn, &ev);
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
                params.set("sessionId", Value::String(ev.session_id.clone()));
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
        if rec.dir == "mux" && is_permission_ask(&rec.kind) {
            conn.send(&Message::notification(
                method::MUX_PERMISSION_PENDING,
                permission_pending(&ev.session_id, rec, "attach"),
            ));
        }
    }
    if watching {
        if let Some(remote) = &ev.remote {
            // A peer's prompt the person must answer, for a unix socket or app
            // watcher that did not attach the session (`hub/person.rs` (c)):
            // never relayed on to a Web client or another peer daemon.
            if rec.kind == crate::hub::PEER_PERMISSION_PENDING {
                if !attached && !conn.origin.web_class() {
                    conn.send(&Message::notification(
                        method::MUX_PERMISSION_PENDING,
                        peer_permission_pending(&ev.session_id, rec, &remote.peer),
                    ));
                }
                return;
            }
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
            // `replaced`: the same chat came back under this id (`Session::replaced`).
            let mut params = json!({"sessionId": ev.session_id, "session": {"sessionId": ev.session_id}, "kind": "purged", "recordKind": "purged", "seq": rec.seq});
            if rec.msg.get("replaced") == Some(&Value::Bool(true)) {
                params.set("replaced", Value::Bool(true));
            }
            conn.send(&Message::notification(method::MUX_SESSION_CHANGED, params));
            return;
        }
        // A deferred new chat has no attachment yet. Its command publication must still wake
        // the page's read of that chat's command list, including when skills arrive after creation.
        if rec.dir != "mux" && rec.kind != "available_commands_update" {
            return;
        }
        let Some(kind) = change_kind::session_change_kind(&rec.kind) else { return };
        if let Ok(s) = hub.resolve(&ev.session_id) {
            conn.send(&Message::notification(
                method::MUX_SESSION_CHANGED,
                json!({"sessionId": ev.session_id, "session": hub.session_summary(&s), "kind": kind, "recordKind": rec.kind, "seq": rec.seq}),
            ));
        }
        // A watcher that is not attached still learns a permission is waiting.
        if is_permission_ask(&rec.kind) && !attached {
            conn.send(&Message::notification(
                method::MUX_PERMISSION_PENDING,
                permission_pending(&ev.session_id, rec, "watch"),
            ));
        }
    }
}

fn str_param<'a>(params: &'a Value, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str)
}

pub(crate) fn session_key(params: &Value) -> Result<&str, RpcError> {
    str_param(params, "sessionId")
        .or_else(|| str_param(params, "session"))
        .or_else(|| str_param(params, "name"))
        .ok_or_else(|| RpcError::invalid_params("sessionId or session is required"))
}

fn mux_meta(params: &Value) -> Option<&Value> {
    params.get("_meta").and_then(|m| m.get("acpmux"))
}

mod agent_messages;
mod app_reply;
mod clock_text;
pub(crate) use clock_text::iso;
mod change_kind;
mod chats;
pub mod conn_auth;
mod ephemeral;
mod fanout;
mod forum;
pub use conn_auth::ConnAuth;
mod fork_through;
mod harness_admin;
mod harness_enable;
mod inventory_watch;
pub mod local_app;
mod models_fanout;
mod new_worktree;
pub(crate) mod outbox;
mod pairing;
pub mod peer_auth;
mod peer_forward;
pub mod peer_text;
mod pending;
mod processes;
mod worktrees;
use crate::hub::is_permission_ask;
pub use pending::{event_value, into_event_value};
use pending::{peer_permission_pending, permission_pending};
mod redact;
pub(crate) mod remote_guard;
mod requests;
mod routes;
mod secrets;
mod stream;
mod subsessions;
pub(crate) mod trust_gate;
mod view;
mod wait;
#[cfg(windows)]
mod windows_socket;
use requests::handle_notification;

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

#[cfg(test)]
mod outbound_queue_tests {
    use super::{Message, enqueue_outbound};
    use serde_json::json;
    use std::sync::atomic::{AtomicBool, AtomicU64};
    use tokio::sync::mpsc;

    #[tokio::test]
    async fn a_slow_reader_gets_a_gap_signal_without_losing_a_response() {
        let (out, mut queued) = mpsc::channel(3);
        out.try_send("queued-before-reader-catches-up\n".to_owned()).unwrap();
        let dropped = AtomicU64::new(0);
        let gap_pending = AtomicBool::new(false);

        enqueue_outbound(
            &out,
            Message::notification("session/update", json!({"kind": "progress"})).to_line(),
            false,
            &dropped,
            &gap_pending,
        );
        enqueue_outbound(
            &out,
            Message::ok(json!(7), json!({"status": "complete"})).to_line(),
            true,
            &dropped,
            &gap_pending,
        );

        assert_eq!(queued.recv().await.as_deref(), Some("queued-before-reader-catches-up\n"));
        let gap = Message::parse(&queued.recv().await.unwrap()).unwrap();
        let Message::Notification { method, params } = gap else { panic!("{gap:?}") };
        assert_eq!(method, "_acpmux/lagged");
        let params = params.unwrap();
        assert_eq!(params["reason"], "output_queue_full");
        assert_eq!(params["dropped"], 1);
        let response = Message::parse(&queued.recv().await.unwrap()).unwrap();
        assert!(matches!(response, Message::Response { id, .. } if id == json!(7)));
    }
}
