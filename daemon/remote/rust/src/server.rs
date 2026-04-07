use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use serde_json::{Value, json};
use sha1::{Digest, Sha1};

use crate::auth::{TicketClaims, has_session_capability, verify_ticket};
use crate::pane::{EventCallback, PaneHandle, PaneRuntimeEvent};
use crate::proxy::{ProxyError, ProxyManager};
use crate::rpc::{
    FrameRead, Request, Response, error as rpc_error, ok as rpc_ok, read_frame, write_response,
};
use crate::session::{PaneSlot, Session, SessionError, SessionListEntry, SessionSnapshot, Window};

#[derive(Default)]
pub struct UnixServeConfig {
    pub socket_path: String,
    pub ws_port: Option<u16>,
    pub ws_secret: Option<String>,
}

#[derive(Default)]
pub struct TlsServeConfig {
    pub listen_addr: String,
    pub server_id: String,
    pub ticket_secret: String,
    pub cert_file: String,
    pub key_file: String,
}

#[derive(Clone)]
pub struct Daemon {
    inner: Arc<DaemonInner>,
}

struct DaemonInner {
    version: String,
    state: Mutex<CoreState>,
    state_cv: Condvar,
    proxies: ProxyManager,
}

struct CoreState {
    next_session_id: u64,
    next_attachment_id: u64,
    next_window_id: u64,
    next_pane_id: u64,
    next_event_id: u64,
    sessions: BTreeMap<String, Arc<Session>>,
    buffers: BTreeMap<String, String>,
    pane_pipes: BTreeMap<String, Arc<Mutex<std::process::ChildStdin>>>,
    wait_signals: BTreeMap<String, u64>,
    used_nonces: BTreeMap<String, i64>,
    event_base_cursor: u64,
    events: VecDeque<Value>,
}

impl Daemon {
    pub fn new(version: &str) -> Self {
        Self {
            inner: Arc::new(DaemonInner {
                version: version.to_string(),
                state: Mutex::new(CoreState {
                    next_session_id: 1,
                    next_attachment_id: 1,
                    next_window_id: 1,
                    next_pane_id: 1,
                    next_event_id: 1,
                    sessions: BTreeMap::new(),
                    buffers: BTreeMap::new(),
                    pane_pipes: BTreeMap::new(),
                    wait_signals: BTreeMap::new(),
                    used_nonces: BTreeMap::new(),
                    event_base_cursor: 0,
                    events: VecDeque::new(),
                }),
                state_cv: Condvar::new(),
                proxies: ProxyManager::new(),
            }),
        }
    }

    pub fn serve_stdio<R: Read, W: Write>(&self, input: R, mut output: W) -> Result<(), String> {
        let mut reader = BufReader::new(input);
        loop {
            let response = match read_frame(&mut reader) {
                Ok(FrameRead::Eof) => return Ok(()),
                Ok(FrameRead::Oversized) => rpc_error(
                    None,
                    "invalid_request",
                    "request frame exceeds maximum size",
                ),
                Ok(FrameRead::Frame(frame)) => self.parse_and_dispatch(&frame, None),
                Err(err) => return Err(err.to_string()),
            };
            write_response(&mut output, &response).map_err(|err| err.to_string())?;
        }
    }

    pub fn serve_unix(&self, cfg: UnixServeConfig) -> Result<(), String> {
        if cfg.socket_path.trim().is_empty() {
            return Err("missing daemon socket path".to_string());
        }
        if let (Some(ws_port), Some(ws_secret)) = (cfg.ws_port, cfg.ws_secret.as_ref()) {
            if !ws_secret.is_empty() {
                let daemon = self.clone();
                let ws_secret = ws_secret.clone();
                thread::spawn(move || {
                    let _ = daemon.serve_websocket(ws_port, &ws_secret);
                });
            }
        }
        if let Some(parent) = Path::new(&cfg.socket_path).parent() {
            fs::create_dir_all(parent).map_err(|err| err.to_string())?;
        }
        if Path::new(&cfg.socket_path).exists() {
            let _ = fs::remove_file(&cfg.socket_path);
        }

        let listener = UnixListener::bind(&cfg.socket_path).map_err(|err| err.to_string())?;
        for stream in listener.incoming() {
            match stream {
                Ok(stream) => {
                    let daemon = self.clone();
                    thread::spawn(move || {
                        if let Err(err) = daemon.serve_stream(stream, None) {
                            debug_log(&format!("unix stream closed with error: {err}"));
                        }
                    });
                }
                Err(err) => return Err(err.to_string()),
            }
        }
        Ok(())
    }

    fn serve_websocket(&self, port: u16, secret: &str) -> Result<(), String> {
        let listener = TcpListener::bind(("0.0.0.0", port)).map_err(|err| err.to_string())?;
        for stream in listener.incoming() {
            match stream {
                Ok(stream) => {
                    let daemon = self.clone();
                    let secret = secret.to_string();
                    thread::spawn(move || {
                        if let Err(err) = daemon.serve_websocket_stream(stream, &secret) {
                            debug_log(&format!("websocket stream closed with error: {err}"));
                        }
                    });
                }
                Err(err) => return Err(err.to_string()),
            }
        }
        Ok(())
    }

    pub fn serve_tls(&self, cfg: TlsServeConfig) -> Result<(), String> {
        if cfg.listen_addr.is_empty()
            || cfg.server_id.is_empty()
            || cfg.ticket_secret.is_empty()
            || cfg.cert_file.is_empty()
            || cfg.key_file.is_empty()
        {
            return Err(
                "tls listener requires listen address, cert, key, server id, and ticket secret"
                    .to_string(),
            );
        }

        let cert_chain = load_certs(&cfg.cert_file)?;
        let private_key = load_key(&cfg.key_file)?;
        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(cert_chain, private_key)
            .map_err(|err| err.to_string())?;
        let config = Arc::new(config);
        let listener = TcpListener::bind(&cfg.listen_addr).map_err(|err| err.to_string())?;

        for stream in listener.incoming() {
            match stream {
                Ok(stream) => {
                    let daemon = self.clone();
                    let config = Arc::clone(&config);
                    let server_id = cfg.server_id.clone();
                    let ticket_secret = cfg.ticket_secret.clone();
                    thread::spawn(move || {
                        let connection =
                            rustls::ServerConnection::new(config).map_err(|err| err.to_string());
                        if let Ok(connection) = connection {
                            let stream = rustls::StreamOwned::new(connection, stream);
                            if let Err(err) = daemon.serve_tls_stream(
                                stream,
                                &server_id,
                                ticket_secret.as_bytes(),
                            ) {
                                debug_log(&format!("tls stream closed with error: {err}"));
                            }
                        } else if let Err(err) = connection {
                            debug_log(&format!("failed to create tls server connection: {err}"));
                        }
                    });
                }
                Err(err) => return Err(err.to_string()),
            }
        }
        Ok(())
    }

    #[allow(dead_code)]
    pub fn dispatch_json(&self, method: &str, params: Value) -> Result<Value, String> {
        let request = Request {
            id: Some(json!(1)),
            method: method.to_string(),
            params,
        };
        let response = self.handle_request(&request);
        if response.ok {
            Ok(response.result.unwrap_or_else(|| json!({})))
        } else {
            Err(response
                .error
                .map(|value| value.message)
                .unwrap_or_else(|| "request failed".to_string()))
        }
    }

    pub fn signal_wait(&self, name: &str) -> u64 {
        let mut state = self.inner.state.lock().unwrap();
        let next = state.wait_signals.get(name).copied().unwrap_or(0) + 1;
        state.wait_signals.insert(name.to_string(), next);
        self.emit_event_locked(
            &mut state,
            "wait.signal",
            json!({ "name": name, "generation": next }),
        );
        self.inner.state_cv.notify_all();
        next
    }

    pub fn sessions(&self) -> Vec<Arc<Session>> {
        self.inner
            .state
            .lock()
            .unwrap()
            .sessions
            .values()
            .cloned()
            .collect()
    }

    pub fn find_session(&self, session_id: &str) -> Option<Arc<Session>> {
        self.inner
            .state
            .lock()
            .unwrap()
            .sessions
            .get(session_id)
            .cloned()
    }

    pub fn find_pane_by_id(
        &self,
        pane_id: &str,
    ) -> Option<(Arc<Session>, String, Arc<PaneHandle>)> {
        for session in self.sessions() {
            let inner = session.inner.lock().unwrap();
            for window in &inner.windows {
                for pane in &window.panes {
                    if pane.pane_id == pane_id {
                        return Some((
                            Arc::clone(&session),
                            window.id.clone(),
                            Arc::clone(&pane.handle),
                        ));
                    }
                }
            }
        }
        None
    }

    fn serve_stream<S: Read + Write>(
        &self,
        stream: S,
        authorizer: Option<DirectAuthorizer>,
    ) -> Result<(), String> {
        self.serve_reader(BufReader::new(stream), authorizer)
    }

    fn serve_reader<S: Read + Write>(
        &self,
        mut reader: BufReader<S>,
        authorizer: Option<DirectAuthorizer>,
    ) -> Result<(), String> {
        let mut authorizer = authorizer;
        let mut last_method: Option<String> = None;
        loop {
            let response = match read_frame(&mut reader) {
                Ok(FrameRead::Eof) => return Ok(()),
                Ok(FrameRead::Oversized) => rpc_error(
                    None,
                    "invalid_request",
                    "request frame exceeds maximum size",
                ),
                Ok(FrameRead::Frame(frame)) => {
                    last_method = request_method_for_frame(&frame);
                    self.parse_and_dispatch(&frame, authorizer.as_mut())
                }
                Err(err) => {
                    let context = last_method.as_deref().unwrap_or("unknown");
                    return Err(format!("read_frame after {context}: {err}"));
                }
            };
            if let Err(err) = write_response(reader.get_mut(), &response) {
                let context = last_method.as_deref().unwrap_or("unknown");
                return Err(format!("write_response for {context}: {err}"));
            }
        }
    }

    fn serve_tls_stream<S: Read + Write>(
        &self,
        stream: S,
        expected_server_id: &str,
        ticket_secret: &[u8],
    ) -> Result<(), String> {
        let mut reader = BufReader::new(stream);
        let frame = match read_frame(&mut reader) {
            Ok(FrameRead::Frame(frame)) => frame,
            Ok(FrameRead::Oversized) => {
                write_response(
                    reader.get_mut(),
                    &rpc_error(
                        None,
                        "invalid_request",
                        "handshake frame exceeds maximum size",
                    ),
                )
                .map_err(|err| err.to_string())?;
                return Ok(());
            }
            Ok(FrameRead::Eof) => return Ok(()),
            Err(err) => return Err(err.to_string()),
        };
        let value: Value = match serde_json::from_slice(trim_crlf(&frame)) {
            Ok(value) => value,
            Err(_) => {
                write_response(
                    reader.get_mut(),
                    &rpc_error(None, "invalid_request", "invalid JSON handshake"),
                )
                .map_err(|err| err.to_string())?;
                return Ok(());
            }
        };
        let Some(ticket) = value.get("ticket").and_then(Value::as_str) else {
            write_response(
                reader.get_mut(),
                &rpc_error(None, "invalid_request", "ticket is required"),
            )
            .map_err(|err| err.to_string())?;
            return Ok(());
        };
        let claims = match verify_ticket(ticket, ticket_secret, expected_server_id) {
            Ok(claims) => claims,
            Err(err) => {
                write_response(
                    reader.get_mut(),
                    &rpc_error(None, "unauthorized", err.to_string()),
                )
                .map_err(|write_err| write_err.to_string())?;
                return Ok(());
            }
        };
        if !has_session_capability(&claims.capabilities) {
            write_response(
                reader.get_mut(),
                &rpc_error(None, "unauthorized", "ticket missing session capability"),
            )
            .map_err(|err| err.to_string())?;
            return Ok(());
        }
        if claims.nonce.trim().is_empty() {
            write_response(
                reader.get_mut(),
                &rpc_error(None, "unauthorized", "ticket nonce is required"),
            )
            .map_err(|err| err.to_string())?;
            return Ok(());
        }
        if let Err(message) = self.consume_nonce(&claims.nonce, claims.exp) {
            write_response(reader.get_mut(), &rpc_error(None, "unauthorized", message))
                .map_err(|err| err.to_string())?;
            return Ok(());
        }
        write_response(
            reader.get_mut(),
            &rpc_ok(None, json!({ "authenticated": true })),
        )
        .map_err(|err| err.to_string())?;
        self.serve_reader(reader, Some(DirectAuthorizer::new(claims)))
    }

    fn parse_and_dispatch(
        &self,
        frame: &[u8],
        authorizer: Option<&mut DirectAuthorizer>,
    ) -> Response {
        let request = match serde_json::from_slice::<Request>(trim_crlf(frame)) {
            Ok(value) => value,
            Err(_) => return rpc_error(None, "invalid_request", "invalid JSON request"),
        };
        if let Some(authorizer) = authorizer {
            authorizer.handle(self, &request)
        } else {
            self.handle_request(&request)
        }
    }

    fn handle_request(&self, request: &Request) -> Response {
        if request.method.is_empty() {
            return rpc_error(request.id.clone(), "invalid_request", "method is required");
        }
        match request.method.as_str() {
            "hello" => rpc_ok(
                request.id.clone(),
                json!({
                    "name": "cmuxd-remote",
                    "version": self.inner.version,
                    "capabilities": [
                        "session.basic",
                        "session.resize.min",
                        "terminal.stream",
                        "proxy.http_connect",
                        "proxy.socks5",
                        "proxy.stream",
                        "amux.capture",
                        "amux.wait",
                        "amux.events.read",
                        "tmux.exec",
                    ],
                }),
            ),
            "ping" => rpc_ok(request.id.clone(), json!({ "pong": true })),
            "proxy.open" => self.handle_proxy_open(request),
            "proxy.close" => self.handle_proxy_close(request),
            "proxy.write" => self.handle_proxy_write(request),
            "proxy.read" => self.handle_proxy_read(request),
            "session.open" => self.handle_session_open(request),
            "session.close" => self.handle_session_close(request),
            "session.attach" => self.handle_session_attach(request),
            "session.resize" => self.handle_session_resize(request),
            "session.detach" => self.handle_session_detach(request),
            "session.status" => self.handle_session_status(request),
            "session.list" => self.handle_session_list(request),
            "session.history" => self.handle_session_history(request),
            "terminal.open" => self.handle_terminal_open(request),
            "terminal.read" => self.handle_terminal_read(request),
            "terminal.write" => self.handle_terminal_write(request),
            "amux.capture" => self.handle_amux_capture(request),
            "amux.wait" => self.handle_amux_wait(request),
            "amux.events.read" => self.handle_amux_events_read(request),
            "tmux.exec" => self.handle_tmux_exec(request),
            _ => rpc_error(request.id.clone(), "method_not_found", "unknown method"),
        }
    }

    fn handle_proxy_open(&self, request: &Request) -> Response {
        let Some(host) = get_string(&request.params, "host") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "proxy.open requires host",
            );
        };
        let Some(port) = get_positive_u16(&request.params, "port") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "proxy.open requires port in range 1-65535",
            );
        };
        let timeout_ms =
            get_non_negative_i64(&request.params, "timeout_ms").unwrap_or(10_000) as u64;
        match self.inner.proxies.open(host, port, timeout_ms) {
            Ok(stream_id) => rpc_ok(request.id.clone(), json!({ "stream_id": stream_id })),
            Err(err) => rpc_error(request.id.clone(), "open_failed", err.to_string()),
        }
    }

    fn handle_proxy_close(&self, request: &Request) -> Response {
        let Some(stream_id) = get_string(&request.params, "stream_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "proxy.close requires stream_id",
            );
        };
        match self.inner.proxies.close(stream_id) {
            Ok(()) => rpc_ok(request.id.clone(), json!({ "closed": true })),
            Err(_) => rpc_error(request.id.clone(), "not_found", "stream not found"),
        }
    }

    fn handle_proxy_write(&self, request: &Request) -> Response {
        let Some(stream_id) = get_string(&request.params, "stream_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "proxy.write requires stream_id",
            );
        };
        let Some(encoded) = get_string(&request.params, "data_base64") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "proxy.write requires data_base64",
            );
        };
        let data = match base64::engine::general_purpose::STANDARD.decode(encoded) {
            Ok(value) => value,
            Err(_) => {
                return rpc_error(
                    request.id.clone(),
                    "invalid_params",
                    "data_base64 must be valid base64",
                );
            }
        };
        match self.inner.proxies.write(stream_id, &data) {
            Ok(written) => rpc_ok(request.id.clone(), json!({ "written": written })),
            Err(ProxyError::NotFound) => {
                rpc_error(request.id.clone(), "not_found", "stream not found")
            }
            Err(err) => rpc_error(request.id.clone(), "stream_error", err.to_string()),
        }
    }

    fn handle_proxy_read(&self, request: &Request) -> Response {
        let Some(stream_id) = get_string(&request.params, "stream_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "proxy.read requires stream_id",
            );
        };
        let max_bytes = get_positive_usize(&request.params, "max_bytes").unwrap_or(32_768);
        if max_bytes > 262_144 {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "max_bytes must be in range 1-262144",
            );
        }
        let timeout_ms = get_non_negative_i64(&request.params, "timeout_ms").unwrap_or(50) as i32;
        match self.inner.proxies.read(stream_id, max_bytes, timeout_ms) {
            Ok(read) => rpc_ok(
                request.id.clone(),
                json!({
                    "data_base64": base64::engine::general_purpose::STANDARD.encode(read.data),
                    "eof": read.eof,
                }),
            ),
            Err(ProxyError::NotFound) => {
                rpc_error(request.id.clone(), "not_found", "stream not found")
            }
            Err(err) => rpc_error(request.id.clone(), "stream_error", err.to_string()),
        }
    }

    fn handle_session_open(&self, request: &Request) -> Response {
        let session_id = get_string(&request.params, "session_id").map(ToString::to_string);
        match self.ensure_session(session_id.as_deref()) {
            Ok(snapshot) => rpc_ok(request.id.clone(), snapshot_value(snapshot, None, None)),
            Err(err) => rpc_error(request.id.clone(), "internal_error", err),
        }
    }

    fn handle_session_close(&self, request: &Request) -> Response {
        let Some(session_id) = get_string(&request.params, "session_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.close requires session_id",
            );
        };
        match self.close_session(session_id) {
            Ok(()) => rpc_ok(
                request.id.clone(),
                json!({ "session_id": session_id, "closed": true }),
            ),
            Err(_) => rpc_error(request.id.clone(), "not_found", "session not found"),
        }
    }

    fn handle_session_attach(&self, request: &Request) -> Response {
        let Some(session_id) = get_string(&request.params, "session_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.attach requires session_id",
            );
        };
        let Some(attachment_id) = get_string(&request.params, "attachment_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.attach requires attachment_id",
            );
        };
        let Some(cols) = get_positive_u16(&request.params, "cols") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.attach requires cols > 0",
            );
        };
        let Some(rows) = get_positive_u16(&request.params, "rows") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.attach requires rows > 0",
            );
        };
        match self.attach_session(session_id, attachment_id, cols, rows) {
            Ok(snapshot) => rpc_ok(request.id.clone(), snapshot_value(snapshot, None, None)),
            Err(SessionError::NotFound) => {
                rpc_error(request.id.clone(), "not_found", "session not found")
            }
            Err(SessionError::AttachmentNotFound) => {
                rpc_error(request.id.clone(), "not_found", "attachment not found")
            }
            Err(SessionError::InvalidSize) => rpc_error(
                request.id.clone(),
                "invalid_params",
                "cols and rows must be greater than zero",
            ),
        }
    }

    fn handle_session_resize(&self, request: &Request) -> Response {
        let Some(session_id) = get_string(&request.params, "session_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.resize requires session_id",
            );
        };
        let Some(attachment_id) = get_string(&request.params, "attachment_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.resize requires attachment_id",
            );
        };
        let Some(cols) = get_positive_u16(&request.params, "cols") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.resize requires cols > 0",
            );
        };
        let Some(rows) = get_positive_u16(&request.params, "rows") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.resize requires rows > 0",
            );
        };
        match self.resize_session(session_id, attachment_id, cols, rows) {
            Ok(snapshot) => rpc_ok(request.id.clone(), snapshot_value(snapshot, None, None)),
            Err(SessionError::NotFound) => {
                rpc_error(request.id.clone(), "not_found", "session not found")
            }
            Err(SessionError::AttachmentNotFound) => {
                rpc_error(request.id.clone(), "not_found", "attachment not found")
            }
            Err(SessionError::InvalidSize) => rpc_error(
                request.id.clone(),
                "invalid_params",
                "cols and rows must be greater than zero",
            ),
        }
    }

    fn handle_session_detach(&self, request: &Request) -> Response {
        let Some(session_id) = get_string(&request.params, "session_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.detach requires session_id",
            );
        };
        let Some(attachment_id) = get_string(&request.params, "attachment_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.detach requires attachment_id",
            );
        };
        match self.detach_session(session_id, attachment_id) {
            Ok(snapshot) => rpc_ok(request.id.clone(), snapshot_value(snapshot, None, None)),
            Err(SessionError::NotFound) => {
                rpc_error(request.id.clone(), "not_found", "session not found")
            }
            Err(SessionError::AttachmentNotFound) => {
                rpc_error(request.id.clone(), "not_found", "attachment not found")
            }
            Err(SessionError::InvalidSize) => rpc_error(
                request.id.clone(),
                "invalid_params",
                "cols and rows must be greater than zero",
            ),
        }
    }

    fn handle_session_status(&self, request: &Request) -> Response {
        let Some(session_id) = get_string(&request.params, "session_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.status requires session_id",
            );
        };
        match self.find_session(session_id) {
            Some(session) => rpc_ok(
                request.id.clone(),
                snapshot_value(session.snapshot(), None, None),
            ),
            None => rpc_error(request.id.clone(), "not_found", "session not found"),
        }
    }

    fn handle_session_list(&self, request: &Request) -> Response {
        let sessions: Vec<SessionListEntry> = self
            .sessions()
            .into_iter()
            .map(|session| session.list_entry())
            .collect();
        rpc_ok(request.id.clone(), json!({ "sessions": sessions }))
    }

    fn handle_session_history(&self, request: &Request) -> Response {
        let Some(session_id) = get_string(&request.params, "session_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "session.history requires session_id",
            );
        };
        let Some((_, _, pane)) = self.resolve_active_pane(session_id) else {
            return rpc_error(
                request.id.clone(),
                "not_found",
                "terminal session not found",
            );
        };
        match pane.capture(true) {
            Ok(capture) => {
                let history = join_history(&capture.capture.history, &capture.capture.visible);
                rpc_ok(
                    request.id.clone(),
                    json!({ "session_id": session_id, "history": history }),
                )
            }
            Err(err) => rpc_error(request.id.clone(), "internal_error", err),
        }
    }

    fn handle_terminal_open(&self, request: &Request) -> Response {
        let Some(command) = get_string(&request.params, "command") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "terminal.open requires command",
            );
        };
        let Some(cols) = get_positive_u16(&request.params, "cols") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "terminal.open requires cols > 0",
            );
        };
        let Some(rows) = get_positive_u16(&request.params, "rows") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "terminal.open requires rows > 0",
            );
        };
        let requested_session_id = get_string(&request.params, "session_id");

        match self.open_terminal(requested_session_id, command, cols, rows) {
            Ok((snapshot, attachment_id)) => rpc_ok(
                request.id.clone(),
                snapshot_value(snapshot, Some(attachment_id), Some(0)),
            ),
            Err(OpenTerminalError::AlreadyExists) => rpc_error(
                request.id.clone(),
                "already_exists",
                "session already exists",
            ),
            Err(OpenTerminalError::Other(err)) => {
                rpc_error(request.id.clone(), "internal_error", err)
            }
        }
    }

    fn handle_terminal_read(&self, request: &Request) -> Response {
        let Some(session_id) = get_string(&request.params, "session_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "terminal.read requires session_id",
            );
        };
        let Some(offset) = get_non_negative_u64(&request.params, "offset") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "terminal.read requires offset >= 0",
            );
        };
        let max_bytes = get_positive_usize(&request.params, "max_bytes").unwrap_or(65_536);
        let timeout_ms = get_non_negative_i64(&request.params, "timeout_ms").unwrap_or(0) as i32;
        let Some((_, _, pane)) = self.resolve_active_pane(session_id) else {
            return rpc_error(
                request.id.clone(),
                "not_found",
                "terminal session not found",
            );
        };
        match pane.read(offset, max_bytes, timeout_ms) {
            Ok(read) => rpc_ok(
                request.id.clone(),
                json!({
                    "session_id": session_id,
                    "offset": read.offset,
                    "base_offset": read.base_offset,
                    "truncated": read.truncated,
                    "eof": read.eof,
                    "data": base64::engine::general_purpose::STANDARD.encode(read.data),
                }),
            ),
            Err(err) if err == "timeout" => rpc_error(
                request.id.clone(),
                "deadline_exceeded",
                "terminal read timed out",
            ),
            Err(err) => rpc_error(request.id.clone(), "internal_error", err),
        }
    }

    fn handle_terminal_write(&self, request: &Request) -> Response {
        let Some(session_id) = get_string(&request.params, "session_id") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "terminal.write requires session_id",
            );
        };
        let Some(encoded) = get_string(&request.params, "data") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "terminal.write requires data",
            );
        };
        let data = match base64::engine::general_purpose::STANDARD.decode(encoded) {
            Ok(value) => value,
            Err(_) => {
                return rpc_error(
                    request.id.clone(),
                    "invalid_params",
                    "terminal.write data must be base64",
                );
            }
        };
        let Some((_, _, pane)) = self.resolve_active_pane(session_id) else {
            return rpc_error(
                request.id.clone(),
                "not_found",
                "terminal session not found",
            );
        };
        match pane.write(data.clone()) {
            Ok(written) => rpc_ok(
                request.id.clone(),
                json!({ "session_id": session_id, "written": written }),
            ),
            Err(err) => rpc_error(request.id.clone(), "internal_error", err),
        }
    }

    fn handle_amux_capture(&self, request: &Request) -> Response {
        let include_history = get_bool(&request.params, "history").unwrap_or(true);
        let pane = if let Some(pane_id) = get_string(&request.params, "pane_id") {
            self.find_pane_by_id(pane_id)
        } else if let Some(session_id) = get_string(&request.params, "session_id") {
            self.resolve_active_pane(session_id)
        } else {
            None
        };
        let Some((_session, _window_id, pane)) = pane else {
            return rpc_error(request.id.clone(), "not_found", "pane not found");
        };
        match pane.capture(include_history) {
            Ok(capture) => rpc_ok(
                request.id.clone(),
                serde_json::to_value(capture).unwrap_or_else(|_| json!({})),
            ),
            Err(err) => rpc_error(request.id.clone(), "internal_error", err),
        }
    }

    fn handle_amux_wait(&self, request: &Request) -> Response {
        let Some(kind) = get_string(&request.params, "kind") else {
            return rpc_error(
                request.id.clone(),
                "invalid_params",
                "amux.wait requires kind",
            );
        };
        let timeout_ms =
            get_non_negative_i64(&request.params, "timeout_ms").unwrap_or(30_000) as u64;
        match kind {
            "signal" => {
                let Some(name) = get_string(&request.params, "name") else {
                    return rpc_error(
                        request.id.clone(),
                        "invalid_params",
                        "signal wait requires name",
                    );
                };
                let after_generation = get_non_negative_u64(&request.params, "after_generation")
                    .unwrap_or_else(|| self.current_signal_generation(name));
                match self.wait_for_signal(
                    name,
                    after_generation,
                    Duration::from_millis(timeout_ms),
                ) {
                    Ok(generation) => rpc_ok(
                        request.id.clone(),
                        json!({ "name": name, "generation": generation }),
                    ),
                    Err(err) => rpc_error(request.id.clone(), "deadline_exceeded", err),
                }
            }
            "content" => {
                let Some(needle) = get_string(&request.params, "needle") else {
                    return rpc_error(
                        request.id.clone(),
                        "invalid_params",
                        "content wait requires needle",
                    );
                };
                let pane = if let Some(pane_id) = get_string(&request.params, "pane_id") {
                    self.find_pane_by_id(pane_id)
                } else if let Some(session_id) = get_string(&request.params, "session_id") {
                    self.resolve_active_pane(session_id)
                } else {
                    None
                };
                let Some((_session, _window, pane)) = pane else {
                    return rpc_error(request.id.clone(), "not_found", "pane not found");
                };
                match self.wait_for_content(&pane, needle, Duration::from_millis(timeout_ms)) {
                    Ok(()) => rpc_ok(request.id.clone(), json!({ "matched": true })),
                    Err(err) => rpc_error(request.id.clone(), "deadline_exceeded", err),
                }
            }
            "exited" => {
                let pane = if let Some(pane_id) = get_string(&request.params, "pane_id") {
                    self.find_pane_by_id(pane_id)
                } else if let Some(session_id) = get_string(&request.params, "session_id") {
                    self.resolve_active_pane(session_id)
                } else {
                    None
                };
                let Some((_session, _window, pane)) = pane else {
                    return rpc_error(request.id.clone(), "not_found", "pane not found");
                };
                match self.wait_for_exit(&pane, Duration::from_millis(timeout_ms)) {
                    Ok(()) => rpc_ok(request.id.clone(), json!({ "exited": true })),
                    Err(err) => rpc_error(request.id.clone(), "deadline_exceeded", err),
                }
            }
            "busy" => {
                let pane = if let Some(pane_id) = get_string(&request.params, "pane_id") {
                    self.find_pane_by_id(pane_id)
                } else if let Some(session_id) = get_string(&request.params, "session_id") {
                    self.resolve_active_pane(session_id)
                } else {
                    None
                };
                let Some((session, _window, pane)) = pane else {
                    return rpc_error(request.id.clone(), "not_found", "pane not found");
                };
                match self.wait_for_busy(
                    &session.id,
                    &pane.pane_id,
                    &pane,
                    Duration::from_millis(timeout_ms),
                ) {
                    Ok(()) => rpc_ok(request.id.clone(), json!({ "busy": true })),
                    Err(err) => rpc_error(request.id.clone(), "deadline_exceeded", err),
                }
            }
            "ready" => {
                let pane = if let Some(pane_id) = get_string(&request.params, "pane_id") {
                    self.find_pane_by_id(pane_id)
                } else if let Some(session_id) = get_string(&request.params, "session_id") {
                    self.resolve_active_pane(session_id)
                } else {
                    None
                };
                let Some((_session, _window, pane)) = pane else {
                    return rpc_error(request.id.clone(), "not_found", "pane not found");
                };
                match self.wait_for_idle(&pane, Duration::from_millis(timeout_ms)) {
                    Ok(()) => rpc_ok(request.id.clone(), json!({ "ready": true })),
                    Err(err) => rpc_error(request.id.clone(), "deadline_exceeded", err),
                }
            }
            "idle" => {
                let pane = if let Some(pane_id) = get_string(&request.params, "pane_id") {
                    self.find_pane_by_id(pane_id)
                } else if let Some(session_id) = get_string(&request.params, "session_id") {
                    self.resolve_active_pane(session_id)
                } else {
                    None
                };
                let Some((_session, _window, pane)) = pane else {
                    return rpc_error(request.id.clone(), "not_found", "pane not found");
                };
                match self.wait_for_idle(&pane, Duration::from_millis(timeout_ms)) {
                    Ok(()) => rpc_ok(request.id.clone(), json!({ "idle": true })),
                    Err(err) => rpc_error(request.id.clone(), "deadline_exceeded", err),
                }
            }
            _ => rpc_error(
                request.id.clone(),
                "invalid_params",
                "unsupported wait kind",
            ),
        }
    }

    fn handle_amux_events_read(&self, request: &Request) -> Response {
        let cursor = get_non_negative_u64(&request.params, "cursor").unwrap_or(0);
        let timeout_ms = get_non_negative_i64(&request.params, "timeout_ms").unwrap_or(0) as u64;
        let filters = get_filters(&request.params);
        let session_id = get_string(&request.params, "session_id").map(ToString::to_string);
        let pane_id = get_string(&request.params, "pane_id").map(ToString::to_string);
        let (next_cursor, events) = self.read_events(
            cursor,
            Duration::from_millis(timeout_ms),
            &filters,
            session_id.as_deref(),
            pane_id.as_deref(),
        );
        rpc_ok(
            request.id.clone(),
            json!({
                "cursor": next_cursor,
                "events": events,
            }),
        )
    }

    fn handle_tmux_exec(&self, request: &Request) -> Response {
        let argv = match request.params.get("argv").and_then(Value::as_array) {
            Some(values) => {
                let mut argv = Vec::with_capacity(values.len());
                for value in values {
                    let Some(value) = value.as_str() else {
                        return rpc_error(
                            request.id.clone(),
                            "invalid_params",
                            "tmux.exec argv entries must be strings",
                        );
                    };
                    argv.push(value.to_string());
                }
                argv
            }
            None => {
                return rpc_error(
                    request.id.clone(),
                    "invalid_params",
                    "tmux.exec requires argv",
                );
            }
        };
        match self.tmux_exec(&argv) {
            Ok(result) => rpc_ok(request.id.clone(), result),
            Err(err) => rpc_error(request.id.clone(), "tmux_error", err),
        }
    }

    fn ensure_session(&self, requested_id: Option<&str>) -> Result<SessionSnapshot, String> {
        let session = {
            let mut state = self.inner.state.lock().unwrap();
            let session_id = match requested_id {
                Some(value) => value.to_string(),
                None => allocate_generated_session_id(&mut state),
            };
            if let Some(existing) = state.sessions.get(&session_id) {
                existing.clone()
            } else {
                let session = Arc::new(Session::new(session_id.clone()));
                state.sessions.insert(session_id, Arc::clone(&session));
                session
            }
        };
        Ok(session.snapshot())
    }

    fn open_terminal(
        &self,
        requested_session_id: Option<&str>,
        command: &str,
        cols: u16,
        rows: u16,
    ) -> Result<(SessionSnapshot, String), OpenTerminalError> {
        let (
            session,
            session_id,
            attachment_id,
            window_id,
            pane_id,
            effective_cols,
            effective_rows,
        ) = {
            let mut state = self.inner.state.lock().unwrap();
            let session_id = match requested_session_id {
                Some(value) => {
                    if state.sessions.contains_key(value) {
                        return Err(OpenTerminalError::AlreadyExists);
                    }
                    value.to_string()
                }
                None => allocate_generated_session_id(&mut state),
            };
            let attachment_id = format!("att-{}", state.next_attachment_id);
            state.next_attachment_id += 1;
            let window_id = format!("win-{}", state.next_window_id);
            state.next_window_id += 1;
            let pane_id = format!("pane-{}", state.next_pane_id);
            state.next_pane_id += 1;

            let session = Arc::new(Session::new(session_id.clone()));
            session
                .attach(attachment_id.clone(), cols, rows)
                .map_err(|err| OpenTerminalError::Other(format!("{err:?}")))?;
            let (effective_cols, effective_rows) = session.effective_size();
            (
                session,
                session_id,
                attachment_id,
                window_id,
                pane_id,
                effective_cols,
                effective_rows,
            )
        };

        let event_daemon = self.clone();
        let pane_events: EventCallback =
            Arc::new(move |event| event_daemon.handle_pane_event(event));
        let handle = PaneHandle::spawn(
            &session_id,
            &pane_id,
            command,
            effective_cols,
            effective_rows,
            pane_events,
        )
        .map_err(OpenTerminalError::Other)?;

        {
            let mut inner = session.inner.lock().unwrap();
            inner.windows.push(Window {
                id: window_id.clone(),
                name: session_id.clone(),
                panes: vec![PaneSlot {
                    pane_id: pane_id.clone(),
                    command: command.to_string(),
                    handle: Arc::clone(&handle),
                }],
                active_pane: 0,
                last_pane: None,
            });
            inner.active_window = 0;
        }

        {
            let mut state = self.inner.state.lock().unwrap();
            if state.sessions.contains_key(&session_id) {
                drop(state);
                handle.close();
                return Err(OpenTerminalError::AlreadyExists);
            }
            state
                .sessions
                .insert(session_id.clone(), Arc::clone(&session));
        }

        let mut state = self.inner.state.lock().unwrap();
        self.emit_event_locked(
            &mut state,
            "session.open",
            json!({ "session_id": session_id }),
        );
        self.emit_event_locked(
            &mut state,
            "window.open",
            json!({ "session_id": session_id, "window_id": window_id }),
        );
        self.emit_event_locked(
            &mut state,
            "pane.open",
            json!({ "session_id": session_id, "pane_id": pane_id }),
        );
        self.inner.state_cv.notify_all();
        Ok((session.snapshot(), attachment_id))
    }

    fn close_session(&self, session_id: &str) -> Result<(), SessionError> {
        let session = {
            let mut state = self.inner.state.lock().unwrap();
            state
                .sessions
                .remove(session_id)
                .ok_or(SessionError::NotFound)?
        };
        let close_events = self.session_close_events(&session);
        {
            let mut state = self.inner.state.lock().unwrap();
            for (kind, payload) in close_events {
                self.emit_event_locked(&mut state, kind, payload);
            }
            self.emit_event_locked(
                &mut state,
                "session.close",
                json!({ "session_id": session_id }),
            );
            self.inner.state_cv.notify_all();
        }
        for pane in collect_panes(&session) {
            self.tmux_close_pipe(&pane.pane_id);
            pane.close();
        }
        Ok(())
    }

    fn attach_session(
        &self,
        session_id: &str,
        attachment_id: &str,
        cols: u16,
        rows: u16,
    ) -> Result<SessionSnapshot, SessionError> {
        let session = self
            .find_session(session_id)
            .ok_or(SessionError::NotFound)?;
        session.attach(attachment_id.to_string(), cols, rows)?;
        self.resize_session_panes(&session);
        let snapshot = session.snapshot();
        let mut state = self.inner.state.lock().unwrap();
        self.emit_event_locked(
            &mut state,
            "session.attach",
            json!({ "session_id": session_id, "attachment_id": attachment_id, "cols": cols, "rows": rows }),
        );
        self.inner.state_cv.notify_all();
        Ok(snapshot)
    }

    fn resize_session(
        &self,
        session_id: &str,
        attachment_id: &str,
        cols: u16,
        rows: u16,
    ) -> Result<SessionSnapshot, SessionError> {
        let session = self
            .find_session(session_id)
            .ok_or(SessionError::NotFound)?;
        session.resize_attachment(attachment_id, cols, rows)?;
        self.resize_session_panes(&session);
        let snapshot = session.snapshot();
        let mut state = self.inner.state.lock().unwrap();
        self.emit_event_locked(
            &mut state,
            "session.resize",
            json!({ "session_id": session_id, "attachment_id": attachment_id, "cols": cols, "rows": rows }),
        );
        self.inner.state_cv.notify_all();
        Ok(snapshot)
    }

    fn detach_session(
        &self,
        session_id: &str,
        attachment_id: &str,
    ) -> Result<SessionSnapshot, SessionError> {
        let session = self
            .find_session(session_id)
            .ok_or(SessionError::NotFound)?;
        session.detach(attachment_id)?;
        self.resize_session_panes(&session);
        let snapshot = session.snapshot();
        let mut state = self.inner.state.lock().unwrap();
        self.emit_event_locked(
            &mut state,
            "session.detach",
            json!({ "session_id": session_id, "attachment_id": attachment_id }),
        );
        self.inner.state_cv.notify_all();
        Ok(snapshot)
    }

    fn resolve_active_pane(
        &self,
        session_id: &str,
    ) -> Option<(Arc<Session>, String, Arc<PaneHandle>)> {
        let session = self.find_session(session_id)?;
        let inner = session.inner.lock().unwrap();
        let window = inner.windows.get(inner.active_window)?;
        let pane = window.panes.get(window.active_pane)?;
        Some((session.clone(), window.id.clone(), pane.handle.clone()))
    }

    fn resize_session_panes(&self, session: &Arc<Session>) {
        let (cols, rows) = session.effective_size();
        if cols == 0 || rows == 0 {
            return;
        }
        for pane in collect_panes(session) {
            let _ = pane.resize(cols, rows);
        }
    }

    fn handle_pane_event(&self, event: PaneRuntimeEvent) {
        let mut pipe_write: Option<(String, Arc<Mutex<std::process::ChildStdin>>, Vec<u8>)> = None;
        let mut state = self.inner.state.lock().unwrap();
        match event {
            PaneRuntimeEvent::Output {
                session_id,
                pane_id,
                data,
            } => {
                if let Some(pipe) = state.pane_pipes.get(&pane_id) {
                    pipe_write = Some((pane_id.clone(), Arc::clone(pipe), data.clone()));
                }
                self.emit_event_locked(
                    &mut state,
                    "pane.output",
                    json!({ "session_id": session_id, "pane_id": pane_id, "len": data.len() }),
                )
            }
            PaneRuntimeEvent::Busy {
                session_id,
                pane_id,
            } => self.emit_event_locked(
                &mut state,
                "busy",
                json!({ "session_id": session_id, "pane_id": pane_id }),
            ),
            PaneRuntimeEvent::Idle {
                session_id,
                pane_id,
            } => self.emit_event_locked(
                &mut state,
                "idle",
                json!({ "session_id": session_id, "pane_id": pane_id }),
            ),
            PaneRuntimeEvent::Exit {
                session_id,
                pane_id,
            } => {
                state.pane_pipes.remove(&pane_id);
                self.emit_event_locked(
                    &mut state,
                    "exited",
                    json!({ "session_id": session_id, "pane_id": pane_id }),
                )
            }
        }
        self.inner.state_cv.notify_all();
        drop(state);

        if let Some((pane_id, pipe, data)) = pipe_write {
            let result = {
                let mut stdin = pipe.lock().unwrap();
                stdin
                    .write_all(&data)
                    .and_then(|_| stdin.flush())
                    .map_err(|err| err.to_string())
            };
            if result.is_err() {
                let mut state = self.inner.state.lock().unwrap();
                state.pane_pipes.remove(&pane_id);
            }
        }
    }

    fn current_signal_generation(&self, name: &str) -> u64 {
        self.inner
            .state
            .lock()
            .unwrap()
            .wait_signals
            .get(name)
            .copied()
            .unwrap_or(0)
    }

    fn wait_for_signal(
        &self,
        name: &str,
        after_generation: u64,
        timeout: Duration,
    ) -> Result<u64, String> {
        let deadline = Instant::now() + timeout;
        let mut state = self.inner.state.lock().unwrap();
        loop {
            if let Some(generation) = state.wait_signals.get(name).copied() {
                if generation > after_generation {
                    return Ok(generation);
                }
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(format!("wait timed out waiting for '{name}'"));
            }
            let (next_state, wait_result) = self
                .inner
                .state_cv
                .wait_timeout(state, deadline - now)
                .unwrap();
            state = next_state;
            if wait_result.timed_out() {
                return Err(format!("wait timed out waiting for '{name}'"));
            }
        }
    }

    fn wait_for_content(
        &self,
        pane: &PaneHandle,
        needle: &str,
        timeout: Duration,
    ) -> Result<(), String> {
        let deadline = Instant::now() + timeout;
        loop {
            let capture = pane.capture(true)?;
            let content = join_history(&capture.capture.history, &capture.capture.visible);
            if content.contains(needle) {
                return Ok(());
            }
            let now = Instant::now();
            if now >= deadline {
                return Err("content wait timed out".to_string());
            }
            let guard = pane.shared.state.lock().unwrap();
            let _ = pane.shared.cv.wait_timeout(guard, deadline - now).unwrap();
        }
    }

    fn wait_for_exit(&self, pane: &PaneHandle, timeout: Duration) -> Result<(), String> {
        let deadline = Instant::now() + timeout;
        let mut guard = pane.shared.state.lock().unwrap();
        loop {
            if guard.closed {
                return Ok(());
            }
            let now = Instant::now();
            if now >= deadline {
                return Err("exit wait timed out".to_string());
            }
            let (next_guard, wait_result) =
                pane.shared.cv.wait_timeout(guard, deadline - now).unwrap();
            guard = next_guard;
            if wait_result.timed_out() {
                return Err("exit wait timed out".to_string());
            }
        }
    }

    #[cfg(test)]
    fn current_event_cursor(&self) -> u64 {
        let state = self.inner.state.lock().unwrap();
        state.event_base_cursor + state.events.len() as u64
    }

    fn wait_for_busy(
        &self,
        _session_id: &str,
        _pane_id: &str,
        pane: &PaneHandle,
        timeout: Duration,
    ) -> Result<(), String> {
        let deadline = Instant::now() + timeout;
        let mut guard = pane.shared.state.lock().unwrap();
        let start_generation = guard.busy_generation;
        loop {
            if guard.busy || guard.busy_generation != start_generation {
                return Ok(());
            }
            let now = Instant::now();
            if now >= deadline {
                return Err("busy wait timed out".to_string());
            }
            let (next_guard, wait_result) =
                pane.shared.cv.wait_timeout(guard, deadline - now).unwrap();
            guard = next_guard;
            if wait_result.timed_out() {
                return Err("busy wait timed out".to_string());
            }
        }
    }

    fn wait_for_idle(&self, pane: &PaneHandle, timeout: Duration) -> Result<(), String> {
        let deadline = Instant::now() + timeout;
        let mut guard = pane.shared.state.lock().unwrap();
        loop {
            if !guard.busy {
                return Ok(());
            }
            let now = Instant::now();
            if now >= deadline {
                return Err("idle wait timed out".to_string());
            }
            let (next_guard, wait_result) =
                pane.shared.cv.wait_timeout(guard, deadline - now).unwrap();
            guard = next_guard;
            if wait_result.timed_out() {
                return Err("idle wait timed out".to_string());
            }
        }
    }

    fn read_events(
        &self,
        cursor: u64,
        timeout: Duration,
        filters: &BTreeSet<String>,
        session_id: Option<&str>,
        pane_id: Option<&str>,
    ) -> (u64, Vec<Value>) {
        let deadline = Instant::now() + timeout;
        let mut state = self.inner.state.lock().unwrap();
        loop {
            let filtered = collect_events(&state, cursor, filters, session_id, pane_id);
            if !filtered.is_empty() || timeout.is_zero() {
                let next_cursor = state.event_base_cursor + state.events.len() as u64;
                return (next_cursor, filtered);
            }
            let now = Instant::now();
            if now >= deadline {
                return (cursor, Vec::new());
            }
            let (next_state, wait_result) = self
                .inner
                .state_cv
                .wait_timeout(state, deadline - now)
                .unwrap();
            state = next_state;
            if wait_result.timed_out() {
                return (cursor, Vec::new());
            }
        }
    }

    fn consume_nonce(&self, nonce: &str, expires_at: i64) -> Result<(), String> {
        let now = unix_now_secs();
        let mut state = self.inner.state.lock().unwrap();
        state.used_nonces.retain(|_, expiry| *expiry > now);
        if state.used_nonces.contains_key(nonce) {
            return Err("ticket nonce already used".to_string());
        }
        state.used_nonces.insert(nonce.to_string(), expires_at);
        Ok(())
    }

    fn emit_event_locked(&self, state: &mut CoreState, kind: &str, payload: Value) {
        let cursor = state.next_event_id;
        state.next_event_id += 1;
        let mut event = json!({
            "cursor": cursor,
            "kind": kind,
            "time_ms": unix_now(),
        });
        if let (Some(event_obj), Some(payload_obj)) = (event.as_object_mut(), payload.as_object()) {
            for (key, value) in payload_obj {
                event_obj.insert(key.clone(), value.clone());
            }
        }
        state.events.push_back(event);
        while state.events.len() > 4096 {
            state.events.pop_front();
            state.event_base_cursor += 1;
        }
    }
}

fn request_method_for_frame(frame: &[u8]) -> Option<String> {
    serde_json::from_slice::<Value>(trim_crlf(frame))
        .ok()
        .and_then(|value| {
            value
                .get("method")
                .and_then(Value::as_str)
                .map(ToString::to_string)
        })
}

fn debug_log(message: &str) {
    if env::var_os("CMUX_REMOTE_DEBUG_LOG").is_some() {
        eprintln!("cmuxd-remote debug: {message}");
    }
}

impl Daemon {
    fn tmux_exec(&self, argv: &[String]) -> Result<Value, String> {
        if argv.is_empty() {
            return Err("tmux.exec requires a command".to_string());
        }

        let command = argv[0].as_str();
        let raw_args = &argv[1..];

        match command {
            "new-session" | "new" => {
                let parsed = parse_tmux_args(
                    raw_args,
                    &["-c", "-F", "-n", "-s", "-x", "-y"],
                    &["-A", "-d", "-P"],
                )?;
                let requested_session = parsed.value("-s").map(ToString::to_string);
                let command_text = tmux_shell_command(parsed.positional(), parsed.value("-c"));
                let cols = parsed
                    .value("-x")
                    .and_then(|value| value.parse::<u16>().ok())
                    .filter(|value| *value > 0)
                    .unwrap_or(80);
                let rows = parsed
                    .value("-y")
                    .and_then(|value| value.parse::<u16>().ok())
                    .filter(|value| *value > 0)
                    .unwrap_or(24);

                let session = if parsed.has_flag("-A") {
                    requested_session
                        .as_deref()
                        .and_then(|value| self.find_session(value))
                } else {
                    None
                };

                let (session, window_index, pane_index) = if let Some(session) = session {
                    let inner = session.inner.lock().unwrap();
                    if inner.windows.is_empty() {
                        return Err("existing session has no windows".to_string());
                    }
                    (
                        session.clone(),
                        inner.active_window,
                        inner.windows[inner.active_window].active_pane,
                    )
                } else {
                    let (snapshot, attachment_id) = self
                        .open_terminal(requested_session.as_deref(), &command_text, cols, rows)
                        .map_err(tmux_open_terminal_error)?;
                    let session = self
                        .find_session(&snapshot.session_id)
                        .ok_or_else(|| "created session disappeared".to_string())?;
                    let _ = self.detach_session(&snapshot.session_id, &attachment_id);
                    if let Some(title) = parsed.value("-n") {
                        if !title.trim().is_empty() {
                            let mut inner = session.inner.lock().unwrap();
                            if let Some(window) = inner.windows.get_mut(0) {
                                window.name = title.to_string();
                            }
                        }
                    }
                    (session, 0, 0)
                };

                let stdout = if parsed.has_flag("-P") {
                    let context =
                        self.tmux_format_context(&session, window_index, Some(pane_index))?;
                    tmux_render_format(
                        parsed.value("-F"),
                        &context,
                        &tmux_session_display_id(&session.id),
                    )
                } else {
                    String::new()
                };

                Ok(tmux_result(
                    stdout,
                    json!({
                        "session_id": session.id,
                        "window_id": tmux_window_display_id(&self.tmux_window_id(&session, window_index)?),
                        "pane_id": tmux_pane_display_id(&self.tmux_pane_id(&session, window_index, pane_index)?),
                    }),
                ))
            }
            "new-window" | "neww" => {
                let parsed = parse_tmux_args(raw_args, &["-c", "-F", "-n", "-t"], &["-d", "-P"])?;
                let session = self.tmux_resolve_session(parsed.value("-t"))?;
                let (window_index, pane_index) = self.tmux_create_window(
                    &session,
                    parsed.value("-n").map(ToString::to_string),
                    &tmux_shell_command(parsed.positional(), parsed.value("-c")),
                    !parsed.has_flag("-d"),
                )?;
                let stdout = if parsed.has_flag("-P") {
                    let context =
                        self.tmux_format_context(&session, window_index, Some(pane_index))?;
                    let pane_id = self.tmux_pane_id(&session, window_index, pane_index)?;
                    tmux_render_format(
                        parsed.value("-F"),
                        &context,
                        &tmux_pane_display_id(&pane_id),
                    )
                } else {
                    String::new()
                };
                Ok(tmux_result(
                    stdout,
                    json!({
                        "session_id": session.id,
                        "window_id": tmux_window_display_id(&self.tmux_window_id(&session, window_index)?),
                        "pane_id": tmux_pane_display_id(&self.tmux_pane_id(&session, window_index, pane_index)?),
                    }),
                ))
            }
            "split-window" | "splitw" => {
                let parsed = parse_tmux_args(
                    raw_args,
                    &["-c", "-F", "-l", "-t"],
                    &["-P", "-b", "-d", "-h", "-v"],
                )?;
                let target = self.tmux_resolve_pane(parsed.value("-t"))?;
                let pane_index = self.tmux_create_pane(
                    &target.session,
                    target.window_index,
                    &tmux_shell_command(parsed.positional(), parsed.value("-c")),
                    !parsed.has_flag("-d"),
                )?;
                let stdout = if parsed.has_flag("-P") {
                    let context = self.tmux_format_context(
                        &target.session,
                        target.window_index,
                        Some(pane_index),
                    )?;
                    let pane_id =
                        self.tmux_pane_id(&target.session, target.window_index, pane_index)?;
                    tmux_render_format(
                        parsed.value("-F"),
                        &context,
                        &tmux_pane_display_id(&pane_id),
                    )
                } else {
                    String::new()
                };
                Ok(tmux_result(
                    stdout,
                    json!({
                        "session_id": target.session.id,
                        "window_id": tmux_window_display_id(&self.tmux_window_id(&target.session, target.window_index)?),
                        "pane_id": tmux_pane_display_id(&self.tmux_pane_id(&target.session, target.window_index, pane_index)?),
                    }),
                ))
            }
            "select-window" | "selectw" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &[])?;
                let target = self.tmux_resolve_window(parsed.value("-t"))?;
                self.tmux_select_window(&target.session, target.window_index)?;
                Ok(tmux_result(
                    String::new(),
                    json!({ "session_id": target.session.id }),
                ))
            }
            "select-pane" | "selectp" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &[])?;
                let target = self.tmux_resolve_pane(parsed.value("-t"))?;
                self.tmux_select_pane(&target.session, target.window_index, target.pane_index)?;
                Ok(tmux_result(
                    String::new(),
                    json!({
                        "session_id": target.session.id,
                        "pane_id": tmux_pane_display_id(&target.pane_id),
                    }),
                ))
            }
            "kill-window" | "killw" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &[])?;
                let target = self.tmux_resolve_window(parsed.value("-t"))?;
                self.tmux_kill_window(&target.session, target.window_index)?;
                Ok(tmux_result(
                    String::new(),
                    json!({ "session_id": target.session.id }),
                ))
            }
            "kill-pane" | "killp" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &[])?;
                let target = self.tmux_resolve_pane(parsed.value("-t"))?;
                self.tmux_kill_pane(&target.session, target.window_index, target.pane_index)?;
                Ok(tmux_result(
                    String::new(),
                    json!({
                        "session_id": target.session.id,
                        "pane_id": tmux_pane_display_id(&target.pane_id),
                    }),
                ))
            }
            "send-keys" | "send" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &["-l"])?;
                let target = self.tmux_resolve_pane(parsed.value("-t"))?;
                let data = tmux_send_keys_bytes(parsed.positional(), parsed.has_flag("-l"));
                target
                    .handle
                    .write(data)
                    .map_err(|err| format!("send-keys failed: {err}"))?;
                Ok(tmux_result(
                    String::new(),
                    json!({
                        "session_id": target.session.id,
                        "pane_id": tmux_pane_display_id(&target.pane_id),
                    }),
                ))
            }
            "capture-pane" | "capturep" => {
                let parsed = parse_tmux_args(
                    raw_args,
                    &["-E", "-S", "-t"],
                    &["-J", "-N", "-p", "-e", "-q"],
                )?;
                let target = self.tmux_resolve_pane(parsed.value("-t"))?;
                let include_history = parsed
                    .value("-S")
                    .map(|value| {
                        value == "-" || value.parse::<i64>().map(|line| line < 0).unwrap_or(false)
                    })
                    .unwrap_or(false);
                let capture = target.handle.capture(include_history)?;
                let text = tmux_capture_text(
                    &capture.capture,
                    include_history,
                    parsed.value("-S"),
                    parsed.value("-E"),
                );
                if parsed.has_flag("-p") {
                    Ok(tmux_result(
                        tmux_line_output(&text),
                        json!({
                            "session_id": target.session.id,
                            "pane_id": tmux_pane_display_id(&target.pane_id),
                        }),
                    ))
                } else {
                    let mut state = self.inner.state.lock().unwrap();
                    state.buffers.insert("default".to_string(), text.clone());
                    Ok(tmux_result(
                        String::new(),
                        json!({
                            "buffer": "default",
                            "bytes": text.len(),
                        }),
                    ))
                }
            }
            "display-message" | "display" | "displayp" => {
                let parsed = parse_tmux_args(raw_args, &["-F", "-t"], &["-p"])?;
                let target = self.tmux_resolve_pane(parsed.value("-t"))?;
                let context = self.tmux_format_context(
                    &target.session,
                    target.window_index,
                    Some(target.pane_index),
                )?;
                let owned_format;
                let format = if parsed.positional().is_empty() {
                    parsed.value("-F")
                } else {
                    owned_format = parsed.positional().join(" ");
                    Some(owned_format.as_str())
                };
                let rendered = tmux_render_format(format, &context, "");
                Ok(tmux_result(
                    tmux_line_output(&rendered),
                    json!({
                        "session_id": target.session.id,
                        "pane_id": tmux_pane_display_id(&target.pane_id),
                    }),
                ))
            }
            "list-windows" | "lsw" => {
                let parsed = parse_tmux_args(raw_args, &["-F", "-t"], &[])?;
                let session = self.tmux_resolve_session(parsed.value("-t"))?;
                let window_count = session.inner.lock().unwrap().windows.len();
                let mut lines = Vec::with_capacity(window_count);
                for window_index in 0..window_count {
                    let context = self.tmux_format_context(&session, window_index, None)?;
                    let window_id = self.tmux_window_id(&session, window_index)?;
                    let fallback =
                        format!("{} {}", window_index, tmux_window_display_id(&window_id));
                    lines.push(tmux_render_format(parsed.value("-F"), &context, &fallback));
                }
                Ok(tmux_result(
                    lines.join("\n"),
                    json!({ "session_id": session.id }),
                ))
            }
            "list-panes" | "lsp" => {
                let parsed = parse_tmux_args(raw_args, &["-F", "-t"], &[])?;
                let window = self.tmux_resolve_window(parsed.value("-t"))?;
                let pane_count = {
                    let inner = window.session.inner.lock().unwrap();
                    inner
                        .windows
                        .get(window.window_index)
                        .map(|value| value.panes.len())
                        .ok_or_else(|| "window not found".to_string())?
                };
                let mut lines = Vec::with_capacity(pane_count);
                for pane_index in 0..pane_count {
                    let context = self.tmux_format_context(
                        &window.session,
                        window.window_index,
                        Some(pane_index),
                    )?;
                    let pane_id =
                        self.tmux_pane_id(&window.session, window.window_index, pane_index)?;
                    lines.push(tmux_render_format(
                        parsed.value("-F"),
                        &context,
                        &tmux_pane_display_id(&pane_id),
                    ));
                }
                Ok(tmux_result(
                    lines.join("\n"),
                    json!({
                        "session_id": window.session.id,
                        "window_id": tmux_window_display_id(&self.tmux_window_id(&window.session, window.window_index)?),
                    }),
                ))
            }
            "rename-window" | "renamew" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &[])?;
                let title = parsed.positional().join(" ").trim().to_string();
                if title.is_empty() {
                    return Err("rename-window requires a title".to_string());
                }
                let target = self.tmux_resolve_window(parsed.value("-t"))?;
                let mut inner = target.session.inner.lock().unwrap();
                let window = inner
                    .windows
                    .get_mut(target.window_index)
                    .ok_or_else(|| "window not found".to_string())?;
                window.name = title;
                Ok(tmux_result(
                    String::new(),
                    json!({ "session_id": target.session.id }),
                ))
            }
            "resize-pane" | "resizep" => {
                let parsed =
                    parse_tmux_args(raw_args, &["-t", "-x", "-y"], &["-D", "-L", "-R", "-U"])?;
                let target = self.tmux_resolve_pane(parsed.value("-t"))?;
                let exact_cols = parsed
                    .value("-x")
                    .and_then(|value| value.trim_end_matches('%').parse::<u16>().ok())
                    .filter(|value| *value > 0);
                let exact_rows = parsed
                    .value("-y")
                    .and_then(|value| value.trim_end_matches('%').parse::<u16>().ok())
                    .filter(|value| *value > 0);
                let amount = exact_cols.or(exact_rows).unwrap_or(5);
                let capture = target.handle.capture(false)?;
                let mut cols = capture.capture.cols.max(2);
                let mut rows = capture.capture.rows.max(1);
                if parsed.has_flag("-L") {
                    cols = cols.saturating_sub(amount).max(2);
                } else if parsed.has_flag("-R") {
                    cols = cols.saturating_add(amount);
                } else if parsed.has_flag("-U") {
                    rows = rows.saturating_sub(amount).max(1);
                } else if parsed.has_flag("-D") {
                    rows = rows.saturating_add(amount);
                } else {
                    if let Some(exact_cols) = exact_cols {
                        cols = exact_cols.max(2);
                    }
                    if let Some(exact_rows) = exact_rows {
                        rows = exact_rows.max(1);
                    }
                }
                target.handle.resize(cols, rows)?;
                Ok(tmux_result(
                    String::new(),
                    json!({
                        "session_id": target.session.id,
                        "pane_id": tmux_pane_display_id(&target.pane_id),
                        "cols": cols,
                        "rows": rows,
                    }),
                ))
            }
            "wait-for" => {
                let parsed = parse_tmux_args(raw_args, &[], &["-S"])?;
                let name = parsed
                    .positional()
                    .first()
                    .ok_or_else(|| "wait-for requires a name".to_string())?;
                if parsed.has_flag("-S") {
                    let generation = self.signal_wait(name);
                    Ok(tmux_result(
                        String::new(),
                        json!({ "name": name, "generation": generation }),
                    ))
                } else {
                    let current_generation = self.current_signal_generation(name);
                    let generation = if current_generation > 0 {
                        current_generation
                    } else {
                        self.wait_for_signal(name, 0, Duration::from_secs(30))?
                    };
                    Ok(tmux_result(
                        String::new(),
                        json!({ "name": name, "generation": generation }),
                    ))
                }
            }
            "last-pane" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &[])?;
                let target = self.tmux_resolve_window(parsed.value("-t"))?;
                self.tmux_last_pane(&target.session, target.window_index)?;
                Ok(tmux_result(
                    String::new(),
                    json!({ "session_id": target.session.id }),
                ))
            }
            "last-window" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &[])?;
                let session = self.tmux_resolve_session(parsed.value("-t"))?;
                self.tmux_last_window(&session)?;
                Ok(tmux_result(
                    String::new(),
                    json!({ "session_id": session.id }),
                ))
            }
            "next-window" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &[])?;
                let session = self.tmux_resolve_session(parsed.value("-t"))?;
                self.tmux_cycle_window(&session, 1)?;
                Ok(tmux_result(
                    String::new(),
                    json!({ "session_id": session.id }),
                ))
            }
            "previous-window" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &[])?;
                let session = self.tmux_resolve_session(parsed.value("-t"))?;
                self.tmux_cycle_window(&session, -1)?;
                Ok(tmux_result(
                    String::new(),
                    json!({ "session_id": session.id }),
                ))
            }
            "has-session" | "has" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &[])?;
                let _ = self.tmux_resolve_session(parsed.value("-t"))?;
                Ok(tmux_result(String::new(), json!({ "exists": true })))
            }
            "set-buffer" => {
                let parsed = parse_tmux_args(raw_args, &["-b"], &[])?;
                let text = parsed.positional().join(" ").trim().to_string();
                if text.is_empty() {
                    return Err("set-buffer requires text".to_string());
                }
                let name = parsed.value("-b").unwrap_or("default");
                let mut state = self.inner.state.lock().unwrap();
                state.buffers.insert(name.to_string(), text);
                Ok(tmux_result(String::new(), json!({ "buffer": name })))
            }
            "show-buffer" | "showb" => {
                let parsed = parse_tmux_args(raw_args, &["-b"], &[])?;
                let name = parsed.value("-b").unwrap_or("default");
                let state = self.inner.state.lock().unwrap();
                let buffer = state
                    .buffers
                    .get(name)
                    .ok_or_else(|| format!("buffer not found: {name}"))?
                    .clone();
                Ok(tmux_result(
                    tmux_line_output(&buffer),
                    json!({ "buffer": name }),
                ))
            }
            "save-buffer" | "saveb" => {
                let parsed = parse_tmux_args(raw_args, &["-b"], &[])?;
                let name = parsed.value("-b").unwrap_or("default");
                let buffer = {
                    let state = self.inner.state.lock().unwrap();
                    state
                        .buffers
                        .get(name)
                        .ok_or_else(|| format!("buffer not found: {name}"))?
                        .clone()
                };
                if let Some(path) = parsed.positional().first() {
                    fs::write(path, buffer.as_bytes()).map_err(|err| err.to_string())?;
                    Ok(tmux_result(
                        String::new(),
                        json!({ "buffer": name, "path": path }),
                    ))
                } else {
                    Ok(tmux_result(
                        tmux_line_output(&buffer),
                        json!({ "buffer": name }),
                    ))
                }
            }
            "list-buffers" => {
                let state = self.inner.state.lock().unwrap();
                let mut lines = Vec::with_capacity(state.buffers.len());
                for (name, buffer) in &state.buffers {
                    lines.push(format!("{name}\t{}", buffer.len()));
                }
                Ok(tmux_result(
                    lines.join("\n"),
                    json!({ "count": state.buffers.len() }),
                ))
            }
            "paste-buffer" => {
                let parsed = parse_tmux_args(raw_args, &["-b", "-t"], &[])?;
                let name = parsed.value("-b").unwrap_or("default");
                let buffer = {
                    let state = self.inner.state.lock().unwrap();
                    state
                        .buffers
                        .get(name)
                        .ok_or_else(|| format!("buffer not found: {name}"))?
                        .clone()
                };
                let target = self.tmux_resolve_pane(parsed.value("-t"))?;
                target.handle.write(buffer.into_bytes())?;
                Ok(tmux_result(
                    String::new(),
                    json!({
                        "session_id": target.session.id,
                        "pane_id": tmux_pane_display_id(&target.pane_id),
                    }),
                ))
            }
            "pipe-pane" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &[])?;
                let shell_command = parsed.positional().join(" ").trim().to_string();
                if shell_command.is_empty() {
                    return Err("pipe-pane requires a shell command".to_string());
                }
                let target = self.tmux_resolve_pane(parsed.value("-t"))?;
                self.tmux_close_pipe(&target.pane_id);
                self.tmux_open_pipe(&target.pane_id, &shell_command)?;
                Ok(tmux_result(
                    String::new(),
                    json!({
                        "pane_id": tmux_pane_display_id(&target.pane_id),
                        "status": 0,
                    }),
                ))
            }
            "find-window" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &[])?;
                let query = parsed.positional().join(" ").trim().to_string();
                let lines = self.tmux_find_windows(parsed.value("-t"), &query)?;
                Ok(tmux_result(String::new(), json!({ "count": lines.len() })))
            }
            "respawn-pane" => {
                let parsed = parse_tmux_args(raw_args, &["-t"], &["-k"])?;
                let target = self.tmux_resolve_pane(parsed.value("-t"))?;
                let command_text = if parsed.positional().is_empty() {
                    "exec ${SHELL:-/bin/sh} -l".to_string()
                } else {
                    parsed.positional().join(" ")
                };
                self.tmux_respawn_pane(
                    &target.session,
                    target.window_index,
                    target.pane_index,
                    &command_text,
                )?;
                Ok(tmux_result(
                    String::new(),
                    json!({
                        "session_id": target.session.id,
                        "pane_id": tmux_pane_display_id(&target.pane_id),
                    }),
                ))
            }
            _ => Err(format!("unsupported tmux command: {command}")),
        }
    }

    fn tmux_default_session(&self) -> Result<Arc<Session>, String> {
        self.sessions()
            .into_iter()
            .next()
            .ok_or_else(|| "no sessions available".to_string())
    }

    fn tmux_resolve_session(&self, target: Option<&str>) -> Result<Arc<Session>, String> {
        let Some(raw_target) = target.map(str::trim).filter(|value| !value.is_empty()) else {
            return self.tmux_default_session();
        };
        if let Some((session_part, _, _)) = tmux_split_target(raw_target) {
            let session_part = session_part.trim_start_matches('$');
            return self
                .find_session(session_part)
                .ok_or_else(|| format!("session not found: {session_part}"));
        }
        let lookup = raw_target.trim_start_matches('$');
        self.find_session(lookup)
            .ok_or_else(|| format!("session not found: {lookup}"))
    }

    fn tmux_resolve_window(&self, target: Option<&str>) -> Result<TmuxWindowTarget, String> {
        let Some(raw_target) = target.map(str::trim).filter(|value| !value.is_empty()) else {
            let session = self.tmux_default_session()?;
            let active_window = session.inner.lock().unwrap().active_window;
            return Ok(TmuxWindowTarget {
                session,
                window_index: active_window,
            });
        };

        if let Some(window_id) = raw_target.strip_prefix('@') {
            for session in self.sessions() {
                let window_index = {
                    let inner = session.inner.lock().unwrap();
                    inner
                        .windows
                        .iter()
                        .position(|window| window.id == window_id)
                };
                if let Some(window_index) = window_index {
                    return Ok(TmuxWindowTarget {
                        session,
                        window_index,
                    });
                }
            }
            return Err(format!("window not found: {window_id}"));
        }

        let (session, lookup) =
            if let Some((session_part, window_part, _)) = tmux_split_target(raw_target) {
                let session_part = session_part.trim_start_matches('$');
                (
                    self.find_session(session_part)
                        .ok_or_else(|| format!("session not found: {session_part}"))?,
                    window_part,
                )
            } else {
                (self.tmux_default_session()?, raw_target)
            };

        let window_index = self.tmux_window_index_in_session(&session, lookup)?;
        Ok(TmuxWindowTarget {
            session,
            window_index,
        })
    }

    fn tmux_resolve_pane(&self, target: Option<&str>) -> Result<TmuxPaneTarget, String> {
        let Some(raw_target) = target.map(str::trim).filter(|value| !value.is_empty()) else {
            let session = self.tmux_default_session()?;
            let (window_index, pane_index, pane_id, handle) = {
                let inner = session.inner.lock().unwrap();
                let window = inner
                    .windows
                    .get(inner.active_window)
                    .ok_or_else(|| "session has no windows".to_string())?;
                let pane = window
                    .panes
                    .get(window.active_pane)
                    .ok_or_else(|| "window has no panes".to_string())?;
                (
                    inner.active_window,
                    window.active_pane,
                    pane.pane_id.clone(),
                    pane.handle.clone(),
                )
            };
            return Ok(TmuxPaneTarget {
                session,
                window_index,
                pane_index,
                pane_id,
                handle,
            });
        };

        if raw_target.starts_with('@') {
            let window = self.tmux_resolve_window(Some(raw_target))?;
            return self.tmux_active_pane_target(window.session, window.window_index);
        }

        if let Some((session_part, window_part, pane_part)) = tmux_split_target(raw_target) {
            let session_part = session_part.trim_start_matches('$');
            let session = self
                .find_session(session_part)
                .ok_or_else(|| format!("session not found: {session_part}"))?;
            let window_index = self.tmux_window_index_in_session(&session, window_part)?;
            if pane_part.is_empty() {
                return self.tmux_active_pane_target(session, window_index);
            }
            return self.tmux_pane_target_in_window(session, window_index, pane_part);
        }

        if let Some((window_part, pane_part)) = raw_target.split_once('.') {
            let session = self.tmux_default_session()?;
            let window_index = self.tmux_window_index_in_session(&session, window_part)?;
            return self.tmux_pane_target_in_window(session, window_index, pane_part);
        }

        let session = self.tmux_default_session()?;
        let active_window = session.inner.lock().unwrap().active_window;
        if let Ok(target) =
            self.tmux_pane_target_in_window(session.clone(), active_window, raw_target)
        {
            return Ok(target);
        }

        if !raw_target.starts_with('%') {
            return Err(format!("pane not found: {raw_target}"));
        }
        let lookup = raw_target.trim_start_matches('%');
        for session in self.sessions() {
            let found = {
                let inner = session.inner.lock().unwrap();
                let mut found = None;
                for (window_index, window) in inner.windows.iter().enumerate() {
                    if let Some(pane_index) = window
                        .panes
                        .iter()
                        .enumerate()
                        .position(|(pane_index, pane)| tmux_pane_matches(pane_index, pane, lookup))
                    {
                        let pane = &window.panes[pane_index];
                        found = Some((
                            window_index,
                            pane_index,
                            pane.pane_id.clone(),
                            pane.handle.clone(),
                        ));
                        break;
                    }
                }
                found
            };
            if let Some((window_index, pane_index, pane_id, handle)) = found {
                return Ok(TmuxPaneTarget {
                    session,
                    window_index,
                    pane_index,
                    pane_id,
                    handle,
                });
            }
        }
        Err(format!("pane not found: {lookup}"))
    }

    fn tmux_window_index_in_session(
        &self,
        session: &Arc<Session>,
        lookup: &str,
    ) -> Result<usize, String> {
        let lookup = if lookup.is_empty() { "0" } else { lookup };
        session
            .inner
            .lock()
            .unwrap()
            .windows
            .iter()
            .enumerate()
            .position(|(index, window)| tmux_window_matches(index, window, lookup))
            .ok_or_else(|| format!("window not found: {lookup}"))
    }

    fn tmux_active_pane_target(
        &self,
        session: Arc<Session>,
        window_index: usize,
    ) -> Result<TmuxPaneTarget, String> {
        let (pane_index, pane_id, handle) = {
            let inner = session.inner.lock().unwrap();
            let window = inner
                .windows
                .get(window_index)
                .ok_or_else(|| "window not found".to_string())?;
            let pane = window
                .panes
                .get(window.active_pane)
                .ok_or_else(|| "window has no panes".to_string())?;
            (
                window.active_pane,
                pane.pane_id.clone(),
                pane.handle.clone(),
            )
        };
        Ok(TmuxPaneTarget {
            session,
            window_index,
            pane_index,
            pane_id,
            handle,
        })
    }

    fn tmux_pane_target_in_window(
        &self,
        session: Arc<Session>,
        window_index: usize,
        lookup: &str,
    ) -> Result<TmuxPaneTarget, String> {
        let (pane_index, pane_id, handle) = {
            let inner = session.inner.lock().unwrap();
            let window = inner
                .windows
                .get(window_index)
                .ok_or_else(|| "window not found".to_string())?;
            let pane_index = window
                .panes
                .iter()
                .enumerate()
                .position(|(index, pane)| tmux_pane_matches(index, pane, lookup))
                .ok_or_else(|| format!("pane not found: {lookup}"))?;
            let pane = &window.panes[pane_index];
            (pane_index, pane.pane_id.clone(), pane.handle.clone())
        };
        Ok(TmuxPaneTarget {
            session,
            window_index,
            pane_index,
            pane_id,
            handle,
        })
    }

    fn tmux_create_window(
        &self,
        session: &Arc<Session>,
        name: Option<String>,
        command: &str,
        focus: bool,
    ) -> Result<(usize, usize), String> {
        let (cols, rows) = tmux_size_or_default(session.effective_size());
        let (window_id, pane_id) = {
            let mut state = self.inner.state.lock().unwrap();
            let window_id = format!("win-{}", state.next_window_id);
            state.next_window_id += 1;
            let pane_id = format!("pane-{}", state.next_pane_id);
            state.next_pane_id += 1;
            (window_id, pane_id)
        };

        let event_daemon = self.clone();
        let pane_events: EventCallback =
            Arc::new(move |event| event_daemon.handle_pane_event(event));
        let handle = PaneHandle::spawn(&session.id, &pane_id, command, cols, rows, pane_events)?;

        let window_index = {
            let mut inner = session.inner.lock().unwrap();
            let window_index = inner.windows.len();
            inner.windows.push(Window {
                id: window_id.clone(),
                name: name.unwrap_or_else(|| format!("window-{}", window_index)),
                panes: vec![PaneSlot {
                    pane_id: pane_id.clone(),
                    command: command.to_string(),
                    handle,
                }],
                active_pane: 0,
                last_pane: None,
            });
            if focus || window_index == 0 {
                if window_index > 0 {
                    inner.last_window = Some(inner.active_window);
                }
                inner.active_window = window_index;
            }
            window_index
        };

        let mut state = self.inner.state.lock().unwrap();
        self.emit_event_locked(
            &mut state,
            "window.open",
            json!({ "session_id": session.id, "window_id": window_id }),
        );
        self.emit_event_locked(
            &mut state,
            "pane.open",
            json!({ "session_id": session.id, "pane_id": pane_id }),
        );
        self.inner.state_cv.notify_all();
        Ok((window_index, 0))
    }

    fn tmux_create_pane(
        &self,
        session: &Arc<Session>,
        window_index: usize,
        command: &str,
        focus: bool,
    ) -> Result<usize, String> {
        let (cols, rows) = tmux_size_or_default(session.effective_size());
        let pane_id = {
            let mut state = self.inner.state.lock().unwrap();
            let pane_id = format!("pane-{}", state.next_pane_id);
            state.next_pane_id += 1;
            pane_id
        };

        let event_daemon = self.clone();
        let pane_events: EventCallback =
            Arc::new(move |event| event_daemon.handle_pane_event(event));
        let handle = PaneHandle::spawn(&session.id, &pane_id, command, cols, rows, pane_events)?;

        let pane_index = {
            let mut inner = session.inner.lock().unwrap();
            let window = inner
                .windows
                .get_mut(window_index)
                .ok_or_else(|| "window not found".to_string())?;
            let pane_index = window.panes.len();
            window.panes.push(PaneSlot {
                pane_id: pane_id.clone(),
                command: command.to_string(),
                handle,
            });
            if focus {
                window.last_pane = Some(window.active_pane);
                window.active_pane = pane_index;
            }
            pane_index
        };

        let mut state = self.inner.state.lock().unwrap();
        self.emit_event_locked(
            &mut state,
            "pane.open",
            json!({ "session_id": session.id, "pane_id": pane_id }),
        );
        self.inner.state_cv.notify_all();
        Ok(pane_index)
    }

    fn tmux_select_window(
        &self,
        session: &Arc<Session>,
        window_index: usize,
    ) -> Result<(), String> {
        let mut inner = session.inner.lock().unwrap();
        if window_index >= inner.windows.len() {
            return Err("window not found".to_string());
        }
        if inner.active_window != window_index {
            inner.last_window = Some(inner.active_window);
            inner.active_window = window_index;
        }
        Ok(())
    }

    fn tmux_select_pane(
        &self,
        session: &Arc<Session>,
        window_index: usize,
        pane_index: usize,
    ) -> Result<(), String> {
        let mut inner = session.inner.lock().unwrap();
        let window = inner
            .windows
            .get_mut(window_index)
            .ok_or_else(|| "window not found".to_string())?;
        if pane_index >= window.panes.len() {
            return Err("pane not found".to_string());
        }
        if window.active_pane != pane_index {
            window.last_pane = Some(window.active_pane);
            window.active_pane = pane_index;
        }
        Ok(())
    }

    fn tmux_kill_window(&self, session: &Arc<Session>, window_index: usize) -> Result<(), String> {
        let (handles, pane_ids, close_events) = {
            let mut inner = session.inner.lock().unwrap();
            if window_index >= inner.windows.len() {
                return Err("window not found".to_string());
            }
            let window = inner.windows.remove(window_index);
            let window_id = window.id.clone();
            let pane_ids = window
                .panes
                .iter()
                .map(|pane| pane.pane_id.clone())
                .collect::<Vec<_>>();
            let mut close_events = Vec::with_capacity(window.panes.len() + 1);
            for pane in &window.panes {
                close_events.push((
                    "pane.close",
                    json!({ "session_id": session.id, "pane_id": pane.pane_id }),
                ));
            }
            close_events.push((
                "window.close",
                json!({ "session_id": session.id, "window_id": window_id }),
            ));
            if inner.windows.is_empty() {
                inner.active_window = 0;
                inner.last_window = None;
            } else {
                inner.active_window =
                    rebase_index(inner.active_window, window_index, inner.windows.len());
                inner.last_window =
                    rebase_optional_index(inner.last_window, window_index, inner.windows.len());
            }
            (
                window
                    .panes
                    .into_iter()
                    .map(|pane| pane.handle)
                    .collect::<Vec<_>>(),
                pane_ids,
                close_events,
            )
        };
        {
            let mut state = self.inner.state.lock().unwrap();
            for (kind, payload) in close_events {
                self.emit_event_locked(&mut state, kind, payload);
            }
            self.inner.state_cv.notify_all();
        }
        for pane_id in pane_ids {
            self.tmux_close_pipe(&pane_id);
        }
        for handle in handles {
            handle.close();
        }
        if session.inner.lock().unwrap().windows.is_empty() {
            let _ = self.close_session(&session.id);
        }
        Ok(())
    }

    fn tmux_kill_pane(
        &self,
        session: &Arc<Session>,
        window_index: usize,
        pane_index: usize,
    ) -> Result<(), String> {
        let (handle, pane_id, empty_after_remove) = {
            let mut inner = session.inner.lock().unwrap();
            let window = inner
                .windows
                .get_mut(window_index)
                .ok_or_else(|| "window not found".to_string())?;
            if pane_index >= window.panes.len() {
                return Err("pane not found".to_string());
            }
            let pane = window.panes.remove(pane_index);
            if window.panes.is_empty() {
                (pane.handle, pane.pane_id, true)
            } else {
                window.active_pane =
                    rebase_index(window.active_pane, pane_index, window.panes.len());
                window.last_pane =
                    rebase_optional_index(window.last_pane, pane_index, window.panes.len());
                (pane.handle, pane.pane_id, false)
            }
        };
        {
            let mut state = self.inner.state.lock().unwrap();
            self.emit_event_locked(
                &mut state,
                "pane.close",
                json!({ "session_id": session.id, "pane_id": pane_id }),
            );
            self.inner.state_cv.notify_all();
        }
        self.tmux_close_pipe(&pane_id);
        handle.close();
        if empty_after_remove {
            self.tmux_kill_window(session, window_index)?;
        }
        Ok(())
    }

    fn tmux_last_window(&self, session: &Arc<Session>) -> Result<(), String> {
        let mut inner = session.inner.lock().unwrap();
        if let Some(last_window) = inner
            .last_window
            .filter(|value| *value < inner.windows.len())
        {
            let current = inner.active_window;
            inner.active_window = last_window;
            inner.last_window = Some(current);
        }
        Ok(())
    }

    fn tmux_cycle_window(&self, session: &Arc<Session>, delta: isize) -> Result<(), String> {
        let mut inner = session.inner.lock().unwrap();
        if inner.windows.is_empty() {
            return Err("session has no windows".to_string());
        }
        let len = inner.windows.len() as isize;
        inner.last_window = Some(inner.active_window);
        inner.active_window = ((inner.active_window as isize + delta).rem_euclid(len)) as usize;
        Ok(())
    }

    fn tmux_last_pane(&self, session: &Arc<Session>, window_index: usize) -> Result<(), String> {
        let mut inner = session.inner.lock().unwrap();
        let window = inner
            .windows
            .get_mut(window_index)
            .ok_or_else(|| "window not found".to_string())?;
        if let Some(last_pane) = window.last_pane.filter(|value| *value < window.panes.len()) {
            let current = window.active_pane;
            window.active_pane = last_pane;
            window.last_pane = Some(current);
        }
        Ok(())
    }

    fn tmux_respawn_pane(
        &self,
        session: &Arc<Session>,
        window_index: usize,
        pane_index: usize,
        command: &str,
    ) -> Result<(), String> {
        let pane_id = self.tmux_pane_id(session, window_index, pane_index)?;
        let (cols, rows) = tmux_size_or_default(session.effective_size());
        let event_daemon = self.clone();
        let pane_events: EventCallback =
            Arc::new(move |event| event_daemon.handle_pane_event(event));
        let handle = PaneHandle::spawn(&session.id, &pane_id, command, cols, rows, pane_events)?;
        self.tmux_close_pipe(&pane_id);
        let old_handle = {
            let mut inner = session.inner.lock().unwrap();
            let window = inner
                .windows
                .get_mut(window_index)
                .ok_or_else(|| "window not found".to_string())?;
            let pane = window
                .panes
                .get_mut(pane_index)
                .ok_or_else(|| "pane not found".to_string())?;
            pane.command = command.to_string();
            std::mem::replace(&mut pane.handle, handle)
        };
        old_handle.close();
        Ok(())
    }

    fn tmux_find_windows(
        &self,
        target_session: Option<&str>,
        query: &str,
    ) -> Result<Vec<String>, String> {
        let sessions = if let Some(target_session) = target_session {
            vec![self.tmux_resolve_session(Some(target_session))?]
        } else {
            self.sessions()
        };

        let mut lines = Vec::new();
        for session in sessions {
            let inner = session.inner.lock().unwrap();
            for window in &inner.windows {
                let mut matched = query.is_empty() || window.name.contains(query);
                if !matched {
                    for pane in &window.panes {
                        if let Ok(capture) = pane.handle.capture(true) {
                            let content =
                                join_history(&capture.capture.history, &capture.capture.visible);
                            if content.contains(query) {
                                matched = true;
                                break;
                            }
                        }
                    }
                }
                if matched {
                    lines.push(format!(
                        "{} {}",
                        tmux_window_display_id(&window.id),
                        window.name
                    ));
                }
            }
        }
        Ok(lines)
    }

    fn tmux_open_pipe(&self, pane_id: &str, shell_command: &str) -> Result<(), String> {
        let mut child = Command::new("/bin/sh")
            .arg("-lc")
            .arg(shell_command)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|err| err.to_string())?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "pipe-pane child missing stdin".to_string())?;
        thread::spawn(move || {
            let _ = child.wait();
        });

        let mut state = self.inner.state.lock().unwrap();
        state
            .pane_pipes
            .insert(pane_id.to_string(), Arc::new(Mutex::new(stdin)));
        Ok(())
    }

    fn tmux_close_pipe(&self, pane_id: &str) {
        let mut state = self.inner.state.lock().unwrap();
        state.pane_pipes.remove(pane_id);
    }

    fn tmux_window_id(
        &self,
        session: &Arc<Session>,
        window_index: usize,
    ) -> Result<String, String> {
        session
            .inner
            .lock()
            .unwrap()
            .windows
            .get(window_index)
            .map(|window| window.id.clone())
            .ok_or_else(|| "window not found".to_string())
    }

    fn tmux_pane_id(
        &self,
        session: &Arc<Session>,
        window_index: usize,
        pane_index: usize,
    ) -> Result<String, String> {
        session
            .inner
            .lock()
            .unwrap()
            .windows
            .get(window_index)
            .and_then(|window| window.panes.get(pane_index))
            .map(|pane| pane.pane_id.clone())
            .ok_or_else(|| "pane not found".to_string())
    }

    fn tmux_format_context(
        &self,
        session: &Arc<Session>,
        window_index: usize,
        pane_index: Option<usize>,
    ) -> Result<BTreeMap<String, String>, String> {
        let inner = session.inner.lock().unwrap();
        let window = inner
            .windows
            .get(window_index)
            .ok_or_else(|| "window not found".to_string())?;
        let mut context = BTreeMap::new();
        context.insert("session_name".to_string(), session.id.clone());
        context.insert(
            "session_id".to_string(),
            tmux_session_display_id(&session.id),
        );
        context.insert("window_id".to_string(), tmux_window_display_id(&window.id));
        context.insert("window_name".to_string(), window.name.clone());
        context.insert("window_index".to_string(), window_index.to_string());
        context.insert(
            "window_active".to_string(),
            if inner.active_window == window_index {
                "1"
            } else {
                "0"
            }
            .to_string(),
        );
        if let Some(pane_index) = pane_index {
            let pane = window
                .panes
                .get(pane_index)
                .ok_or_else(|| "pane not found".to_string())?;
            let state = pane.handle.shared.state.lock().unwrap();
            context.insert("pane_id".to_string(), tmux_pane_display_id(&pane.pane_id));
            context.insert("pane_index".to_string(), pane_index.to_string());
            context.insert(
                "pane_active".to_string(),
                if window.active_pane == pane_index {
                    "1"
                } else {
                    "0"
                }
                .to_string(),
            );
            context.insert("pane_title".to_string(), state.title.clone());
            context.insert("pane_current_path".to_string(), state.pwd.clone());
            context.insert(
                "pane_current_command".to_string(),
                tmux_command_name(&pane.command),
            );
        }
        Ok(context)
    }

    fn session_close_events(&self, session: &Arc<Session>) -> Vec<(&'static str, Value)> {
        let inner = session.inner.lock().unwrap();
        let mut events = Vec::new();
        for window in &inner.windows {
            for pane in &window.panes {
                events.push((
                    "pane.close",
                    json!({ "session_id": session.id, "pane_id": pane.pane_id }),
                ));
            }
            events.push((
                "window.close",
                json!({ "session_id": session.id, "window_id": window.id }),
            ));
        }
        events
    }
}

#[derive(Debug)]
enum OpenTerminalError {
    AlreadyExists,
    Other(String),
}

struct TmuxWindowTarget {
    session: Arc<Session>,
    window_index: usize,
}

struct TmuxPaneTarget {
    session: Arc<Session>,
    window_index: usize,
    pane_index: usize,
    pane_id: String,
    handle: Arc<PaneHandle>,
}

#[derive(Default)]
struct ParsedTmuxArgs {
    flags: BTreeSet<String>,
    values: BTreeMap<String, String>,
    positional: Vec<String>,
}

impl ParsedTmuxArgs {
    fn has_flag(&self, flag: &str) -> bool {
        self.flags.contains(flag)
    }

    fn value(&self, flag: &str) -> Option<&str> {
        self.values.get(flag).map(String::as_str)
    }

    fn positional(&self) -> &[String] {
        &self.positional
    }
}

fn parse_tmux_args(
    args: &[String],
    value_flags: &[&str],
    bool_flags: &[&str],
) -> Result<ParsedTmuxArgs, String> {
    let value_flags: BTreeSet<&str> = value_flags.iter().copied().collect();
    let bool_flags: BTreeSet<&str> = bool_flags.iter().copied().collect();
    let mut parsed = ParsedTmuxArgs::default();
    let mut idx = 0;
    while idx < args.len() {
        let arg = args[idx].as_str();
        if arg == "--" {
            parsed.positional.extend(args[idx + 1..].iter().cloned());
            break;
        }
        if value_flags.contains(arg) {
            idx += 1;
            if idx >= args.len() {
                return Err(format!("{arg} requires a value"));
            }
            parsed.values.insert(arg.to_string(), args[idx].clone());
            idx += 1;
            continue;
        }
        if bool_flags.contains(arg) {
            parsed.flags.insert(arg.to_string());
            idx += 1;
            continue;
        }
        parsed.positional.extend(args[idx..].iter().cloned());
        break;
    }
    Ok(parsed)
}

fn tmux_open_terminal_error(err: OpenTerminalError) -> String {
    match err {
        OpenTerminalError::AlreadyExists => "session already exists".to_string(),
        OpenTerminalError::Other(err) => err,
    }
}

fn tmux_split_target(raw: &str) -> Option<(&str, &str, &str)> {
    let (session, rest) = raw.split_once(':')?;
    let (window, pane) = rest.split_once('.').unwrap_or((rest, ""));
    Some((session, window, pane))
}

fn tmux_session_display_id(session_id: &str) -> String {
    format!("${session_id}")
}

fn tmux_window_display_id(window_id: &str) -> String {
    format!("@{window_id}")
}

fn tmux_pane_display_id(pane_id: &str) -> String {
    format!("%{pane_id}")
}

fn tmux_window_matches(index: usize, window: &Window, lookup: &str) -> bool {
    window.id == lookup || window.name == lookup || lookup.parse::<usize>().ok() == Some(index)
}

fn tmux_pane_matches(index: usize, pane: &PaneSlot, lookup: &str) -> bool {
    pane.pane_id == lookup
        || tmux_command_name(&pane.command) == lookup
        || lookup.parse::<usize>().ok() == Some(index)
}

fn tmux_size_or_default((cols, rows): (u16, u16)) -> (u16, u16) {
    let cols = if cols == 0 { 80 } else { cols.max(2) };
    let rows = if rows == 0 { 24 } else { rows.max(1) };
    (cols, rows)
}

fn tmux_shell_command(tokens: &[String], cwd: Option<&str>) -> String {
    let base = if tokens.is_empty() {
        "exec ${SHELL:-/bin/sh} -l".to_string()
    } else {
        tokens.join(" ")
    };
    match cwd {
        Some(cwd) if !cwd.trim().is_empty() => format!("cd {} && {base}", tmux_shell_quote(cwd)),
        _ => base,
    }
}

fn tmux_shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

fn tmux_command_name(command: &str) -> String {
    command
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .rsplit('/')
        .next()
        .unwrap_or_default()
        .to_string()
}

fn tmux_send_keys_bytes(tokens: &[String], literal: bool) -> Vec<u8> {
    let mut out = Vec::new();
    for token in tokens {
        if literal {
            out.extend_from_slice(token.as_bytes());
            continue;
        }
        match token.as_str() {
            "Enter" | "C-m" => out.push(b'\r'),
            "Tab" => out.push(b'\t'),
            "Space" => out.push(b' '),
            "Escape" | "Esc" => out.push(0x1b),
            "BSpace" | "Backspace" => out.push(0x7f),
            "C-c" => out.push(0x03),
            "C-d" => out.push(0x04),
            other => out.extend_from_slice(other.as_bytes()),
        }
    }
    out
}

fn tmux_capture_text(
    capture: &crate::capture::TerminalCapture,
    include_history: bool,
    start: Option<&str>,
    end: Option<&str>,
) -> String {
    let source = if include_history {
        join_history(&capture.history, &capture.visible)
    } else {
        capture.visible.clone()
    };
    let mut lines: Vec<&str> = source.lines().collect();
    if source.ends_with('\n') {
        lines.push("");
    }
    if lines.is_empty() {
        return String::new();
    }
    let start_index = tmux_line_index(start, lines.len(), 0);
    let end_index = tmux_line_index(end, lines.len(), lines.len().saturating_sub(1));
    if start_index > end_index || start_index >= lines.len() {
        return String::new();
    }
    lines[start_index..=end_index.min(lines.len() - 1)].join("\n")
}

fn tmux_line_index(value: Option<&str>, line_count: usize, default: usize) -> usize {
    let Some(value) = value else {
        return default;
    };
    if value == "-" {
        return if default == 0 {
            0
        } else {
            line_count.saturating_sub(1)
        };
    }
    match value.parse::<i64>() {
        Ok(number) if number < 0 => line_count.saturating_sub(number.unsigned_abs() as usize),
        Ok(number) => number as usize,
        Err(_) => default,
    }
}

fn tmux_render_format(
    format: Option<&str>,
    context: &BTreeMap<String, String>,
    fallback: &str,
) -> String {
    let Some(format) = format.filter(|value| !value.is_empty()) else {
        return fallback.to_string();
    };
    let mut rendered = format.to_string();
    for (key, value) in context {
        rendered = rendered.replace(&format!("#{{{key}}}"), value);
    }
    rendered
}

fn tmux_result(stdout: String, extra: Value) -> Value {
    let mut result = extra.as_object().cloned().unwrap_or_default();
    result.insert("stdout".to_string(), json!(stdout));
    Value::Object(result)
}

fn tmux_line_output(value: &str) -> String {
    if value.is_empty() {
        String::new()
    } else if value.ends_with('\n') {
        value.to_string()
    } else {
        format!("{value}\n")
    }
}

#[derive(Default)]
struct DirectAuthorizer {
    capabilities: BTreeSet<String>,
    claimed_session_id: String,
    claimed_attachment_id: String,
    active_session_id: String,
    active_attachment_id: String,
    grant: RequestGrant,
    used: bool,
}

#[derive(Default, PartialEq, Eq)]
enum RequestGrant {
    #[default]
    None,
    Open,
    Attach,
}

impl DirectAuthorizer {
    fn new(claims: TicketClaims) -> Self {
        Self {
            capabilities: claims.capabilities.into_iter().collect(),
            claimed_session_id: claims.session_id,
            claimed_attachment_id: claims.attachment_id,
            active_session_id: String::new(),
            active_attachment_id: String::new(),
            grant: RequestGrant::None,
            used: false,
        }
    }

    fn handle(&mut self, daemon: &Daemon, request: &Request) -> Response {
        if let Some(response) = self.authorize(request) {
            return with_id(response, request.id.clone());
        }
        let response = daemon.handle_request(request);
        if response.ok {
            self.observe(request, &response);
        }
        response
    }

    fn authorize(&self, request: &Request) -> Option<Response> {
        match request.method.as_str() {
            "hello" | "ping" => None,
            "terminal.open" => {
                if !self.capabilities.contains("session.open") {
                    Some(rpc_error(
                        None,
                        "unauthorized",
                        "ticket missing session.open capability",
                    ))
                } else if self.used {
                    Some(rpc_error(
                        None,
                        "unauthorized",
                        "ticket is already bound to a terminal session",
                    ))
                } else {
                    None
                }
            }
            "session.attach" => {
                if !self.capabilities.contains("session.attach") {
                    return Some(rpc_error(
                        None,
                        "unauthorized",
                        "ticket missing session.attach capability",
                    ));
                }
                let session_id = get_string(&request.params, "session_id").unwrap_or_default();
                let attachment_id =
                    get_string(&request.params, "attachment_id").unwrap_or_default();
                if session_id.is_empty() || attachment_id.is_empty() {
                    return None;
                }
                let Some((allowed_session, allowed_attachment)) = self.allowed_scope() else {
                    return Some(rpc_error(
                        None,
                        "unauthorized",
                        "direct session.attach tickets require session and attachment scope",
                    ));
                };
                if allowed_session != session_id || allowed_attachment != attachment_id {
                    Some(rpc_error(
                        None,
                        "unauthorized",
                        "request exceeds direct ticket session scope",
                    ))
                } else {
                    None
                }
            }
            "terminal.read" | "terminal.write" | "session.status" | "session.close" => {
                self.authorize_established(request, false)
            }
            "session.resize" | "session.detach" => self.authorize_established(request, true),
            _ => Some(rpc_error(
                None,
                "unauthorized",
                "request is not allowed for this direct ticket",
            )),
        }
    }

    fn authorize_established(&self, request: &Request, needs_attachment: bool) -> Option<Response> {
        let session_id = get_string(&request.params, "session_id").unwrap_or_default();
        if session_id.is_empty() {
            return None;
        }
        if self.grant == RequestGrant::None || self.active_session_id.is_empty() {
            return Some(rpc_error(
                None,
                "unauthorized",
                "request requires an opened or attached terminal session",
            ));
        }
        if session_id != self.active_session_id {
            return Some(rpc_error(
                None,
                "unauthorized",
                "request exceeds direct ticket session scope",
            ));
        }
        if needs_attachment {
            let attachment_id = get_string(&request.params, "attachment_id").unwrap_or_default();
            if attachment_id.is_empty() {
                return None;
            }
            if attachment_id != self.active_attachment_id {
                return Some(rpc_error(
                    None,
                    "unauthorized",
                    "request exceeds direct ticket attachment scope",
                ));
            }
        }
        None
    }

    fn observe(&mut self, request: &Request, response: &Response) {
        match request.method.as_str() {
            "terminal.open" => {
                if let Some((session_id, attachment_id)) = response_scope(response.result.as_ref())
                {
                    self.active_session_id = session_id;
                    self.active_attachment_id = attachment_id;
                    self.grant = RequestGrant::Open;
                    self.used = true;
                }
            }
            "session.attach" => {
                let session_id = get_string(&request.params, "session_id").unwrap_or_default();
                let attachment_id =
                    get_string(&request.params, "attachment_id").unwrap_or_default();
                if !session_id.is_empty() && !attachment_id.is_empty() {
                    self.active_session_id = session_id.to_string();
                    self.active_attachment_id = attachment_id.to_string();
                    self.grant = RequestGrant::Attach;
                    self.used = true;
                }
            }
            "session.close" | "session.detach" => {
                self.grant = RequestGrant::None;
                self.active_session_id.clear();
                self.active_attachment_id.clear();
            }
            _ => {}
        }
    }

    fn allowed_scope(&self) -> Option<(&str, &str)> {
        if self.grant != RequestGrant::None
            && !self.active_session_id.is_empty()
            && !self.active_attachment_id.is_empty()
        {
            Some((&self.active_session_id, &self.active_attachment_id))
        } else if !self.claimed_session_id.is_empty() && !self.claimed_attachment_id.is_empty() {
            Some((&self.claimed_session_id, &self.claimed_attachment_id))
        } else {
            None
        }
    }
}

fn with_id(mut response: Response, id: Option<Value>) -> Response {
    response.id = id;
    response
}

fn response_scope(result: Option<&Value>) -> Option<(String, String)> {
    let result = result?;
    let session_id = result.get("session_id")?.as_str()?.to_string();
    let attachment_id = result.get("attachment_id")?.as_str()?.to_string();
    Some((session_id, attachment_id))
}

fn trim_crlf(frame: &[u8]) -> &[u8] {
    let mut end = frame.len();
    while end > 0 && (frame[end - 1] == b'\n' || frame[end - 1] == b'\r') {
        end -= 1;
    }
    &frame[..end]
}

fn collect_panes(session: &Arc<Session>) -> Vec<Arc<PaneHandle>> {
    let inner = session.inner.lock().unwrap();
    inner
        .windows
        .iter()
        .flat_map(|window| window.panes.iter().map(|pane| Arc::clone(&pane.handle)))
        .collect()
}

fn collect_events(
    state: &CoreState,
    cursor: u64,
    filters: &BTreeSet<String>,
    session_id: Option<&str>,
    pane_id: Option<&str>,
) -> Vec<Value> {
    let start = cursor.max(state.event_base_cursor);
    let offset = start.saturating_sub(state.event_base_cursor) as usize;
    state
        .events
        .iter()
        .skip(offset)
        .filter(|event| {
            let kind = event
                .get("kind")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let session_matches = session_id
                .map(|value| event.get("session_id").and_then(Value::as_str) == Some(value))
                .unwrap_or(true);
            let pane_matches = pane_id
                .map(|value| event.get("pane_id").and_then(Value::as_str) == Some(value))
                .unwrap_or(true);
            (filters.is_empty() || filters.contains(kind)) && session_matches && pane_matches
        })
        .cloned()
        .collect()
}

fn snapshot_value(
    snapshot: SessionSnapshot,
    attachment_id: Option<String>,
    offset: Option<u64>,
) -> Value {
    let mut value = serde_json::to_value(snapshot).unwrap_or_else(|_| json!({}));
    if let Some(object) = value.as_object_mut() {
        if let Some(attachment_id) = attachment_id {
            object.insert("attachment_id".to_string(), json!(attachment_id));
        }
        if let Some(offset) = offset {
            object.insert("offset".to_string(), json!(offset));
        }
    }
    value
}

fn get_string<'a>(params: &'a Value, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str)
}

fn get_bool(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(Value::as_bool)
}

fn get_non_negative_i64(params: &Value, key: &str) -> Option<i64> {
    match params.get(key) {
        Some(Value::Number(value)) => value.as_i64().filter(|value| *value >= 0),
        Some(Value::String(value)) => value.parse::<i64>().ok().filter(|value| *value >= 0),
        _ => None,
    }
}

fn get_non_negative_u64(params: &Value, key: &str) -> Option<u64> {
    get_non_negative_i64(params, key).map(|value| value as u64)
}

fn get_positive_u16(params: &Value, key: &str) -> Option<u16> {
    get_non_negative_i64(params, key)
        .filter(|value| *value > 0 && *value <= u16::MAX as i64)
        .map(|value| value as u16)
}

fn get_positive_usize(params: &Value, key: &str) -> Option<usize> {
    get_non_negative_i64(params, key)
        .filter(|value| *value > 0)
        .map(|value| value as usize)
}

fn get_filters(params: &Value) -> BTreeSet<String> {
    let filter_value = params.get("filters").or_else(|| params.get("filter"));
    match filter_value {
        Some(Value::String(value)) => value
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
            .collect(),
        Some(Value::Array(values)) => values
            .iter()
            .filter_map(Value::as_str)
            .map(ToString::to_string)
            .collect(),
        _ => BTreeSet::new(),
    }
}

fn join_history(history: &str, visible: &str) -> String {
    match (history.is_empty(), visible.is_empty()) {
        (true, true) => String::new(),
        (false, true) => history.to_string(),
        (true, false) => visible.to_string(),
        (false, false) => format!("{history}\n{visible}"),
    }
}

fn rebase_index(index: usize, removed: usize, len_after_remove: usize) -> usize {
    if len_after_remove == 0 {
        return 0;
    }
    if index > removed {
        index - 1
    } else if index >= len_after_remove {
        len_after_remove - 1
    } else {
        index
    }
}

fn rebase_optional_index(
    index: Option<usize>,
    removed: usize,
    len_after_remove: usize,
) -> Option<usize> {
    let index = index?;
    if len_after_remove == 0 || index == removed {
        return None;
    }
    Some(rebase_index(index, removed, len_after_remove))
}

fn allocate_generated_session_id(state: &mut CoreState) -> String {
    loop {
        let value = format!("sess-{}", state.next_session_id);
        state.next_session_id += 1;
        if !state.sessions.contains_key(&value) {
            return value;
        }
    }
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis() as u64)
        .unwrap_or_default()
}

fn unix_now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs() as i64)
        .unwrap_or_default()
}

fn load_certs(path: &str) -> Result<Vec<CertificateDer<'static>>, String> {
    let data = fs::read(path).map_err(|err| err.to_string())?;
    let mut reader = BufReader::new(data.as_slice());
    rustls_pemfile::certs(&mut reader)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|err| err.to_string())
}

fn load_key(path: &str) -> Result<PrivateKeyDer<'static>, String> {
    let data = fs::read(path).map_err(|err| err.to_string())?;
    let mut reader = BufReader::new(data.as_slice());
    rustls_pemfile::private_key(&mut reader)
        .map_err(|err| err.to_string())?
        .ok_or_else(|| "missing private key".to_string())
}

const MAX_HTTP_REQUEST_BYTES: usize = 8 * 1024;
const WEBSOCKET_MAGIC: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

impl Daemon {
    fn serve_websocket_stream<S: Read + Write>(
        &self,
        stream: S,
        secret: &str,
    ) -> Result<(), String> {
        let mut reader = BufReader::new(stream);
        let request = read_http_request(&mut reader)?;
        if !is_websocket_upgrade(&request) {
            return Err("missing websocket upgrade".to_string());
        }
        let ws_key = header_value(&request, "sec-websocket-key")
            .ok_or_else(|| "missing websocket key".to_string())?;
        write_websocket_upgrade(reader.get_mut(), ws_key)?;

        let Some(auth_message) = read_ws_text_message(&mut reader)? else {
            return Ok(());
        };
        if !websocket_secret_matches(&auth_message, secret) {
            write_ws_json_value(
                reader.get_mut(),
                &json!({
                    "ok": false,
                    "error": {
                        "code": "unauthorized",
                        "message": "invalid secret",
                    }
                }),
            )?;
            return Ok(());
        }
        write_ws_json_value(
            reader.get_mut(),
            &json!({
                "ok": true,
                "result": {
                    "authenticated": true,
                }
            }),
        )?;

        loop {
            let Some(message) = read_ws_text_message(&mut reader)? else {
                return Ok(());
            };
            if message.trim().is_empty() {
                continue;
            }
            let response = self.parse_and_dispatch(message.as_bytes(), None);
            write_ws_response(reader.get_mut(), &response)?;
        }
    }
}

fn read_http_request<S: Read>(reader: &mut BufReader<S>) -> Result<String, String> {
    let mut request = String::new();
    loop {
        let mut line = String::new();
        let read = reader.read_line(&mut line).map_err(|err| err.to_string())?;
        if read == 0 {
            return Err("connection closed".to_string());
        }
        if request.len() + line.len() > MAX_HTTP_REQUEST_BYTES {
            return Err("websocket HTTP request too large".to_string());
        }
        request.push_str(&line);
        if line == "\r\n" || line == "\n" {
            return Ok(request);
        }
    }
}

fn is_websocket_upgrade(request: &str) -> bool {
    header_value(request, "upgrade")
        .map(|value| value.eq_ignore_ascii_case("websocket"))
        .unwrap_or(false)
}

fn header_value<'a>(request: &'a str, name: &str) -> Option<&'a str> {
    request
        .split("\r\n")
        .filter_map(|line| line.split_once(':'))
        .find_map(|(key, value)| {
            key.trim()
                .eq_ignore_ascii_case(name)
                .then_some(value.trim())
        })
}

fn write_websocket_upgrade<S: Write>(stream: &mut S, ws_key: &str) -> Result<(), String> {
    let mut hasher = Sha1::new();
    hasher.update(ws_key.as_bytes());
    hasher.update(WEBSOCKET_MAGIC.as_bytes());
    let accept = base64::engine::general_purpose::STANDARD.encode(hasher.finalize());
    stream
        .write_all(
            format!(
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
            )
            .as_bytes(),
        )
        .map_err(|err| err.to_string())?;
    stream.flush().map_err(|err| err.to_string())
}

fn websocket_secret_matches(payload: &str, secret: &str) -> bool {
    serde_json::from_str::<Value>(payload)
        .ok()
        .and_then(|value| {
            value
                .get("secret")
                .and_then(Value::as_str)
                .map(|candidate| candidate == secret)
        })
        .unwrap_or(false)
}

fn read_ws_text_message<S: Read + Write>(
    reader: &mut BufReader<S>,
) -> Result<Option<String>, String> {
    loop {
        let mut header = [0u8; 2];
        match reader.read_exact(&mut header) {
            Ok(()) => {}
            Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(err) => return Err(err.to_string()),
        }

        let opcode = header[0] & 0x0F;
        let masked = (header[1] & 0x80) != 0;
        let payload = read_ws_payload(reader, header[1] & 0x7F, masked)?;

        match opcode {
            0x08 => return Ok(None),
            0x09 => {
                write_ws_frame(reader.get_mut(), 0x0A, &payload)?;
            }
            0x01 => {
                let text = String::from_utf8(payload).map_err(|err| err.to_string())?;
                return Ok(Some(text));
            }
            _ => {}
        }
    }
}

fn read_ws_payload<S: Read + Write>(
    reader: &mut BufReader<S>,
    len_byte: u8,
    masked: bool,
) -> Result<Vec<u8>, String> {
    let mut payload_len = len_byte as u64;
    if len_byte == 126 {
        let mut extended = [0u8; 2];
        reader
            .read_exact(&mut extended)
            .map_err(|err| err.to_string())?;
        payload_len = u16::from_be_bytes(extended) as u64;
    } else if len_byte == 127 {
        let mut extended = [0u8; 8];
        reader
            .read_exact(&mut extended)
            .map_err(|err| err.to_string())?;
        payload_len = u64::from_be_bytes(extended);
    }
    if payload_len > crate::rpc::MAX_FRAME_BYTES as u64 {
        return Err("websocket frame exceeds maximum size".to_string());
    }

    let mut mask_key = [0u8; 4];
    if masked {
        reader
            .read_exact(&mut mask_key)
            .map_err(|err| err.to_string())?;
    }

    let mut payload = vec![0u8; payload_len as usize];
    if !payload.is_empty() {
        reader
            .read_exact(&mut payload)
            .map_err(|err| err.to_string())?;
    }
    if masked {
        for (index, byte) in payload.iter_mut().enumerate() {
            *byte ^= mask_key[index % mask_key.len()];
        }
    }

    Ok(payload)
}

fn write_ws_json_value<S: Write>(stream: &mut S, value: &Value) -> Result<(), String> {
    let payload = serde_json::to_vec(value).map_err(|err| err.to_string())?;
    write_ws_frame(stream, 0x01, &payload)
}

fn write_ws_response<S: Write>(stream: &mut S, response: &Response) -> Result<(), String> {
    let payload = serde_json::to_vec(response).map_err(|err| err.to_string())?;
    write_ws_frame(stream, 0x01, &payload)
}

fn write_ws_frame<S: Write>(stream: &mut S, opcode: u8, data: &[u8]) -> Result<(), String> {
    let mut header = [0u8; 10];
    header[0] = 0x80 | opcode;
    let header_len = if data.len() <= 125 {
        header[1] = data.len() as u8;
        2
    } else if data.len() <= u16::MAX as usize {
        header[1] = 126;
        header[2..4].copy_from_slice(&(data.len() as u16).to_be_bytes());
        4
    } else {
        header[1] = 127;
        header[2..10].copy_from_slice(&(data.len() as u64).to_be_bytes());
        10
    };
    stream
        .write_all(&header[..header_len])
        .map_err(|err| err.to_string())?;
    if !data.is_empty() {
        stream.write_all(data).map_err(|err| err.to_string())?;
    }
    stream.flush().map_err(|err| err.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::{
        io::{BufRead, BufReader, Read, Write},
        net::Shutdown,
        os::unix::net::UnixStream,
        thread,
        time::Duration,
    };

    fn write_masked_ws_text_frame(stream: &mut UnixStream, text: &str) {
        let payload = text.as_bytes();
        let mask = [0x12, 0x34, 0x56, 0x78];
        let mut header = Vec::with_capacity(14);
        header.push(0x81);
        if payload.len() <= 125 {
            header.push(0x80 | payload.len() as u8);
        } else if payload.len() <= u16::MAX as usize {
            header.push(0x80 | 126);
            header.extend_from_slice(&(payload.len() as u16).to_be_bytes());
        } else {
            header.push(0x80 | 127);
            header.extend_from_slice(&(payload.len() as u64).to_be_bytes());
        }
        header.extend_from_slice(&mask);
        stream.write_all(&header).unwrap();

        let mut masked = payload.to_vec();
        for (index, byte) in masked.iter_mut().enumerate() {
            *byte ^= mask[index % mask.len()];
        }
        stream.write_all(&masked).unwrap();
        stream.flush().unwrap();
    }

    fn read_ws_text_frame(reader: &mut BufReader<UnixStream>) -> String {
        let mut header = [0u8; 2];
        reader.read_exact(&mut header).unwrap();
        let mut payload_len = (header[1] & 0x7F) as usize;
        if payload_len == 126 {
            let mut extended = [0u8; 2];
            reader.read_exact(&mut extended).unwrap();
            payload_len = u16::from_be_bytes(extended) as usize;
        } else if payload_len == 127 {
            let mut extended = [0u8; 8];
            reader.read_exact(&mut extended).unwrap();
            payload_len = u64::from_be_bytes(extended) as usize;
        }
        let mut payload = vec![0u8; payload_len];
        if payload_len > 0 {
            reader.read_exact(&mut payload).unwrap();
        }
        String::from_utf8(payload).unwrap()
    }

    #[test]
    fn websocket_stream_authenticates_and_dispatches_requests() {
        let daemon = Daemon::new("test");
        let (client, server) = UnixStream::pair().unwrap();
        let server_thread = thread::spawn(move || {
            daemon.serve_websocket_stream(server, "secret").unwrap();
        });

        let mut client = client;
        client
            .write_all(
                b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: SGVsbG9Xb3JsZA==\r\nSec-WebSocket-Version: 13\r\n\r\n",
            )
            .unwrap();
        client.flush().unwrap();

        let mut reader = BufReader::new(client.try_clone().unwrap());
        let mut status_line = String::new();
        reader.read_line(&mut status_line).unwrap();
        assert!(status_line.starts_with("HTTP/1.1 101"));
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if line == "\r\n" || line.is_empty() {
                break;
            }
        }

        write_masked_ws_text_frame(&mut client, r#"{"secret":"secret"}"#);
        let auth_response: Value = serde_json::from_str(&read_ws_text_frame(&mut reader)).unwrap();
        assert_eq!(auth_response["ok"].as_bool(), Some(true));
        assert_eq!(
            auth_response["result"]["authenticated"].as_bool(),
            Some(true)
        );

        write_masked_ws_text_frame(&mut client, r#"{"id":1,"method":"hello","params":{}}"#);
        let response: Value = serde_json::from_str(&read_ws_text_frame(&mut reader)).unwrap();
        assert_eq!(response["ok"].as_bool(), Some(true));
        assert_eq!(response["id"].as_i64(), Some(1));
        assert_eq!(response["result"]["name"].as_str(), Some("cmuxd-remote"));

        client.shutdown(Shutdown::Both).unwrap();
        server_thread.join().unwrap();
    }

    use crate::auth::{TicketClaims, sign};

    fn tmux_exec(daemon: &Daemon, argv: &[&str]) -> Value {
        daemon
            .dispatch_json("tmux.exec", json!({ "argv": argv }))
            .unwrap()
    }

    fn wait_ready(daemon: &Daemon, session_id: &str) {
        daemon
            .dispatch_json(
                "amux.wait",
                json!({
                    "kind": "ready",
                    "session_id": session_id,
                    "timeout_ms": 5_000,
                }),
            )
            .unwrap();
    }

    fn event_kinds(result: &Value) -> Vec<&str> {
        result["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|event| event["kind"].as_str().unwrap())
            .collect()
    }

    fn strip_display_id<'a>(value: &'a str, prefix: char) -> &'a str {
        value.trim_start_matches(prefix)
    }

    fn encode_ticket(claims: TicketClaims, secret: &[u8]) -> String {
        let payload = serde_json::to_vec(&claims).unwrap();
        let encoded_payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(payload);
        let encoded_signature = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(sign(encoded_payload.as_bytes(), secret));
        format!("{encoded_payload}.{encoded_signature}")
    }

    #[test]
    fn amux_events_read_accepts_filters_plural_and_session_close_emits_close_events() {
        let daemon = Daemon::new("test");
        let opened = tmux_exec(&daemon, &["new-session", "-s", "close-demo", "/bin/cat"]);
        let session_id = opened["session_id"].as_str().unwrap();
        wait_ready(&daemon, session_id);

        let cursor = daemon.current_event_cursor();
        daemon
            .dispatch_json("session.close", json!({ "session_id": session_id }))
            .unwrap();

        let events = daemon
            .dispatch_json(
                "amux.events.read",
                json!({
                    "cursor": cursor,
                    "timeout_ms": 0,
                    "filters": ["pane.close", "window.close", "session.close"],
                }),
            )
            .unwrap();

        assert_eq!(
            event_kinds(&events),
            vec!["pane.close", "window.close", "session.close"]
        );
    }

    #[test]
    fn tmux_targets_accept_dollar_prefixed_session_window_targets() {
        let daemon = Daemon::new("test");
        let opened = tmux_exec(&daemon, &["new-session", "-s", "target-demo", "/bin/cat"]);
        let session_id = opened["session_id"].as_str().unwrap().to_string();
        wait_ready(&daemon, &session_id);

        let list = tmux_exec(
            &daemon,
            &[
                "list-panes",
                "-t",
                "$target-demo:0",
                "-F",
                "#{session_name}:#{window_index}.#{pane_index}",
            ],
        );
        assert_eq!(list["stdout"].as_str().unwrap().trim(), "target-demo:0.0");

        let display = tmux_exec(
            &daemon,
            &[
                "display-message",
                "-t",
                "$target-demo:0",
                "#{session_name}:#{window_index}.#{pane_index}",
            ],
        );
        assert_eq!(
            display["stdout"].as_str().unwrap().trim(),
            "target-demo:0.0"
        );

        daemon
            .dispatch_json("session.close", json!({ "session_id": session_id }))
            .unwrap();
    }

    #[test]
    fn tmux_kill_commands_emit_close_events() {
        let daemon = Daemon::new("test");
        let opened = tmux_exec(&daemon, &["new-session", "-s", "kill-demo", "/bin/cat"]);
        let session_id = opened["session_id"].as_str().unwrap().to_string();
        wait_ready(&daemon, &session_id);

        let split = tmux_exec(&daemon, &["split-window", "-t", "kill-demo:0", "/bin/cat"]);
        let split_pane_id = strip_display_id(split["pane_id"].as_str().unwrap(), '%').to_string();
        let cursor = daemon.current_event_cursor();
        tmux_exec(&daemon, &["kill-pane", "-t", "$kill-demo:0.1"]);

        let pane_events = daemon
            .dispatch_json(
                "amux.events.read",
                json!({
                    "cursor": cursor,
                    "timeout_ms": 0,
                    "filters": ["pane.close"],
                    "session_id": session_id,
                }),
            )
            .unwrap();
        let pane_events = pane_events["events"].as_array().unwrap();
        assert_eq!(pane_events.len(), 1);
        assert_eq!(pane_events[0]["kind"].as_str().unwrap(), "pane.close");
        assert_eq!(pane_events[0]["pane_id"].as_str().unwrap(), split_pane_id);

        let new_window = tmux_exec(&daemon, &["new-window", "-t", "kill-demo", "/bin/cat"]);
        let window_id =
            strip_display_id(new_window["window_id"].as_str().unwrap(), '@').to_string();
        let window_pane_id =
            strip_display_id(new_window["pane_id"].as_str().unwrap(), '%').to_string();
        let cursor = daemon.current_event_cursor();
        tmux_exec(&daemon, &["kill-window", "-t", "$kill-demo:1"]);

        let window_events = daemon
            .dispatch_json(
                "amux.events.read",
                json!({
                    "cursor": cursor,
                    "timeout_ms": 0,
                    "filters": ["pane.close", "window.close", "session.close"],
                    "session_id": session_id,
                }),
            )
            .unwrap();
        let window_events = window_events["events"].as_array().unwrap();
        assert_eq!(window_events.len(), 2);
        assert_eq!(window_events[0]["kind"].as_str().unwrap(), "pane.close");
        assert_eq!(
            window_events[0]["pane_id"].as_str().unwrap(),
            window_pane_id
        );
        assert_eq!(window_events[1]["kind"].as_str().unwrap(), "window.close");
        assert_eq!(window_events[1]["window_id"].as_str().unwrap(), window_id);

        daemon
            .dispatch_json("session.close", json!({ "session_id": session_id }))
            .unwrap();
    }

    #[test]
    fn amux_wait_signal_tracks_tmux_wait_for_generations() {
        let daemon = Daemon::new("test");

        tmux_exec(&daemon, &["wait-for", "-S", "spec-signal"]);
        let first = daemon
            .dispatch_json(
                "amux.wait",
                json!({
                    "kind": "signal",
                    "name": "spec-signal",
                    "after_generation": 0,
                    "timeout_ms": 0,
                }),
            )
            .unwrap();
        assert_eq!(first["name"].as_str().unwrap(), "spec-signal");
        assert_eq!(first["generation"].as_u64().unwrap(), 1);

        let signaler = daemon.clone();
        let signal_thread = thread::spawn(move || {
            tmux_exec(&signaler, &["wait-for", "-S", "spec-signal"]);
        });
        signal_thread.join().unwrap();

        let second = daemon
            .dispatch_json(
                "amux.wait",
                json!({
                    "kind": "signal",
                    "name": "spec-signal",
                    "after_generation": 1,
                    "timeout_ms": 5_000,
                }),
            )
            .unwrap();
        assert_eq!(second["name"].as_str().unwrap(), "spec-signal");
        assert_eq!(second["generation"].as_u64().unwrap(), 2);
    }

    #[test]
    fn tmux_required_format_variables_render_without_placeholders() {
        let daemon = Daemon::new("test");
        let opened = tmux_exec(
            &daemon,
            &[
                "new-session",
                "-s",
                "fmt-demo",
                "-n",
                "fmt-window",
                "/bin/cat",
            ],
        );
        let session_id = opened["session_id"].as_str().unwrap().to_string();
        wait_ready(&daemon, &session_id);

        let rendered = tmux_exec(
            &daemon,
            &[
                "display-message",
                "-t",
                "fmt-demo:0.0",
                "#{session_name}|#{session_id}|#{window_id}|#{window_name}|#{window_index}|#{window_active}|#{pane_id}|#{pane_index}|#{pane_active}|#{pane_title}|#{pane_current_path}|#{pane_current_command}",
            ],
        )["stdout"]
            .as_str()
            .unwrap()
            .trim()
            .to_string();

        assert!(!rendered.contains("#{"));
        let parts: Vec<&str> = rendered.split('|').collect();
        assert_eq!(parts.len(), 12);
        assert_eq!(parts[0], "fmt-demo");
        assert_eq!(parts[1], "$fmt-demo");
        assert_eq!(parts[2], opened["window_id"].as_str().unwrap());
        assert_eq!(parts[3], "fmt-window");
        assert_eq!(parts[4], "0");
        assert_eq!(parts[5], "1");
        assert_eq!(parts[6], opened["pane_id"].as_str().unwrap());
        assert_eq!(parts[7], "0");
        assert_eq!(parts[8], "1");
        assert_eq!(parts[11], "cat");

        daemon
            .dispatch_json("session.close", json!({ "session_id": session_id }))
            .unwrap();
    }

    #[test]
    fn exited_event_is_emitted_once_per_pane_exit() {
        let daemon = Daemon::new("test");
        let opened = tmux_exec(
            &daemon,
            &["new-session", "-s", "exit-demo", "/bin/echo", "done"],
        );
        let session_id = opened["session_id"].as_str().unwrap().to_string();
        let pane_id = strip_display_id(opened["pane_id"].as_str().unwrap(), '%').to_string();

        daemon
            .dispatch_json(
                "amux.wait",
                json!({
                    "kind": "exited",
                    "pane_id": pane_id,
                    "timeout_ms": 5_000,
                }),
            )
            .unwrap();
        thread::sleep(Duration::from_millis(100));

        let exited_events = daemon
            .dispatch_json(
                "amux.events.read",
                json!({
                    "cursor": 0,
                    "timeout_ms": 0,
                    "filters": ["exited"],
                    "session_id": session_id,
                }),
            )
            .unwrap();
        assert_eq!(event_kinds(&exited_events), vec!["exited"]);

        let cursor = exited_events["cursor"].as_u64().unwrap();
        daemon
            .dispatch_json(
                "amux.capture",
                json!({
                    "pane_id": strip_display_id(opened["pane_id"].as_str().unwrap(), '%'),
                    "history": true,
                }),
            )
            .unwrap();
        thread::sleep(Duration::from_millis(50));

        let later_events = daemon
            .dispatch_json(
                "amux.events.read",
                json!({
                    "cursor": cursor,
                    "timeout_ms": 0,
                    "filters": ["exited"],
                }),
            )
            .unwrap();
        assert!(later_events["events"].as_array().unwrap().is_empty());

        daemon
            .dispatch_json("session.close", json!({ "session_id": "exit-demo" }))
            .unwrap();
    }

    #[test]
    fn generated_session_ids_skip_existing_custom_ids() {
        let daemon = Daemon::new("test");
        let custom = daemon
            .dispatch_json(
                "terminal.open",
                json!({
                    "session_id": "sess-1",
                    "command": "/bin/cat",
                    "cols": 80,
                    "rows": 24,
                }),
            )
            .unwrap();
        let generated = daemon
            .dispatch_json(
                "terminal.open",
                json!({
                    "command": "/bin/cat",
                    "cols": 80,
                    "rows": 24,
                }),
            )
            .unwrap();

        assert_eq!(custom["session_id"].as_str().unwrap(), "sess-1");
        assert_eq!(generated["session_id"].as_str().unwrap(), "sess-2");

        daemon
            .dispatch_json("session.close", json!({ "session_id": "sess-1" }))
            .unwrap();
        daemon
            .dispatch_json("session.close", json!({ "session_id": "sess-2" }))
            .unwrap();
    }

    #[test]
    fn bare_tmux_pane_targets_do_not_escape_the_active_window() {
        let daemon = Daemon::new("test");
        tmux_exec(&daemon, &["new-session", "-s", "alpha", "/bin/cat"]);
        tmux_exec(&daemon, &["new-session", "-s", "beta", "/bin/cat"]);
        tmux_exec(&daemon, &["split-window", "-t", "beta:0", "/bin/cat"]);

        let err = match daemon.tmux_resolve_pane(Some("1")) {
            Ok(_) => panic!("bare pane index should stay scoped to the active window"),
            Err(err) => err,
        };
        assert_eq!(err, "pane not found: 1");

        daemon
            .dispatch_json("session.close", json!({ "session_id": "alpha" }))
            .unwrap();
        daemon
            .dispatch_json("session.close", json!({ "session_id": "beta" }))
            .unwrap();
    }

    #[test]
    fn direct_tls_keeps_buffered_frames_after_handshake() {
        let daemon = Daemon::new("test");
        let (client, server) = UnixStream::pair().unwrap();
        let server_thread = thread::spawn(move || {
            daemon.serve_tls_stream(server, "srv", b"secret").unwrap();
        });

        let claims = TicketClaims {
            server_id: "srv".to_string(),
            team_id: String::new(),
            session_id: String::new(),
            attachment_id: String::new(),
            capabilities: vec!["session.open".to_string()],
            exp: unix_now_secs() + 60,
            nonce: "buffered-handshake".to_string(),
        };
        let ticket = encode_ticket(claims, b"secret");
        let handshake = serde_json::to_vec(&json!({ "ticket": ticket })).unwrap();
        let request = serde_json::to_vec(&json!({
            "id": 1,
            "method": "hello",
            "params": {}
        }))
        .unwrap();

        let mut client = client;
        client.write_all(&handshake).unwrap();
        client.write_all(b"\n").unwrap();
        client.write_all(&request).unwrap();
        client.write_all(b"\n").unwrap();
        client.flush().unwrap();
        client.shutdown(Shutdown::Write).unwrap();

        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let handshake_response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(handshake_response["ok"].as_bool(), Some(true));

        line.clear();
        reader.read_line(&mut line).unwrap();
        let request_response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request_response["ok"].as_bool(), Some(true));
        assert_eq!(
            request_response["result"]["name"].as_str(),
            Some("cmuxd-remote")
        );

        server_thread.join().unwrap();
    }
}
