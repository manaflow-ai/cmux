//! The opt-in daemon WebSocket listener (`--ws`): one JSON message per text
//! frame, the localhost listener rule at the handshake
//! (plans/cmux-next/identity.md section 4), then token or pairing auth.

use crate::panic_free::RecoverPoison;
use crate::supervised::{self, Fatal, ShutdownBehavior};
use cmux_threads::checked::sync as waits;
use std::net::{SocketAddr, TcpListener};

use tungstenite::protocol::CloseFrame;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::{Message, WebSocket, accept_hdr_with_config};

use super::attachment_http;
use super::connection_scheduler::connection_qos::ReaderClass;
use super::connection_scheduler::{REQUEST_THREAD_QOS, spawn_request_thread};
use super::listen;
use super::page_files;
use super::*;
use crate::diagnostics::{IpcTransport, JsonParseScope};
use crate::net_keepalive::{WebSocketKeepalive, enable_tcp_keepalive};
use crate::pairing::CredentialMatch;

/// A running opt-in WebSocket listener. Dropping it stops accepts and closes clients.
pub struct WebSocketServer {
    local_addr: SocketAddr,
    shutdown: Arc<AtomicBool>,
    connections: Arc<Mutex<HashMap<u64, TcpStream>>>,
    thread: Option<supervised::SupervisedThread<()>>,
}

impl WebSocketServer {
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }
}

impl Drop for WebSocketServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        for stream in self.connections.lock().recover_poison().values() {
            let _ = stream.shutdown(Shutdown::Both);
        }
        if let Ok(stream) = TcpStream::connect(self.local_addr) {
            let _ = stream.set_nodelay(true);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Bind an opt-in WebSocket listener using one JSON message per text frame.
/// Browser pages may connect only from the listener's own origin.
pub fn serve_websocket(
    mux: Arc<Mux>,
    addr: SocketAddr,
    token: Option<String>,
    allow_insecure_bind: bool,
) -> anyhow::Result<WebSocketServer> {
    serve_websocket_with_access(mux, addr, token, allow_insecure_bind, &WebSocketAccess::default())
}

/// Extra browser origins and `Host` names a WebSocket listener accepts
/// (`--ws-allow-origin`, `--ws-allow-host`), for example a web frontend dev
/// server or a `tailscale serve` name. `Origin: null` is never accepted.
pub use cmux_local_auth::parse_origin as parse_websocket_origin;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WebSocketAccess {
    pub origins: Vec<String>,
    pub hosts: Vec<String>,
}

/// [`serve_websocket`] with extra allowed origins and hosts. Every
/// handshake passes the localhost listener rule (plans/cmux-next/identity.md
/// section 4) before the first protocol frame.
pub fn serve_websocket_with_access(
    mux: Arc<Mux>,
    addr: SocketAddr,
    token: Option<String>,
    allow_insecure_bind: bool,
    access: &WebSocketAccess,
) -> anyhow::Result<WebSocketServer> {
    serve_websocket_with_pages(mux, addr, token, allow_insecure_bind, access, None)
}

/// [`serve_websocket_with_access`] that also answers plain `GET /pages/...`
/// requests with files of the page bundle directory `pages`
/// (spec/transports.md "App listener and page files"; [`super::page_bundle_dir`]).
pub fn serve_websocket_with_pages(
    mux: Arc<Mux>,
    addr: SocketAddr,
    token: Option<String>,
    allow_insecure_bind: bool,
    access: &WebSocketAccess,
    pages: Option<PathBuf>,
) -> anyhow::Result<WebSocketServer> {
    serve_websocket_with_keepalive(
        mux,
        addr,
        token,
        allow_insecure_bind,
        access,
        pages,
        WebSocketKeepalive::default(),
    )
}

/// [`serve_websocket_with_pages`] with a chosen dead-peer policy. Every
/// production listener uses [`WebSocketKeepalive::default`]; tests pass
/// short intervals to observe pings and dead-peer closes.
#[doc(hidden)]
pub fn serve_websocket_with_keepalive(
    mux: Arc<Mux>,
    addr: SocketAddr,
    token: Option<String>,
    allow_insecure_bind: bool,
    access: &WebSocketAccess,
    pages: Option<PathBuf>,
    keepalive: WebSocketKeepalive,
) -> anyhow::Result<WebSocketServer> {
    // WebSocket has no TLS here. Remote deployments must explicitly opt in and
    // should put cmux-tui behind a TLS-terminating reverse proxy.
    if !addr.ip().is_loopback() && !allow_insecure_bind {
        anyhow::bail!("refusing non-loopback WebSocket bind {addr} without --ws-insecure-bind");
    }
    let token = token.filter(|value| !value.trim().is_empty());
    if let Some(token_value) = token.as_ref() {
        let auth_message_bytes =
            serde_json::to_vec(&json!({"auth": {"token": token_value}}))?.len();
        if auth_message_bytes > WEBSOCKET_AUTH_MAX_BYTES {
            anyhow::bail!(
                "WebSocket token produces a {auth_message_bytes}-byte auth message; maximum is {WEBSOCKET_AUTH_MAX_BYTES} bytes"
            );
        }
    }
    let listener = TcpListener::bind(addr)?;
    let local_addr = listener.local_addr()?;
    let policy = websocket_listener_policy(local_addr, access);
    let rules = Arc::new(ListenerRules { policy, pages, keepalive });
    let shutdown = Arc::new(AtomicBool::new(false));
    let connections = Arc::new(Mutex::new(HashMap::new()));
    let next_connection = Arc::new(AtomicU64::new(1));
    let active_connections = mux.connection_stats().clone();
    let thread_shutdown = shutdown.clone();
    let thread_connections = connections.clone();
    let render_service = Arc::new(RenderService::new());
    let thread = supervised::spawn_at(
        "mux-ws-server",
        listen::ACCEPT_THREAD_QOS,
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            let mut backoff = crate::backoff::Backoff::new(ACCEPT_RETRY_INITIAL, ACCEPT_RETRY_MAX);
            while !thread_shutdown.load(Ordering::Acquire) {
                let (stream, peer) = match listener.accept() {
                    Ok(connection) => {
                        backoff.reset();
                        connection
                    }
                    Err(error) => {
                        if thread_shutdown.load(Ordering::Acquire) {
                            break;
                        }
                        // Accept errors can persist (for example, after resource exhaustion).
                        if crate::backoff::accept_error_needs_backoff(&error) {
                            backoff.sleep();
                        }
                        continue;
                    }
                };
                if stream.set_nodelay(true).is_err() {
                    continue;
                }
                enable_tcp_keepalive(&stream);
                if thread_shutdown.load(Ordering::Acquire) {
                    break;
                }
                let Some(permit) = claim_connection(&active_connections) else { continue };
                let id = next_connection.fetch_add(1, Ordering::Relaxed);
                if let Ok(tracked) = stream.try_clone() {
                    thread_connections.lock().recover_poison().insert(id, tracked);
                }
                let mux = mux.clone();
                let token = token.clone();
                let rules = rules.clone();
                let render_service = render_service.clone();
                let connections = thread_connections.clone();
                let cleanup_connections = thread_connections.clone();
                // It reads frames and runs their requests itself: a request thread.
                if spawn_request_thread("mux-ws-conn", move || {
                    handle_websocket_connection_with_permit(
                        mux,
                        stream,
                        peer,
                        token.as_deref(),
                        &rules,
                        render_service,
                        Some(permit),
                    );
                    connections.lock().recover_poison().remove(&id);
                })
                .is_err()
                {
                    cleanup_connections.lock().recover_poison().remove(&id);
                }
            }
        },
    )?;
    Ok(WebSocketServer { local_addr, shutdown, connections, thread: Some(thread) })
}

#[cfg(test)]
pub(super) fn handle_websocket_connection(
    mux: Arc<Mux>,
    stream: TcpStream,
    peer: SocketAddr,
    token: Option<&str>,
    render_service: Arc<RenderService>,
) {
    let rules = ListenerRules {
        policy: cmux_local_auth::ListenerPolicy::loopback(0),
        pages: None,
        keepalive: WebSocketKeepalive::default(),
    };
    handle_websocket_connection_with_permit(mux, stream, peer, token, &rules, render_service, None);
}

/// What a listener checks and serves besides the protocol: the Host/Origin
/// rule, the page bundle directory (none: every page request is a 404) and
/// when an idle connection is pinged and closed.
struct ListenerRules {
    policy: cmux_local_auth::ListenerPolicy,
    pages: Option<PathBuf>,
    keepalive: WebSocketKeepalive,
}

/// The Origin and Host rule of a daemon WebSocket listener bound on `local`.
/// The Host rule holds on every bind: `--ws-insecure-bind` widens the
/// address, never the accepted names (names come from `--ws-allow-host`).
fn websocket_listener_policy(
    local: SocketAddr,
    access: &WebSocketAccess,
) -> cmux_local_auth::ListenerPolicy {
    let policy = cmux_local_auth::ListenerPolicy::for_bind_keeping_host_rule(local);
    let policy = access.hosts.iter().fold(policy, |policy, host| policy.with_host(host));
    access.origins.iter().fold(policy, |policy, origin| policy.with_origin(origin))
}

/// Refuse a handshake whose `Host` or `Origin` breaks the listener rule,
/// before any protocol frame. Tokens and pairing are checked after it.
fn check_websocket_handshake(
    policy: &cmux_local_auth::ListenerPolicy,
    request: &tungstenite::handshake::server::Request,
) -> Result<(), cmux_local_auth::Refusal> {
    let values = |name: &str| {
        request
            .headers()
            .get_all(name)
            .iter()
            .map(|value| value.to_str().unwrap_or("\u{0}"))
            .collect::<Vec<_>>()
    };
    policy.check(&values("host"), &values("origin"))
}

/// The page id of an accepted handshake's Origin, when it is one Origin
/// that names a cmux page.
fn handshake_page(request: &tungstenite::handshake::server::Request) -> Option<String> {
    let mut origins = request.headers().get_all("origin").iter();
    let origin = origins.next()?.to_str().ok()?;
    if origins.next().is_some() {
        return None;
    }
    crate::request_origin::page_router_table::page_from_origin(origin)
}

// The handshake callback's error type is tungstenite's HTTP response.
#[allow(clippy::result_large_err)]
fn handle_websocket_connection_with_permit(
    mux: Arc<Mux>,
    stream: TcpStream,
    peer: SocketAddr,
    token: Option<&str>,
    rules: &ListenerRules,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
) {
    let mut stream = stream;
    if stream.set_read_timeout(Some(WEBSOCKET_HANDSHAKE_TIMEOUT)).is_err()
        || stream.set_write_timeout(Some(WEBSOCKET_HANDSHAKE_TIMEOUT)).is_err()
    {
        return;
    }
    // The request head decides: a WebSocket handshake (replayed to the
    // handshake below) or a page file request (answered and closed).
    let Some((head_bytes, head)) = page_files::read_request_head(&mut stream) else { return };
    if !head.is_websocket_upgrade() {
        // Download links (`ws-attachments-v1`), else page files.
        if head.target.starts_with(attachment_http::PREFIX) {
            attachment_http::serve(stream, &head, &rules.policy, &mux);
        } else {
            page_files::serve(stream, &head, &rules.policy, rules.pages.as_deref());
        }
        return;
    }
    let stream = SynchronizedTcpStream::with_replay(stream, head_bytes);
    let auth_config = WebSocketConfig::default()
        .read_buffer_size(4 * 1024)
        .write_buffer_size(4 * 1024)
        .max_write_buffer_size(WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES)
        .max_message_size(Some(WEBSOCKET_AUTH_MAX_BYTES))
        .max_frame_size(Some(WEBSOCKET_AUTH_MAX_BYTES));
    // The page a host's page Origin names (`cmux-page://cmux.<page>`,
    // page-router-v1): the web view sets it, page script cannot.
    let page = std::cell::Cell::new(None::<String>);
    let callback = |request: &tungstenite::handshake::server::Request,
                    response: tungstenite::handshake::server::Response| {
        match check_websocket_handshake(&rules.policy, request) {
            Ok(()) => {
                page.set(handshake_page(request));
                Ok(response)
            }
            Err(refusal) => {
                let mut denied = tungstenite::handshake::server::ErrorResponse::new(Some(
                    refusal.reason().to_owned(),
                ));
                *denied.status_mut() = tungstenite::http::StatusCode::FORBIDDEN;
                Err(denied)
            }
        }
    };
    let Ok(mut websocket) = accept_hdr_with_config(stream, callback, Some(auth_config)) else {
        return;
    };

    let handshake_page = page.take();
    let Some(admission) =
        authenticate_websocket(&mux, &mut websocket, peer, token, handshake_page.as_deref())
    else {
        let frame = CloseFrame { code: CloseCode::Policy, reason: "authentication failed".into() };
        let _ = websocket.close(Some(frame));
        let _ = websocket.flush();
        return;
    };
    websocket.set_config(|config| {
        config.max_message_size = Some(WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES);
        config.max_frame_size = Some(WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES);
    });
    // The read timeout is the ping clock: a read that sees nothing for one
    // interval returns, and the loop below pings or gives up.
    let keepalive = rules.keepalive;
    if websocket.get_mut().set_read_timeout(Some(keepalive.ping_interval)).is_err() {
        return;
    }
    let _ = websocket.get_mut().set_write_timeout(Some(STREAM_WRITE_TIMEOUT));
    let Ok(writer_stream) = websocket.get_ref().try_clone() else { return };
    // Shares the write lock with the writer thread and tungstenite's Pong
    // replies, so a Ping is never written inside another frame.
    let Ok(mut ping_stream) = websocket.get_ref().try_clone() else { return };
    let Ok(writer_shutdown) = writer_stream.try_clone_raw() else { return };
    let Ok(control) = writer_stream.try_clone_raw() else { return };
    let _ = writer_stream.set_write_timeout(Some(STREAM_WRITE_TIMEOUT));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new_with_render_service(
        QueuedSink { outbound: outbound.clone(), control: Some(SinkControl::WebSocket(control)) },
        render_service,
    );
    let writer_outbound = outbound;
    let writer_close = writer.clone();
    let writer_ipc = mux.ipc_stats().clone();
    // The writer holds the connection's slot until its close frame is out,
    // so the reader never joins it (a wait for another thread, which the
    // reader, a request thread that disallows blocking, may not make).
    let writer_permit = connection_permit.clone();
    let Ok(writer_thread) = supervised::spawn_at(
        "mux-ws-out",
        REQUEST_THREAD_QOS,
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            let _permit = writer_permit;
            let mut writer_stream = writer_stream;
            // mq14-allow: the writer's idle wait for its own queue (BoundedOutbound::recv).
            while let Some(item) = writer_outbound.recv() {
                let result = match item {
                    OutboundItem::Text(text) => {
                        writer_ipc.line_sent(text.len());
                        writer_stream.write_websocket_text(&text, &writer_ipc)
                    }
                    // The WebSocket sink refuses frames before they queue.
                    OutboundItem::Frame(..) | OutboundItem::Chunk { .. } => {
                        Err(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "a frame reached a WebSocket",
                        ))
                    }
                    OutboundItem::Flush(flushed) => writer_stream.flush().map(|()| {
                        let _ = flushed.send(());
                    }),
                };
                if result.is_err() {
                    writer_outbound.close();
                    break;
                }
            }
            writer_close.close();
            let _ = writer_stream.write_websocket_close();
            let _ = writer_shutdown.shutdown(Shutdown::Both);
        },
    ) else {
        writer.close();
        return;
    };
    let client = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
    // The connection's stream 0, open until the connection ends
    // (`server-stats` `ipc`).
    let ipc = mux.ipc_stats().clone();
    let _stream = ipc.stream_opened();
    if admission == CredentialMatch::Person {
        mux.control_clients.mark_person(client);
    }
    let mut hello = client_hello::HelloGate::new(ClientTransport::WebSocket);
    // A page-bound credential admits its page only: the page's raw commands and its
    // `cmux.protocol/2` allow list, nothing else (page-credential-scoped-v1). It matched only
    // because the handshake named that page.
    match handshake_page {
        Some(page) if admission == CredentialMatch::Page => {
            hello.scope_to_page(&page);
            origin_gate::set_scoped_page(&mux, client, page);
        }
        Some(page) => origin_gate::set_page(&mux, client, page),
        // A page-bound credential matched only a handshake that named its page.
        None => {}
    }
    let class = mux.control_clients.connection_class(client);
    let mut reader_class = ReaderClass::new(class.clone(), mux.request_qos());
    let surface_scheduler = Arc::new(
        ConnectionSurfaceScheduler::new_inner(
            mux.surface_operation_admission.clone(),
            connection_permit.clone(),
        )
        .classed(class),
    );

    // Any inbound byte, including part of a frame or a Pong, is liveness.
    let mut idle_since = Instant::now();
    let mut bytes_seen = websocket.get_ref().bytes_read();
    loop {
        if !writer.is_open() {
            break;
        }

        let incoming = websocket.read();
        let bytes_read = websocket.get_ref().bytes_read();
        if bytes_read != bytes_seen {
            bytes_seen = bytes_read;
            idle_since = Instant::now();
        }
        match incoming {
            Ok(Message::Text(text)) => {
                // The frame's arrival, for its request span (server/request_spans.rs).
                let arrived = Instant::now();
                ipc.line_received(text.len());
                let mut text = text.to_string();
                // One request of `server-stats` `ipc`, as a line is.
                let parses = JsonParseScope::enter(&ipc, IpcTransport::Lines);
                let keep_open =
                    match hello.observe(&mux, client, &text, client_hello::Peer::unknown) {
                        Some(reply) => writer.send_control(&reply).is_ok(),
                        None => {
                            reader_class.before_line(&mux, client, hello.is_closed());
                            handle_connection_frame_at(
                                &mux,
                                client,
                                ClientTransport::WebSocket,
                                &text,
                                &writer,
                                &surface_scheduler,
                                arrived,
                            )
                        }
                    };
                drop(parses);
                zeroize_string(&mut text);
                if !keep_open {
                    break;
                }
                // Time spent handling the frame (a handler can wait on a
                // slow client's queue) is not inbound silence.
                idle_since = Instant::now();
            }
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
                let _ = websocket.flush();
            }
            Ok(Message::Close(_)) => break,
            // The protocol is JSON text: a binary message is malformed.
            Ok(Message::Binary(_)) => {
                ipc.bad_message();
                break;
            }
            Ok(_) => break,
            // A full ping interval of inbound silence (the read timeout:
            // WouldBlock on Unix, TimedOut on Windows). Tungstenite keeps a
            // partly read frame buffered across it.
            Err(tungstenite::Error::Io(error))
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                if idle_since.elapsed() >= keepalive.dead_peer_timeout {
                    break;
                }
                if ping_stream.write_websocket_ping().is_err() {
                    break;
                }
            }
            Err(error) => {
                if is_malformed_websocket_message(&error) {
                    ipc.bad_message();
                }
                break;
            }
        }
    }
    let _ = surface_scheduler.close_and_wait(CONNECTION_SURFACE_SHUTDOWN_TIMEOUT);
    disconnect_client(&mux, client, false);
    // The disconnect closed the writer's queue: the writer writes what is
    // left, then the close frame, and shuts the socket down. The reader
    // writes no close of its own, which could pass the writer's last items.
    drop(writer_thread);
    drop(websocket);
    drop(connection_permit);
}

/// Whether a read error means the peer sent a malformed message (oversize,
/// not UTF-8, against the protocol), not that the connection went away.
fn is_malformed_websocket_message(error: &tungstenite::Error) -> bool {
    use tungstenite::error::ProtocolError;
    match error {
        tungstenite::Error::Capacity(_)
        | tungstenite::Error::Utf8(_)
        | tungstenite::Error::AttackAttempt => true,
        tungstenite::Error::Protocol(protocol) => {
            !matches!(protocol, ProtocolError::ResetWithoutClosingHandshake)
        }
        _ => false,
    }
}

/// What admitted the connection, once authenticated: `Person` for a
/// pairing-store credential (a human-approved pairing, or the verified app's
/// `page-credential`); `None` (the match kind, not a refusal) for the static
/// or file token (any same-user process can read the file, so it never
/// carries the person's Cloud lease); `Page` for a page-bound credential
/// (`page-credential {page}`), which admits only a handshake whose Origin
/// names its page (`handshake_page`) and only that page's commands.
fn authenticate_websocket(
    mux: &Arc<Mux>,
    websocket: &mut WebSocket<SynchronizedTcpStream>,
    peer: SocketAddr,
    configured_token: Option<&str>,
    handshake_page: Option<&str>,
) -> Option<CredentialMatch> {
    let Ok(Message::Text(text)) = websocket.read() else { return None };
    let mut text = text.to_string();
    if let Some(mut provided) = auth_token(&text) {
        let matched = mux.authenticate_page_handshake(&provided, handshake_page);
        let authenticated = matched != CredentialMatch::None
            || configured_token
                .is_some_and(|expected| constant_time_eq(provided.as_bytes(), expected.as_bytes()));
        zeroize_string(&mut provided);
        zeroize_string(&mut text);
        return authenticated.then_some(matched);
    }
    if !pairing_request(&text) {
        zeroize_string(&mut text);
        return None;
    }
    zeroize_string(&mut text);

    let (challenge, decision) = match mux.begin_pairing(peer.ip()) {
        Ok(pairing) => pairing,
        Err(error) => {
            let _ = websocket.send(Message::Text(
                json!({"pairing_error": {"code": error.code(), "message": error.to_string()}})
                    .to_string()
                    .into(),
            ));
            return None;
        }
    };
    if websocket
        .send(Message::Text(
            json!({"pairing": {
                "id": challenge.id,
                "code": challenge.code,
                "peer": challenge.peer,
                "expires_in": challenge.expires_in,
            }})
            .to_string()
            .into(),
        ))
        .is_err()
    {
        mux.cancel_pairing(challenge.id);
        return None;
    }

    match waits::recv_timeout(&decision, Duration::from_secs(challenge.expires_in)) {
        Ok(PairingDecision::Approved { credential }) => websocket
            .send(Message::Text(json!({"paired": {"credential": credential}}).to_string().into()))
            .is_ok()
            .then_some(CredentialMatch::Person),
        Ok(PairingDecision::Denied) | Err(_) => {
            mux.cancel_pairing(challenge.id);
            None
        }
    }
}
