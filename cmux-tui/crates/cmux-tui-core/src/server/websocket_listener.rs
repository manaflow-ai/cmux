//! The opt-in daemon WebSocket listener (`--ws`): one JSON message per text
//! frame, the localhost listener rule at the handshake
//! (plans/cmux-next/identity.md section 4), then token or pairing auth.

use std::net::{SocketAddr, TcpListener};

use tungstenite::protocol::CloseFrame;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::{Message, WebSocket, accept_hdr_with_config};

use super::*;

/// A running opt-in WebSocket listener. Dropping it stops accepts and closes clients.
pub struct WebSocketServer {
    local_addr: SocketAddr,
    shutdown: Arc<AtomicBool>,
    connections: Arc<Mutex<HashMap<u64, TcpStream>>>,
    thread: Option<JoinHandle<()>>,
}

impl WebSocketServer {
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }
}

impl Drop for WebSocketServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        for stream in self.connections.lock().unwrap().values() {
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
    let policy = Arc::new(websocket_listener_policy(local_addr, access));
    let shutdown = Arc::new(AtomicBool::new(false));
    let connections = Arc::new(Mutex::new(HashMap::new()));
    let next_connection = Arc::new(AtomicU64::new(1));
    let active_connections = mux.connection_stats().clone();
    let thread_shutdown = shutdown.clone();
    let thread_connections = connections.clone();
    let render_service = Arc::new(RenderService::new());
    let thread = std::thread::Builder::new().name("mux-ws-server".into()).spawn(move || {
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
            if thread_shutdown.load(Ordering::Acquire) {
                break;
            }
            let Some(permit) = claim_connection(&active_connections) else { continue };
            let id = next_connection.fetch_add(1, Ordering::Relaxed);
            if let Ok(tracked) = stream.try_clone() {
                thread_connections.lock().unwrap().insert(id, tracked);
            }
            let mux = mux.clone();
            let token = token.clone();
            let policy = policy.clone();
            let render_service = render_service.clone();
            let connections = thread_connections.clone();
            let cleanup_connections = thread_connections.clone();
            if std::thread::Builder::new()
                .name("mux-ws-conn".into())
                .spawn(move || {
                    handle_websocket_connection_with_permit(
                        mux,
                        stream,
                        peer,
                        token.as_deref(),
                        &policy,
                        render_service,
                        Some(permit),
                    );
                    connections.lock().unwrap().remove(&id);
                })
                .is_err()
            {
                cleanup_connections.lock().unwrap().remove(&id);
            }
        }
    })?;
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
    let policy = cmux_local_auth::ListenerPolicy::loopback(0);
    handle_websocket_connection_with_permit(
        mux,
        stream,
        peer,
        token,
        &policy,
        render_service,
        None,
    );
}

/// The Origin and Host rule of a daemon WebSocket listener bound on `local`.
fn websocket_listener_policy(
    local: SocketAddr,
    access: &WebSocketAccess,
) -> cmux_local_auth::ListenerPolicy {
    let policy = cmux_local_auth::ListenerPolicy::for_bind(local);
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

// The handshake callback's error type is tungstenite's HTTP response.
#[allow(clippy::result_large_err)]
fn handle_websocket_connection_with_permit(
    mux: Arc<Mux>,
    stream: TcpStream,
    peer: SocketAddr,
    token: Option<&str>,
    policy: &cmux_local_auth::ListenerPolicy,
    render_service: Arc<RenderService>,
    connection_permit: Option<ConnectionPermit>,
) {
    let stream = SynchronizedTcpStream::new(stream);
    if stream.set_read_timeout(Some(WEBSOCKET_HANDSHAKE_TIMEOUT)).is_err()
        || stream.set_write_timeout(Some(WEBSOCKET_HANDSHAKE_TIMEOUT)).is_err()
    {
        return;
    }
    let auth_config = WebSocketConfig::default()
        .read_buffer_size(4 * 1024)
        .write_buffer_size(4 * 1024)
        .max_write_buffer_size(WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES)
        .max_message_size(Some(WEBSOCKET_AUTH_MAX_BYTES))
        .max_frame_size(Some(WEBSOCKET_AUTH_MAX_BYTES));
    let callback = |request: &tungstenite::handshake::server::Request,
                    response: tungstenite::handshake::server::Response| {
        match check_websocket_handshake(policy, request) {
            Ok(()) => Ok(response),
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

    if !authenticate_websocket(&mux, &mut websocket, peer, token) {
        let frame = CloseFrame { code: CloseCode::Policy, reason: "authentication failed".into() };
        let _ = websocket.close(Some(frame));
        let _ = websocket.flush();
        return;
    }
    websocket.set_config(|config| {
        config.max_message_size = Some(WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES);
        config.max_frame_size = Some(WEBSOCKET_INBOUND_MESSAGE_MAX_BYTES);
    });
    let _ = websocket.get_mut().set_read_timeout(None);
    let _ = websocket.get_mut().set_write_timeout(Some(STREAM_WRITE_TIMEOUT));
    let Ok(writer_stream) = websocket.get_ref().try_clone() else { return };
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
    let Ok(writer_thread) =
        std::thread::Builder::new().name("mux-ws-out".into()).spawn(move || {
            let mut writer_stream = writer_stream;
            while let Some(item) = writer_outbound.recv() {
                let result = match item {
                    OutboundItem::Text(text) => writer_stream.write_websocket_text(&text),
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
        })
    else {
        writer.close();
        return;
    };
    let client = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
    let surface_scheduler = Arc::new(ConnectionSurfaceScheduler::new_inner(
        mux.surface_operation_admission.clone(),
        connection_permit.clone(),
    ));

    loop {
        if !writer.is_open() {
            break;
        }

        let incoming = websocket.read();
        match incoming {
            Ok(Message::Text(text)) => {
                let mut text = text.to_string();
                let keep_open =
                    handle_connection_frame(
                        &mux,
                        client,
                        ClientTransport::WebSocket,
                        &text,
                        &writer,
                        &surface_scheduler,
                    );
                zeroize_string(&mut text);
                if !keep_open {
                    break;
                }
            }
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {
                let _ = websocket.flush();
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => break,
            Err(_) => break,
        }
    }
    let _ = surface_scheduler.close_and_wait(CONNECTION_SURFACE_SHUTDOWN_TIMEOUT);
    disconnect_client(&mux, client, false);
    let _ = writer_thread.join();
    let _ = websocket.close(None);
    drop(connection_permit);
}

fn authenticate_websocket(
    mux: &Arc<Mux>,
    websocket: &mut WebSocket<SynchronizedTcpStream>,
    peer: SocketAddr,
    configured_token: Option<&str>,
) -> bool {
    let Ok(Message::Text(text)) = websocket.read() else { return false };
    let mut text = text.to_string();
    if let Some(mut provided) = auth_token(&text) {
        let authenticated = configured_token
            .is_some_and(|expected| constant_time_eq(provided.as_bytes(), expected.as_bytes()))
            || mux.authenticate_pairing_credential(&provided);
        zeroize_string(&mut provided);
        zeroize_string(&mut text);
        return authenticated;
    }
    if !pairing_request(&text) {
        zeroize_string(&mut text);
        return false;
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
            return false;
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
        return false;
    }

    match decision.recv_timeout(Duration::from_secs(challenge.expires_in)) {
        Ok(PairingDecision::Approved { credential }) => websocket
            .send(Message::Text(json!({"paired": {"credential": credential}}).to_string().into()))
            .is_ok(),
        Ok(PairingDecision::Denied) | Err(_) => {
            mux.cancel_pairing(challenge.id);
            false
        }
    }
}
