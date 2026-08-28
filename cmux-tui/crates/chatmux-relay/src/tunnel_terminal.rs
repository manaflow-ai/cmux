//! Tunnel-direct terminal listener (managed sandboxes only).
//!
//! The chatmux tunnel gateway's `/tcp` endpoint splices a browser WebSocket
//! onto a raw byte stream that dials 127.0.0.1:<port> inside this sandbox.
//! This module is that port: a loopback TCP server that serves terminals
//! through the SAME PtyManager the relay-socket path uses (whole-session
//! attach, W86 single-terminal attach, scrollback replay, sizing,
//! backpressure caps — all shared, none duplicated). Rust port of the Node
//! reference `packages/relay/bin/tunnel-terminal.mjs` in chatmux; the wire
//! shapes are pinned there (docs/TERMINAL.md) and by the tests below.
//!
//! FRAMING — the splice is a raw byte pipe (the browser's WebSocket message
//! boundaries are lost in transit), so every message is length-prefixed:
//!
//!   u32 big-endian payloadLength | u8 kind | payload[payloadLength]
//!
//!   kind 0 = UTF-8 JSON control frame
//!   kind 1 = raw PTY bytes (client->server stdin, server->client output)
//!
//! payloadLength is bounded by MAX_TUNNEL_FRAME_BYTES (1 MiB). An oversized
//! length, an unknown kind, or an undecodable control frame is a protocol
//! error: the server hard-closes the connection (a desynced length stream
//! can never be re-synchronized).
//!
//! CONTROL FRAMES mirror the browser terminal wire, minus the auth step:
//!
//!   c->s first frame  {t:"open", session?, surface?, cols, rows}
//!   s->c              {t:"opened", session, surface?, created, cols, rows}
//!                     or {t:"error", code, message?}
//!   then kind-1 byte flow both ways; later control frames:
//!   c->s              {t:"resize", cols, rows}, {t:"detach"}
//!   s->c              {t:"exit", code}, {t:"error", code, message?}
//!
//! THREAT MODEL — there is deliberately NO auth frame. The tunnel gateway
//! already enforced a capability token minted by the Worker (policyd client
//! token bound to this sandbox + port) before splicing the connection, and
//! this listener binds loopback only, inside a sandbox where local code can
//! already attach terminals through the cmux CLI. Paired human machines
//! never run this listener: it starts from the managed branch only.

use std::future::Future;
use std::pin::Pin;
use std::sync::RwLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::task::{Context, Poll};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Semaphore, mpsc, watch};
use tokio_util::sync::CancellationToken;

use crate::pty::{
    FrameContext, PTY_PROTOCOL_VERSION, PtyManager, TransportKind, random_hex, session_name_ok,
    surface_ref_ok,
};

/// Loopback port the gateway's spliced streams dial. The chatmux Worker
/// mirrors this value in apps/backend/src/tunnel/terminal-ticket-route.ts —
/// KEEP IN SYNC.
pub const TUNNEL_TERMINAL_PORT: u16 = 9776;
/// Loopback ONLY: the tunnel backhaul dials local ports; nothing else may.
pub const TUNNEL_TERMINAL_HOST: &str = "127.0.0.1";
/// Hard per-frame payload bound (matches the relay JSON frame maximum).
pub const MAX_TUNNEL_FRAME_BYTES: usize = 1_048_576;
pub const FRAME_KIND_CONTROL: u8 = 0;
pub const FRAME_KIND_PTY: u8 = 1;
/// u32 length + u8 kind.
const HEADER_BYTES: usize = 5;
/// The opened (or refused) reply must arrive within this budget.
const OPEN_TIMEOUT: Duration = Duration::from_secs(10);
/// Writer flow control: pause the PTY source above the high-water mark of
/// bytes queued toward the socket, resume below the low-water mark. The
/// manager's own 1 MiB output cap stays the hard boundary above this.
const FLOW_PAUSE_BYTES: u64 = 262_144;
const FLOW_RESUME_BYTES: u64 = 32_768;
/// The manager's output cap is one MiB. Keep a small control-frame reserve so
/// a queued output frame cannot prevent an exit or refusal from being sent,
/// while still making the total writer memory bound explicit.
const TUNNEL_QUEUE_BYTES: u64 = MAX_TUNNEL_FRAME_BYTES as u64 + HEADER_BYTES as u64 + 64 * 1024;
/// Bytes held back for terminal control/error frames. Data frames cannot
/// consume this budget, so a saturated output queue can still report failure
/// or completion.
const TUNNEL_CONTROL_QUEUE_RESERVE_BYTES: u64 = 64 * 1024;
const TUNNEL_WRITER_QUEUE_ITEMS: usize = 256;
/// Keep queue slots available for `opened`, `error`, and `exit` control
/// frames. PTY output is rejected before it consumes the reserve.
const TUNNEL_CONTROL_QUEUE_RESERVE_ITEMS: usize = 8;
/// Bound pre-open sockets as well as live PTY attachments. A gateway retry
/// storm must not allocate one reader, writer, and 64 KiB read buffer per
/// unbounded connection.
const TUNNEL_MAX_CONNECTIONS: usize = 64;

/// Authority published by the authenticated relay session for local tunnel
/// connections. `None` means the relay is disconnected or has not completed
/// hello negotiation, so tunnel opens fail closed.
#[derive(Clone, Debug, Default)]
pub struct TunnelAuth {
    pub trust: String,
    pub local_roots: Option<Vec<String>>,
    pub owner_user_id: Option<String>,
}

/// A monotonically versioned authority slot. The generation changes whenever
/// the relay reconnects or publishes a new trust snapshot, so a tunnel socket
/// opened under an older capability cannot continue after that boundary.
#[derive(Clone, Debug, Default)]
pub struct TunnelAuthority {
    pub generation: u64,
    pub auth: Option<TunnelAuth>,
}

impl TunnelAuthority {
    pub fn revoked(previous_generation: u64) -> Self {
        Self { generation: previous_generation.saturating_add(1), auth: None }
    }

    pub fn published(previous_generation: u64, auth: TunnelAuth) -> Self {
        Self { generation: previous_generation.saturating_add(1), auth: Some(auth) }
    }
}

pub type TunnelAuthState = Arc<RwLock<TunnelAuthority>>;

/// Relay pty_error codes -> browser wire codes. Mirrors the Worker's
/// browserErrorCode map (apps/backend/src/terminal/relay-pty.ts). KEEP IN
/// SYNC; `wire_error_codes_match_the_worker_map` pins the shape here.
pub fn wire_error_code(code: &str) -> &'static str {
    match code {
        "bad_request" => "bad_request",
        "trust_refused" => "trust_blocked",
        "session_limit" => "session_limit",
        "terminal_gone" => "terminal_gone",
        "overflow" => "overflow",
        "trust_revoked" => "trust_revoked",
        "busy" => "busy",
        _ => "failed",
    }
}

// ---------------------------------------------------------------------------
// Framing codec
// ---------------------------------------------------------------------------

#[derive(Debug, PartialEq)]
pub struct TunnelFrame {
    pub kind: u8,
    pub payload: Vec<u8>,
}

/// Encode one frame: u32be payload length, u8 kind, payload.
pub fn encode_tunnel_frame(kind: u8, payload: &[u8]) -> Option<Vec<u8>> {
    if payload.len() > MAX_TUNNEL_FRAME_BYTES
        || !matches!(kind, FRAME_KIND_CONTROL | FRAME_KIND_PTY)
    {
        return None;
    }
    let mut frame = Vec::with_capacity(HEADER_BYTES + payload.len());
    frame.extend_from_slice(&u32::try_from(payload.len()).ok()?.to_be_bytes());
    frame.push(kind);
    frame.extend_from_slice(payload);
    Some(frame)
}

pub fn encode_control_frame(frame: &Value) -> Option<Vec<u8>> {
    encode_tunnel_frame(FRAME_KIND_CONTROL, frame.to_string().as_bytes())
}

pub fn encode_pty_frame(bytes: &[u8]) -> Option<Vec<u8>> {
    encode_tunnel_frame(FRAME_KIND_PTY, bytes)
}

/// Incremental frame decoder. After one failure the decoder is poisoned: a
/// length-prefixed stream that desynced once can never be trusted again, so
/// the caller must close the connection.
pub struct TunnelFrameDecoder {
    buffer: Vec<u8>,
    /// Bytes before this cursor have already been emitted. Keeping a cursor
    /// avoids repeatedly shifting the whole buffer for a busy PTY stream.
    cursor: usize,
    failed: bool,
    max_frame_bytes: usize,
}

impl TunnelFrameDecoder {
    pub fn new(max_frame_bytes: usize) -> TunnelFrameDecoder {
        TunnelFrameDecoder {
            buffer: Vec::new(),
            cursor: 0,
            failed: false,
            max_frame_bytes: max_frame_bytes.clamp(1, MAX_TUNNEL_FRAME_BYTES),
        }
    }

    pub fn push(&mut self, chunk: &[u8]) -> Result<Vec<TunnelFrame>, &'static str> {
        if self.failed {
            return Err("decoder_poisoned");
        }
        self.buffer.extend_from_slice(chunk);
        let mut frames = Vec::new();
        while self.buffer.len().saturating_sub(self.cursor) >= HEADER_BYTES {
            let length = u32::from_be_bytes([
                self.buffer[self.cursor],
                self.buffer[self.cursor + 1],
                self.buffer[self.cursor + 2],
                self.buffer[self.cursor + 3],
            ]) as usize;
            let kind = self.buffer[self.cursor + 4];
            if length > self.max_frame_bytes {
                self.failed = true;
                return Err("frame_too_large");
            }
            if kind != FRAME_KIND_CONTROL && kind != FRAME_KIND_PTY {
                self.failed = true;
                return Err("unknown_frame_kind");
            }
            if self.buffer.len().saturating_sub(self.cursor) < HEADER_BYTES + length {
                break;
            }
            let start = self.cursor + HEADER_BYTES;
            let payload = self.buffer[start..start + length].to_vec();
            self.cursor = start + length;
            frames.push(TunnelFrame { kind, payload });
        }
        if self.cursor > 0 && (self.cursor >= 64 * 1024 || self.cursor * 2 >= self.buffer.len()) {
            self.buffer.drain(..self.cursor);
            self.cursor = 0;
        }
        Ok(frames)
    }
}

// ---------------------------------------------------------------------------
// Client control frame parsing (mirror of the browser wire minus `auth`)
// ---------------------------------------------------------------------------

#[derive(Debug, PartialEq)]
pub enum ClientFrame {
    Open { session: Option<String>, surface: Option<String>, cols: u16, rows: u16 },
    Resize { cols: u16, rows: u16 },
    Detach,
}

fn valid_dims(raw: &Value) -> Option<(u16, u16)> {
    let dim = |key: &str| {
        raw.get(key)
            .and_then(Value::as_u64)
            .filter(|value| (1..=10_000).contains(value))
            .and_then(|value| u16::try_from(value).ok())
    };
    Some((dim("cols")?, dim("rows")?))
}

/// None = malformed (a protocol error; the caller closes).
pub fn parse_tunnel_client_frame(payload: &[u8]) -> Option<ClientFrame> {
    let raw: Value = serde_json::from_slice(payload).ok()?;
    if !raw.is_object() {
        return None;
    }
    match raw.get("t").and_then(Value::as_str) {
        Some("open") => {
            let (cols, rows) = valid_dims(&raw)?;
            let session = match raw.get("session") {
                None => None,
                Some(value) => {
                    let name = value.as_str().filter(|name| session_name_ok(name))?;
                    Some(name.to_owned())
                }
            };
            let surface = match raw.get("surface") {
                None => None,
                Some(value) => {
                    // A surface ref without a session has nothing to resolve
                    // against.
                    session.as_ref()?;
                    let surface = value.as_str().filter(|surface| surface_ref_ok(surface))?;
                    Some(surface.to_owned())
                }
            };
            Some(ClientFrame::Open { session, surface, cols, rows })
        }
        Some("resize") => {
            let (cols, rows) = valid_dims(&raw)?;
            Some(ClientFrame::Resize { cols, rows })
        }
        Some("detach") => Some(ClientFrame::Detach),
        _ => None,
    }
}

/// Server-generated session names: same alphabet and prefix the Worker route
/// uses, so pickers and process tables read consistently.
pub fn generate_session_name() -> Result<String, getrandom::Error> {
    const ALPHABET: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";
    let mut bytes = [0_u8; 4];
    getrandom::fill(&mut bytes)?;
    let suffix: String =
        bytes.iter().map(|byte| ALPHABET[*byte as usize % ALPHABET.len()] as char).collect();
    Ok(format!("web-{suffix}"))
}

// ---------------------------------------------------------------------------
// One spliced connection = one terminal attachment
// ---------------------------------------------------------------------------

enum WriterMessage {
    Frame(Vec<u8>),
    /// Flush what is queued, then close the write half. The slot for this
    /// message is reserved when the connection starts.
    End,
}

/// State shared between the reader task, the writer task, and the manager's
/// synchronous reply sink.
struct Connection {
    pty_id: String,
    manager: Arc<PtyManager>,
    writer_tx: mpsc::Sender<WriterMessage>,
    /// A permanently reserved channel slot for the terminal shutdown frame.
    /// `finish` is synchronous, so it cannot wait for queue capacity.
    end_permit: StdMutex<Option<mpsc::OwnedPermit<WriterMessage>>>,
    /// Serializes enqueue and End so shutdown cannot overtake a frame that
    /// already reserved bytes. The critical section only performs a
    /// non-blocking channel operation.
    queue_gate: std::sync::Mutex<()>,
    /// pty_flow requests from the writer's water marks (true = pause).
    flow_tx: watch::Sender<bool>,
    auth_state: TunnelAuthState,
    /// Authority generation captured when this socket was accepted.
    auth_generation: u64,
    /// Bytes queued toward the socket and not yet written.
    pending_out: AtomicU64,
    paused: AtomicBool,
    /// The open frame was forwarded to the manager (pty_close owed on exit).
    open_sent: AtomicBool,
    /// The manager answered pty_opened (clears the open deadline).
    opened_seen: AtomicBool,
    finished: AtomicBool,
    done: CancellationToken,
}

impl Connection {
    fn send_control(&self, frame: &Value) {
        let Some(encoded) = encode_control_frame(frame) else {
            self.finish();
            return;
        };
        let _ = self.enqueue_frame(encoded, true);
    }

    fn reserve_bytes(&self, length: usize, control: bool) -> bool {
        let length = length as u64;
        if length > TUNNEL_QUEUE_BYTES {
            return false;
        }
        let mut current = self.pending_out.load(Ordering::Acquire);
        loop {
            let Some(next) = current.checked_add(length) else { return false };
            let limit = queue_limit(control);
            if next > limit {
                return false;
            }
            match self.pending_out.compare_exchange_weak(
                current,
                next,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return true,
                Err(observed) => current = observed,
            }
        }
    }

    fn enqueue_frame(&self, frame: Vec<u8>, control: bool) -> bool {
        let mut accepted = false;
        let mut reserved = 0_u64;
        {
            let _queue_gate = self.queue_gate.lock().expect("tunnel queue lock");
            let queue_has_room =
                control || self.writer_tx.capacity() > TUNNEL_CONTROL_QUEUE_RESERVE_ITEMS;
            if !self.finished.load(Ordering::SeqCst)
                && queue_has_room
                && self.reserve_bytes(frame.len(), control)
            {
                reserved = frame.len() as u64;
                if self.writer_tx.try_send(WriterMessage::Frame(frame)).is_ok() {
                    accepted = true;
                }
            }
        }
        if !accepted {
            if reserved != 0 {
                // The frame was never handed to the writer, so release its
                // reservation before closing the connection.
                self.pending_out.fetch_sub(reserved, Ordering::AcqRel);
            }
            self.finish();
        }
        accepted
    }

    /// Idempotent shutdown: flush queued frames, close the socket, and let
    /// the reader task settle the owed pty_close (detach, never kill — the
    /// session lives on for a later re-attach, the same rule a dropped
    /// relay-socket viewer follows).
    fn finish(&self) {
        let _queue_gate = self.queue_gate.lock().expect("tunnel queue lock");
        if self.finished.swap(true, Ordering::SeqCst) {
            return;
        }
        if let Some(permit) = self.end_permit.lock().expect("tunnel end permit lock").take() {
            permit.send(WriterMessage::End);
        }
        self.done.cancel();
    }

    fn protocol_error(&self, code: &str) {
        if self.finished.load(Ordering::SeqCst) {
            return;
        }
        // Do not forward parser or filesystem details over the tunnel. The
        // code is stable protocol data; clients can localize it without
        // exposing paths, command lines, or internal error strings.
        self.send_control(&json!({ "t": "error", "code": wire_error_code(code) }));
        self.finish();
    }

    /// The manager's reply sink (FrameContext::send). Synchronous: enqueue
    /// only, never block.
    fn on_manager_frame(&self, frame: &Value) {
        if self.finished.load(Ordering::SeqCst) {
            return;
        }
        if frame.get("ptyId").and_then(Value::as_str) != Some(self.pty_id.as_str()) {
            return;
        }
        match frame.get("type").and_then(Value::as_str) {
            Some("pty_opened") => {
                self.opened_seen.store(true, Ordering::SeqCst);
                let mut opened = json!({
                    "t": "opened",
                    "session": frame.get("session").cloned().unwrap_or(Value::Null),
                    "created": frame.get("created").and_then(Value::as_bool) == Some(true),
                    "cols": frame.get("cols").cloned().unwrap_or(Value::Null),
                    "rows": frame.get("rows").cloned().unwrap_or(Value::Null),
                });
                if let Some(surface) = frame.get("surface").and_then(Value::as_str) {
                    opened["surface"] = Value::from(surface);
                }
                self.send_control(&opened);
            }
            Some("pty_output") => {
                // Manager callbacks can race the reader's authority watch.
                // Re-check at enqueue time so revoked transports cannot
                // publish queued output after the generation changed.
                if !self.authority_current() {
                    self.protocol_error("trust_revoked");
                    return;
                }
                let Some(bytes) = frame
                    .get("dataB64")
                    .and_then(Value::as_str)
                    .and_then(|b64| BASE64.decode(b64).ok())
                    .filter(|bytes| !bytes.is_empty())
                else {
                    return;
                };
                let Some(encoded) = encode_pty_frame(&bytes) else {
                    self.protocol_error("overflow");
                    return;
                };
                if !self.enqueue_frame(encoded, false) {
                    return;
                }
                // Socket-side congestion: pause the source through the
                // manager's own flow verb; the writer resumes it below the
                // low-water mark.
                if self.pending_out.load(Ordering::SeqCst) > FLOW_PAUSE_BYTES
                    && !self.paused.swap(true, Ordering::SeqCst)
                {
                    let _ = self.flow_tx.send(true);
                }
            }
            Some("pty_exit") => {
                let code = frame.get("code").and_then(Value::as_i64).unwrap_or(0);
                self.send_control(&json!({ "t": "exit", "code": code }));
                self.finish();
            }
            Some("pty_error") => {
                let code =
                    wire_error_code(frame.get("code").and_then(Value::as_str).unwrap_or("failed"));
                self.send_control(&json!({ "t": "error", "code": code }));
                // Non-fatal errors (an oversized input frame) keep the
                // attachment; a refused open or a dropped attachment ends
                // the connection.
                if !self.manager.has_attachment(&self.pty_id) {
                    self.finish();
                }
            }
            _ => {}
        }
    }

    fn frame_context(self: &Arc<Self>) -> FrameContext {
        let sink = Arc::clone(self);
        let probe = Arc::clone(self);
        let authority = self.auth_state.read().ok().map(|state| state.clone()).unwrap_or_default();
        let auth = if authority.generation == self.auth_generation {
            authority.auth.unwrap_or_default()
        } else {
            TunnelAuth::default()
        };
        FrameContext {
            send: Arc::new(move |frame: Value| sink.on_manager_frame(&frame)),
            buffered_amount: Arc::new(move || probe.pending_out.load(Ordering::SeqCst)),
            trust: auth.trust,
            local_roots: auth.local_roots,
            owner_user_id: auth.owner_user_id,
            transport_id: Some(self.pty_id.clone()),
            transport_kind: TransportKind::Tunnel,
            auth_generation: Some(self.auth_generation),
        }
    }

    fn authority_current(&self) -> bool {
        self.auth_state.read().ok().is_some_and(|authority| {
            authority.generation == self.auth_generation && authority.auth.is_some()
        })
    }
}

fn queue_limit(control: bool) -> u64 {
    if control {
        TUNNEL_QUEUE_BYTES
    } else {
        TUNNEL_QUEUE_BYTES - TUNNEL_CONTROL_QUEUE_RESERVE_BYTES
    }
}

/// A spawned open task remains owned by the connection until it is joined.
/// Dropping a Tokio `JoinHandle` detaches the task, which would let a cancelled
/// tunnel finish opening and retain its PTY callbacks after the socket exits.
struct AbortOnDrop<T> {
    handle: Option<tokio::task::JoinHandle<T>>,
}

impl<T> AbortOnDrop<T> {
    fn new(handle: tokio::task::JoinHandle<T>) -> Self {
        Self { handle: Some(handle) }
    }

    fn abort(&self) {
        if let Some(handle) = &self.handle {
            handle.abort();
        }
    }
}

impl<T> Unpin for AbortOnDrop<T> {}

impl<T> Future for AbortOnDrop<T> {
    type Output = Result<T, tokio::task::JoinError>;

    fn poll(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<Self::Output> {
        let result = {
            let handle = self.handle.as_mut().expect("open task polled after completion");
            Pin::new(handle).poll(context)
        };
        match result {
            Poll::Ready(result) => {
                self.handle = None;
                Poll::Ready(result)
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

impl<T> Drop for AbortOnDrop<T> {
    fn drop(&mut self) {
        if let Some(handle) = &self.handle {
            handle.abort();
        }
    }
}

async fn handle_client_frame(
    connection: &Arc<Connection>,
    frame: TunnelFrame,
    authority_changes: &mut watch::Receiver<u64>,
) {
    if connection.finished.load(Ordering::SeqCst) {
        return;
    }
    if !connection.authority_current() {
        connection.protocol_error("trust_revoked");
        return;
    }
    if frame.kind == FRAME_KIND_PTY {
        if !connection.open_sent.load(Ordering::SeqCst) {
            connection.protocol_error("bad_request");
            return;
        }
        let input = json!({
            "version": PTY_PROTOCOL_VERSION,
            "type": "pty_input",
            "ptyId": connection.pty_id,
            "dataB64": BASE64.encode(&frame.payload),
        });
        let context = connection.frame_context();
        connection.manager.handle_frame(&input, &context).await;
        return;
    }
    let Some(parsed) = parse_tunnel_client_frame(&frame.payload) else {
        connection.protocol_error("bad_request");
        return;
    };
    match parsed {
        ClientFrame::Open { session, surface, cols, rows } => {
            if connection
                .open_sent
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_err()
            {
                connection.protocol_error("bad_request");
                return;
            }
            let session = match session {
                Some(session) => session,
                None => match generate_session_name() {
                    Ok(session) => session,
                    Err(_) => {
                        connection.protocol_error("failed");
                        return;
                    }
                },
            };
            let mut open = json!({
                "version": PTY_PROTOCOL_VERSION,
                "type": "pty_open",
                "ptyId": connection.pty_id,
                "session": session,
                "cols": cols,
                "rows": rows,
            });
            if let Some(surface) = surface {
                open["surface"] = Value::from(surface);
            }
            let context = connection.frame_context();
            // Run the open in its own task. Dropping an in-flight
            // `handle_frame` future from `timeout` can abandon work while it
            // owns manager resources. An explicit abort, followed by the
            // normal close path, gives cancellation a defined cleanup point.
            let mut open_task = AbortOnDrop::new(tokio::spawn({
                let manager = Arc::clone(&connection.manager);
                async move { manager.handle_frame(&open, &context).await }
            }));
            let deadline = tokio::time::sleep(OPEN_TIMEOUT);
            tokio::pin!(deadline);
            tokio::select! {
                result = &mut open_task => {
                    if result.is_err() {
                        connection.protocol_error("failed");
                    }
                }
                _ = &mut deadline => {
                    open_task.abort();
                    let _ = (&mut open_task).await;
                    connection.protocol_error("failed");
                }
                changed = authority_changes.changed() => {
                    let revoked = matches!(changed, Ok(()) if *authority_changes.borrow_and_update() != connection.auth_generation);
                    if revoked {
                        open_task.abort();
                        let _ = (&mut open_task).await;
                        connection.protocol_error("trust_revoked");
                    } else if changed.is_err() {
                        open_task.abort();
                        let _ = (&mut open_task).await;
                        connection.finish();
                    }
                }
            }
        }
        ClientFrame::Resize { cols, rows } => {
            if !connection.open_sent.load(Ordering::SeqCst) {
                return;
            }
            let resize = json!({
                "version": PTY_PROTOCOL_VERSION,
                "type": "pty_resize",
                "ptyId": connection.pty_id,
                "cols": cols,
                "rows": rows,
            });
            let context = connection.frame_context();
            connection.manager.handle_frame(&resize, &context).await;
        }
        ClientFrame::Detach => connection.finish(),
    }
}

async fn serve_connection(
    stream: TcpStream,
    manager: Arc<PtyManager>,
    parent: CancellationToken,
    auth_state: TunnelAuthState,
    mut authority_changes: watch::Receiver<u64>,
    _connection_permit: tokio::sync::OwnedSemaphorePermit,
) {
    let _ = stream.set_nodelay(true);
    let (mut read_half, mut write_half) = stream.into_split();
    let (writer_tx, mut writer_rx) = mpsc::channel::<WriterMessage>(TUNNEL_WRITER_QUEUE_ITEMS);
    // Reserve one item before any producer can fill the queue. Tokio's owned
    // permit keeps this capacity unavailable to ordinary `try_send` calls and
    // can later send End synchronously from `finish`.
    let end_permit = match writer_tx.clone().reserve_owned().await {
        Ok(permit) => permit,
        Err(_) => {
            let _ = write_half.shutdown().await;
            return;
        }
    };
    let (flow_tx, mut flow_rx) = watch::channel(false);
    let pty_id = match random_hex(8) {
        Ok(id) => format!("tunnel-{id}"),
        Err(_) => {
            let _ = write_half.shutdown().await;
            return;
        }
    };
    let auth_generation =
        auth_state.read().map(|authority| authority.generation).unwrap_or_default();
    let connection = Arc::new(Connection {
        pty_id,
        manager: Arc::clone(&manager),
        writer_tx,
        end_permit: StdMutex::new(Some(end_permit)),
        queue_gate: std::sync::Mutex::new(()),
        flow_tx,
        auth_state,
        auth_generation,
        pending_out: AtomicU64::new(0),
        paused: AtomicBool::new(false),
        open_sent: AtomicBool::new(false),
        opened_seen: AtomicBool::new(false),
        finished: AtomicBool::new(false),
        done: CancellationToken::new(),
    });
    // Writer: the only task that touches the write half. Applies the flow
    // water marks as the queue drains.
    let mut writer = {
        let connection = Arc::clone(&connection);
        tokio::spawn(async move {
            while let Some(message) = writer_rx.recv().await {
                match message {
                    WriterMessage::Frame(frame) => {
                        let written = write_half.write_all(&frame).await;
                        // Every dequeued frame added exactly its length at
                        // enqueue, so this never underflows.
                        let length = frame.len() as u64;
                        let previous = connection.pending_out.fetch_sub(length, Ordering::SeqCst);
                        if written.is_err() {
                            connection.finish();
                            break;
                        }
                        if previous.saturating_sub(length) < FLOW_RESUME_BYTES
                            && connection.paused.swap(false, Ordering::SeqCst)
                        {
                            let _ = connection.flow_tx.send(false);
                        }
                    }
                    WriterMessage::End => break,
                }
            }
            let _ = write_half.shutdown().await;
        })
    };

    // Flow verbs need the async manager; drain them on their own task so a
    // slow open never delays a pause.
    let flow = {
        let connection = Arc::clone(&connection);
        tokio::spawn(async move {
            while flow_rx.changed().await.is_ok() {
                let pause = *flow_rx.borrow_and_update();
                if connection.finished.load(Ordering::SeqCst) {
                    break;
                }
                let frame = json!({
                    "version": PTY_PROTOCOL_VERSION,
                    "type": "pty_flow",
                    "ptyId": connection.pty_id,
                    "pause": pause,
                });
                let context = connection.frame_context();
                connection.manager.handle_frame(&frame, &context).await;
            }
        })
    };

    // Reader: strictly in arrival order, so input received while an open
    // settles lands after the attachment exists. Awaiting each frame is the
    // ingest backpressure (the socket is simply not read meanwhile).
    let mut buffer = vec![0_u8; 65_536];
    let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
    let open_deadline = tokio::time::sleep(OPEN_TIMEOUT);
    tokio::pin!(open_deadline);
    loop {
        tokio::select! {
            biased;
            _ = parent.cancelled() => {
                connection.finish();
                break;
            }
            _ = connection.done.cancelled() => break,
            changed = authority_changes.changed() => {
                match changed {
                    Ok(()) if *authority_changes.borrow_and_update() != connection.auth_generation => {
                        connection.protocol_error("trust_revoked");
                        break;
                    }
                    Ok(()) => {}
                    Err(_) => {
                        connection.finish();
                        break;
                    }
                }
            }
            _ = &mut open_deadline, if !connection.opened_seen.load(Ordering::SeqCst) => {
                connection.protocol_error("bad_request");
                break;
            }
            read = read_half.read(&mut buffer) => {
                let count = match read {
                    Ok(0) | Err(_) => {
                        // A torn splice is a detach, exactly like a dropped
                        // browser socket.
                        connection.finish();
                        break;
                    }
                    Ok(count) => count,
                };
                match decoder.push(&buffer[..count]) {
                    Ok(frames) => {
                        for frame in frames {
                            handle_client_frame(&connection, frame, &mut authority_changes).await;
                        }
                    }
                    Err(_) => {
                        connection.protocol_error("bad_request");
                        break;
                    }
                }
            }
        }
    }
    connection.finish();
    // Stop the independent flow task before removing the transport snapshot.
    // Otherwise a queued pause/resume could enter `handle_frame` after the
    // detach and recreate stale authorization for this connection.
    flow.abort();
    let _ = flow.await;
    // Detach, never kill: the owed close releases only this connection's
    // attachment (transport-fenced), and the session lives on.
    if connection.open_sent.load(Ordering::SeqCst) {
        let close = json!({
            "version": PTY_PROTOCOL_VERSION,
            "type": "pty_close",
            "ptyId": connection.pty_id,
        });
        let context = connection.frame_context();
        manager.handle_frame(&close, &context).await;
    }
    // Remove the per-transport authority even when the open was refused or
    // the peer disconnected before an attachment existed. Otherwise a busy
    // local tunnel endpoint could accumulate stale snapshots indefinitely.
    manager.detach_transport_kind(&connection.pty_id, TransportKind::Tunnel);
    // A peer that stopped reading can wedge the final flush forever; the
    // attachment is already released above, so cap the flush and reap.
    if tokio::time::timeout(Duration::from_secs(30), &mut writer).await.is_err() {
        writer.abort();
    }
}

/// Start the loopback listener. Managed mode only — the caller's managed
/// branch is the gate; paired human machines never reach this. Returns the
/// bound port; a bind failure is the caller's cue to degrade (the relay
/// socket path still serves terminals).
pub async fn start_tunnel_terminal_listener(
    manager: Arc<PtyManager>,
    cancellation: CancellationToken,
    host: &str,
    port: u16,
    auth_state: TunnelAuthState,
    authority_changes: watch::Receiver<u64>,
) -> std::io::Result<u16> {
    // The gateway's capability check ends at this process. Binding any
    // address other than the fixed IPv4 loopback would turn a local-only
    // listener into an unauthenticated network terminal service. Keep the
    // host argument for the test and call-site contract, but fail closed if a
    // future caller passes a configurable or wildcard address.
    if host != TUNNEL_TERMINAL_HOST {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "tunnel terminal listener is unavailable",
        ));
    }
    let listener = TcpListener::bind((host, port)).await?;
    let bound = listener.local_addr()?.port();
    let connection_slots = Arc::new(Semaphore::new(TUNNEL_MAX_CONNECTIONS));
    tokio::spawn(async move {
        loop {
            let accepted = tokio::select! {
                biased;
                _ = cancellation.cancelled() => break,
                accepted = listener.accept() => accepted,
            };
            match accepted {
                Ok((stream, _)) => {
                    let permit = match connection_slots.clone().try_acquire_owned() {
                        Ok(permit) => permit,
                        Err(_) => {
                            let mut stream = stream;
                            let _ = stream.shutdown().await;
                            continue;
                        }
                    };
                    let manager = Arc::clone(&manager);
                    let child = cancellation.child_token();
                    tokio::spawn(serve_connection(
                        stream,
                        manager,
                        child,
                        Arc::clone(&auth_state),
                        authority_changes.clone(),
                        permit,
                    ));
                }
                Err(_) => {
                    // Transient accept errors (EMFILE and friends) must not
                    // spin; the listener itself stays up.
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
        }
    });
    Ok(bound)
}

// ---------------------------------------------------------------------------
// Tests — mirror packages/relay/test/tunnel-terminal.test.mjs in chatmux.
// A fake PtyDeps drives the real PtyManager over a real loopback socket.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pty::{
        CmuxTui, DataSink, EnsureDaemon, ExitSink, PtyControl, PtyDeps, PtyHandle, PtyOutput,
        SpawnSpec,
    };
    use async_trait::async_trait;
    use bytes::Bytes;
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};
    use std::sync::Mutex as StdMutex;
    use tokio::net::tcp::OwnedReadHalf;

    #[derive(Default)]
    struct FakeState {
        on_data: Option<DataSink>,
        on_exit: Option<ExitSink>,
        written: Vec<Vec<u8>>,
        resized: Vec<(u16, u16)>,
        killed: bool,
    }

    #[derive(Clone)]
    struct FakePty {
        state: Arc<StdMutex<FakeState>>,
    }

    impl FakePty {
        fn emit(&self, text: &str) {
            let sink = self.state.lock().unwrap().on_data.clone();
            if let Some(sink) = sink {
                sink(Bytes::copy_from_slice(text.as_bytes()));
            }
        }
        fn exit(&self, code: i64) {
            let sink = self.state.lock().unwrap().on_exit.clone();
            if let Some(sink) = sink {
                sink(code);
            }
        }
    }

    impl PtyControl for FakePty {
        fn write(&self, data: &[u8]) {
            self.state.lock().unwrap().written.push(data.to_vec());
        }
        fn resize(&self, cols: u16, rows: u16) {
            self.state.lock().unwrap().resized.push((cols, rows));
        }
        fn pause(&self) {}
        fn resume(&self) {}
        fn kill(&self) {
            self.state.lock().unwrap().killed = true;
        }
    }

    impl PtyOutput for FakePty {
        fn subscribe(&self, on_data: DataSink, on_exit: ExitSink) {
            let mut state = self.state.lock().unwrap();
            state.on_data = Some(on_data);
            state.on_exit = Some(on_exit);
        }
    }

    struct FakeDeps {
        spawned: Arc<StdMutex<Vec<FakePty>>>,
        banner: Option<Vec<u8>>,
    }

    #[async_trait]
    impl PtyDeps for FakeDeps {
        async fn spawn_pty(&self, _spec: SpawnSpec) -> PtyHandle {
            let pty = FakePty { state: Arc::new(StdMutex::new(FakeState::default())) };
            self.spawned.lock().unwrap().push(pty.clone());
            PtyHandle {
                control: Arc::new(pty.clone()),
                output: Arc::new(pty),
                banner: self.banner.clone(),
            }
        }
        async fn resolve_cmux_tui(&self) -> Option<CmuxTui> {
            None
        }
        async fn ensure_daemon(
            &self,
            _cmux_tui: &CmuxTui,
            _session: &str,
            _socket_dir: &Path,
            _cwd: &Path,
            _env: &HashMap<String, String>,
        ) -> Result<EnsureDaemon, String> {
            Err("no daemon in tunnel tests".to_owned())
        }
        async fn connect_control(
            &self,
            _socket_path: &Path,
        ) -> Result<Arc<dyn crate::control::ControlHandle>, String> {
            Err("no control in tunnel tests".to_owned())
        }
        async fn read_dir(&self, _path: &Path) -> Result<Vec<String>, ()> {
            Err(())
        }
        fn socket_dir(&self) -> PathBuf {
            std::env::temp_dir()
        }
        fn shell(&self) -> String {
            "/bin/fakesh".to_owned()
        }
    }

    struct Rig {
        manager: Arc<PtyManager>,
        spawned: Arc<StdMutex<Vec<FakePty>>>,
        port: u16,
        cancel: CancellationToken,
        generation: watch::Sender<u64>,
    }

    async fn rig_with_limits_and_banner(max_ptys: usize, banner: Option<Vec<u8>>) -> Rig {
        let spawned = Arc::new(StdMutex::new(Vec::new()));
        let deps = Arc::new(FakeDeps { spawned: Arc::clone(&spawned), banner });
        let env = HashMap::from([
            ("SHELL".to_owned(), "/bin/fakesh".to_owned()),
            ("HOME".to_owned(), std::env::temp_dir().to_string_lossy().into_owned()),
        ]);
        let manager = Arc::new(PtyManager::with_limits(
            deps,
            std::env::temp_dir(),
            env,
            max_ptys,
            32,
            1_048_576,
        ));
        let cancel = CancellationToken::new();
        let auth_state = Arc::new(RwLock::new(TunnelAuthority {
            generation: 0,
            auth: Some(TunnelAuth {
                trust: "supervised".to_owned(),
                local_roots: None,
                owner_user_id: None,
            }),
        }));
        let (generation, generation_rx) = watch::channel(0_u64);
        let port = start_tunnel_terminal_listener(
            Arc::clone(&manager),
            cancel.clone(),
            TUNNEL_TERMINAL_HOST,
            0,
            auth_state,
            generation_rx,
        )
        .await
        .expect("bind test listener");
        Rig { manager, spawned, port, cancel, generation }
    }

    async fn rig_with_limits(max_ptys: usize) -> Rig {
        rig_with_limits_and_banner(max_ptys, None).await
    }

    async fn rig_with_start_banner(banner: &[u8]) -> Rig {
        rig_with_limits_and_banner(8, Some(banner.to_vec())).await
    }

    async fn rig() -> Rig {
        rig_with_limits(8).await
    }

    async fn connect(rig: &Rig) -> TcpStream {
        TcpStream::connect((TUNNEL_TERMINAL_HOST, rig.port)).await.expect("connect")
    }

    /// Read whole frames off the socket with a deadline; panics on EOF.
    async fn next_frame(
        read: &mut OwnedReadHalf,
        decoder: &mut TunnelFrameDecoder,
        queue: &mut Vec<TunnelFrame>,
    ) -> TunnelFrame {
        loop {
            if !queue.is_empty() {
                return queue.remove(0);
            }
            let mut buffer = vec![0_u8; 65_536];
            let count = tokio::time::timeout(Duration::from_secs(5), read.read(&mut buffer))
                .await
                .expect("frame deadline")
                .expect("read");
            assert!(count > 0, "peer closed while a frame was expected");
            queue.extend(decoder.push(&buffer[..count]).expect("decode"));
        }
    }

    fn control_json(frame: &TunnelFrame) -> Value {
        assert_eq!(frame.kind, FRAME_KIND_CONTROL);
        serde_json::from_slice(&frame.payload).expect("control json")
    }

    #[test]
    fn data_reservation_leaves_control_bytes_available() {
        assert_eq!(queue_limit(false), TUNNEL_QUEUE_BYTES - TUNNEL_CONTROL_QUEUE_RESERVE_BYTES);
        assert!(queue_limit(false) < queue_limit(true));
        assert!(queue_limit(false) + TUNNEL_CONTROL_QUEUE_RESERVE_BYTES <= TUNNEL_QUEUE_BYTES);
    }

    #[test]
    fn control_reservation_accepts_reserved_tail() {
        let data_limit = queue_limit(false);
        assert!(data_limit + TUNNEL_CONTROL_QUEUE_RESERVE_BYTES <= queue_limit(true));
        assert!(TUNNEL_CONTROL_QUEUE_RESERVE_BYTES > 0);
    }

    #[test]
    fn maximum_valid_data_frame_fits_the_reserved_budget() {
        let encoded = encode_pty_frame(&vec![0_u8; MAX_TUNNEL_FRAME_BYTES]).expect("max frame");
        assert_eq!(encoded.len(), MAX_TUNNEL_FRAME_BYTES + HEADER_BYTES);
        assert!(encoded.len() as u64 <= queue_limit(false));
    }

    /// Wait until the fake spawn landed (open settles asynchronously).
    async fn spawned_pty(rig: &Rig) -> FakePty {
        for _ in 0..100 {
            if let Some(pty) = rig.spawned.lock().unwrap().first().cloned() {
                return pty;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("no PTY spawned");
    }

    async fn read_eof(read: &mut OwnedReadHalf) {
        let mut buffer = vec![0_u8; 4_096];
        loop {
            let count = tokio::time::timeout(Duration::from_secs(5), read.read(&mut buffer))
                .await
                .expect("eof deadline")
                .expect("read");
            if count == 0 {
                return;
            }
        }
    }

    async fn queue_connection(
        manager: Arc<PtyManager>,
    ) -> (Connection, mpsc::Receiver<WriterMessage>) {
        let (writer_tx, writer_rx) = mpsc::channel::<WriterMessage>(TUNNEL_WRITER_QUEUE_ITEMS);
        let end_permit = writer_tx.clone().reserve_owned().await.expect("reserve End slot");
        let (flow_tx, _) = watch::channel(false);
        (
            Connection {
                pty_id: "queue-test".to_owned(),
                manager,
                writer_tx,
                end_permit: StdMutex::new(Some(end_permit)),
                queue_gate: StdMutex::new(()),
                flow_tx,
                auth_state: Arc::new(RwLock::new(TunnelAuthority::default())),
                auth_generation: 0,
                pending_out: AtomicU64::new(0),
                paused: AtomicBool::new(false),
                open_sent: AtomicBool::new(false),
                opened_seen: AtomicBool::new(false),
                finished: AtomicBool::new(false),
                done: CancellationToken::new(),
            },
            writer_rx,
        )
    }

    #[tokio::test]
    async fn maximum_valid_pty_frame_fits_the_bounded_data_budget() {
        let rig = rig().await;
        let (connection, mut writer_rx) = queue_connection(Arc::clone(&rig.manager)).await;
        let frame = encode_pty_frame(&vec![b'x'; MAX_TUNNEL_FRAME_BYTES]).expect("valid frame");
        assert!(connection.enqueue_frame(frame, false));
        connection.finish();
        drop(connection);
        assert!(matches!(writer_rx.recv().await, Some(WriterMessage::Frame(_))));
        assert!(matches!(writer_rx.recv().await, Some(WriterMessage::End)));
        rig.cancel.cancel();
    }

    #[tokio::test]
    async fn saturated_writer_queue_still_delivers_error_and_end() {
        let rig = rig().await;
        let (connection, mut writer_rx) = queue_connection(Arc::clone(&rig.manager)).await;

        // Data can fill every ordinary slot, but the reserved permit keeps
        // the shutdown item available and the item reserve leaves room for
        // the control error.
        let accepted_data = TUNNEL_WRITER_QUEUE_ITEMS - TUNNEL_CONTROL_QUEUE_RESERVE_ITEMS - 1;
        for _ in 0..accepted_data {
            assert!(connection.enqueue_frame(vec![b'x'], false));
        }
        connection.send_control(&json!({ "t": "error", "code": "failed" }));
        connection.finish();
        drop(connection);

        let mut saw_error = false;
        let mut saw_end = false;
        while let Some(message) = writer_rx.recv().await {
            match message {
                WriterMessage::Frame(frame)
                    if frame.len() > 1 && frame[1] == FRAME_KIND_CONTROL =>
                {
                    let payload = &frame[5..];
                    let value: Value = serde_json::from_slice(payload).expect("error frame");
                    saw_error = value["t"] == "error" && value["code"] == "failed";
                }
                WriterMessage::End => {
                    saw_end = true;
                    break;
                }
                WriterMessage::Frame(_) => {}
            }
        }
        assert!(saw_error, "control error must survive data saturation");
        assert!(saw_end, "reserved End item must be delivered");
        rig.cancel.cancel();
    }

    // -- pure codec/parse ---------------------------------------------------

    #[test]
    fn codec_round_trips_frames_split_at_every_byte_boundary() {
        let control =
            encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })).unwrap();
        let pty = encode_pty_frame(b"echo hi\r").unwrap();
        let stream = [control, pty].concat();
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut frames = Vec::new();
        for byte in stream {
            frames.extend(decoder.push(&[byte]).expect("clean stream"));
        }
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].kind, FRAME_KIND_CONTROL);
        assert_eq!(frames[1].kind, FRAME_KIND_PTY);
        assert_eq!(frames[1].payload, b"echo hi\r");
    }

    #[test]
    fn oversized_length_poisons_the_decoder() {
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut header = ((MAX_TUNNEL_FRAME_BYTES + 1) as u32).to_be_bytes().to_vec();
        header.push(FRAME_KIND_PTY);
        assert_eq!(decoder.push(&header), Err("frame_too_large"));
        assert_eq!(decoder.push(b"anything"), Err("decoder_poisoned"));
    }

    #[test]
    fn unknown_kind_poisons_the_decoder() {
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut frame = 1_u32.to_be_bytes().to_vec();
        frame.push(7);
        frame.push(b'x');
        assert_eq!(decoder.push(&frame), Err("unknown_frame_kind"));
    }

    #[test]
    fn parse_accepts_the_wire_shapes_and_rejects_malformed_requests() {
        let open = parse_tunnel_client_frame(br#"{"t":"open","cols":80,"rows":24}"#);
        assert_eq!(
            open,
            Some(ClientFrame::Open { session: None, surface: None, cols: 80, rows: 24 })
        );
        let full = parse_tunnel_client_frame(
            br#"{"t":"open","session":"web-abc2","surface":"s:1.2","cols":1,"rows":10000}"#,
        );
        assert_eq!(
            full,
            Some(ClientFrame::Open {
                session: Some("web-abc2".to_owned()),
                surface: Some("s:1.2".to_owned()),
                cols: 1,
                rows: 10_000,
            })
        );
        assert_eq!(
            parse_tunnel_client_frame(br#"{"t":"resize","cols":120,"rows":40}"#),
            Some(ClientFrame::Resize { cols: 120, rows: 40 })
        );
        assert_eq!(parse_tunnel_client_frame(br#"{"t":"detach"}"#), Some(ClientFrame::Detach));
        for bad in [
            &br#"{"t":"open","cols":0,"rows":24}"#[..],
            br#"{"t":"open","cols":10001,"rows":24}"#,
            br#"{"t":"open","cols":80.5,"rows":24}"#,
            br#"{"t":"open","cols":80}"#,
            br#"{"t":"open","surface":"s:1.2","cols":80,"rows":24}"#,
            br#"{"t":"open","session":"bad/name","cols":80,"rows":24}"#,
            br#"{"t":"open","session":null,"cols":80,"rows":24}"#,
            br#"{"t":"nope"}"#,
            br#"[]"#,
            br#"not json"#,
        ] {
            assert_eq!(parse_tunnel_client_frame(bad), None, "{}", String::from_utf8_lossy(bad));
        }
    }

    #[test]
    fn wire_error_codes_match_the_worker_map() {
        assert_eq!(wire_error_code("trust_refused"), "trust_blocked");
        assert_eq!(wire_error_code("bad_request"), "bad_request");
        assert_eq!(wire_error_code("session_limit"), "session_limit");
        assert_eq!(wire_error_code("terminal_gone"), "terminal_gone");
        assert_eq!(wire_error_code("overflow"), "overflow");
        assert_eq!(wire_error_code("trust_revoked"), "trust_revoked");
        assert_eq!(wire_error_code("busy"), "busy");
        assert_eq!(wire_error_code("failed"), "failed");
        assert_eq!(wire_error_code("brand_new_code"), "failed");
    }

    #[test]
    fn generated_session_names_use_the_web_prefix_and_alphabet() {
        for _ in 0..32 {
            let name = generate_session_name().expect("OS entropy");
            let suffix = name.strip_prefix("web-").expect("web- prefix");
            assert_eq!(suffix.len(), 4);
            assert!(suffix.chars().all(|c| "abcdefghjkmnpqrstuvwxyz23456789".contains(c)));
        }
    }

    #[test]
    fn tunnel_frame_encoding_rejects_oversized_and_unknown_frames_in_release() {
        assert!(
            encode_tunnel_frame(FRAME_KIND_PTY, &vec![0_u8; MAX_TUNNEL_FRAME_BYTES + 1]).is_none()
        );
        assert!(encode_tunnel_frame(7, b"x").is_none());
        assert!(encode_pty_frame(b"ok").is_some());
    }

    // -- live listener ------------------------------------------------------

    #[tokio::test]
    async fn handshake_streams_both_ways_and_a_drop_detaches_without_killing() {
        let rig = rig().await;
        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut queue = Vec::new();

        write
            .write_all(
                &encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })).unwrap(),
            )
            .await
            .unwrap();
        let opened = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
        assert_eq!(opened["t"], "opened");
        assert_eq!(opened["created"], true);
        assert_eq!(opened["cols"], 80);
        assert_eq!(opened["rows"], 24);
        let session = opened["session"].as_str().expect("session name").to_owned();
        assert!(session.starts_with("web-"), "server-minted name: {session}");

        let pty = spawned_pty(&rig).await;
        pty.emit("hello from the shell");
        let output = next_frame(&mut read, &mut decoder, &mut queue).await;
        assert_eq!(output.kind, FRAME_KIND_PTY);
        assert_eq!(output.payload, b"hello from the shell");

        write.write_all(&encode_pty_frame(b"ls\r").unwrap()).await.unwrap();
        write
            .write_all(
                &encode_control_frame(&json!({ "t": "resize", "cols": 132, "rows": 43 })).unwrap(),
            )
            .await
            .unwrap();
        for _ in 0..100 {
            if !pty.state.lock().unwrap().written.is_empty()
                && !pty.state.lock().unwrap().resized.is_empty()
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(pty.state.lock().unwrap().written, vec![b"ls\r".to_vec()]);
        assert_eq!(pty.state.lock().unwrap().resized, vec![(132, 43)]);

        // A torn splice detaches; the shell session must survive for a
        // later re-attach (created:false proves it was found again).
        drop(write);
        drop(read);
        for _ in 0..100 {
            if rig.manager.attachment_count() == 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(rig.manager.attachment_count(), 0, "drop must release the attachment");
        assert!(!pty.state.lock().unwrap().killed, "detach must not kill the session");

        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut queue = Vec::new();
        write
            .write_all(
                &encode_control_frame(
                    &json!({ "t": "open", "session": session, "cols": 80, "rows": 24 }),
                )
                .unwrap(),
            )
            .await
            .unwrap();
        let reopened = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
        assert_eq!(reopened["t"], "opened");
        assert_eq!(reopened["created"], false);
        rig.cancel.cancel();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn tunnel_open_replays_start_output_without_deadlocking() {
        let rig = rig_with_start_banner(b"startup").await;
        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut queue = Vec::new();
        write
            .write_all(
                &encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })).unwrap(),
            )
            .await
            .unwrap();

        let opened = tokio::time::timeout(
            Duration::from_secs(1),
            next_frame(&mut read, &mut decoder, &mut queue),
        )
        .await
        .expect("tunnel open must not deadlock while starting output");
        assert_eq!(control_json(&opened)["t"], "opened");

        let output = tokio::time::timeout(
            Duration::from_secs(1),
            next_frame(&mut read, &mut decoder, &mut queue),
        )
        .await
        .expect("startup output must be delivered");
        assert_eq!(output.kind, FRAME_KIND_PTY);
        assert_eq!(output.payload, b"startup");

        drop(write);
        rig.cancel.cancel();
    }

    #[tokio::test]
    async fn bytes_before_open_are_a_protocol_error() {
        let rig = rig().await;
        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        write.write_all(&encode_pty_frame(b"sneaky").unwrap()).await.unwrap();
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut queue = Vec::new();
        let error = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
        assert_eq!(error["t"], "error");
        assert_eq!(error["code"], "bad_request");
        read_eof(&mut read).await;
        rig.cancel.cancel();
    }

    #[tokio::test]
    async fn authority_revocation_closes_a_quiet_open_attachment() {
        let rig = rig().await;
        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        write
            .write_all(
                &encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })).unwrap(),
            )
            .await
            .unwrap();
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut queue = Vec::new();
        let opened = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
        assert_eq!(opened["t"], "opened");
        assert_eq!(rig.manager.attachment_count(), 1);

        // The session publishes the new floor before notifying sockets. A
        // quiet connection must close without requiring another client frame.
        rig.manager.set_tunnel_authority_generation(1);
        rig.generation.send(1).unwrap();
        read_eof(&mut read).await;
        for _ in 0..100 {
            if rig.manager.attachment_count() == 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(rig.manager.attachment_count(), 0);
        drop(write);
        rig.cancel.cancel();
    }

    #[tokio::test]
    async fn duplicate_open_is_a_protocol_error() {
        let rig = rig().await;
        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        let open = encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })).unwrap();
        write.write_all(&open).await.unwrap();
        write.write_all(&open).await.unwrap();
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut queue = Vec::new();
        loop {
            let frame = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
            if frame["t"] == "error" {
                assert_eq!(frame["code"], "bad_request");
                break;
            }
            assert_eq!(frame["t"], "opened");
        }
        read_eof(&mut read).await;
        rig.cancel.cancel();
    }

    #[tokio::test]
    async fn a_malformed_control_frame_closes_the_connection() {
        let rig = rig().await;
        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        write
            .write_all(&encode_tunnel_frame(FRAME_KIND_CONTROL, b"{not json").unwrap())
            .await
            .unwrap();
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut queue = Vec::new();
        let error = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
        assert_eq!(error["t"], "error");
        assert_eq!(error["code"], "bad_request");
        read_eof(&mut read).await;
        rig.cancel.cancel();
    }

    #[tokio::test]
    async fn a_pty_exit_reaches_the_client_and_ends_the_connection() {
        let rig = rig().await;
        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        write
            .write_all(
                &encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })).unwrap(),
            )
            .await
            .unwrap();
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut queue = Vec::new();
        let opened = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
        assert_eq!(opened["t"], "opened");
        spawned_pty(&rig).await.exit(3);
        let exit = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
        assert_eq!(exit["t"], "exit");
        assert_eq!(exit["code"], 3);
        read_eof(&mut read).await;
        rig.cancel.cancel();
    }

    #[tokio::test]
    async fn a_refused_open_maps_the_error_code_and_closes() {
        let rig = rig_with_limits(0).await;
        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        write
            .write_all(
                &encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })).unwrap(),
            )
            .await
            .unwrap();
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut queue = Vec::new();
        let error = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
        assert_eq!(error["t"], "error");
        assert_eq!(error["code"], "session_limit");
        read_eof(&mut read).await;
        rig.cancel.cancel();
    }

    #[tokio::test]
    async fn listener_rejects_non_loopback_bind_addresses() {
        let spawned = Arc::new(StdMutex::new(Vec::new()));
        let deps = Arc::new(FakeDeps { spawned: Arc::clone(&spawned), banner: None });
        let manager = Arc::new(PtyManager::with_limits(
            deps,
            std::env::temp_dir(),
            HashMap::new(),
            1,
            32,
            1_048_576,
        ));
        let error = start_tunnel_terminal_listener(
            manager,
            CancellationToken::new(),
            "0.0.0.0",
            0,
            Arc::new(RwLock::new(TunnelAuthority::default())),
            watch::channel(0_u64).1,
        )
        .await
        .expect_err("wildcard bind must be rejected");
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
    }
}
