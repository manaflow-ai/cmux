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

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use bytes::{Buf, BytesMut};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::pty::{
    FrameContext, PTY_PROTOCOL_VERSION, PtyManager, random_hex, session_name_ok, surface_ref_ok,
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
/// Bound decoded client frames while the ordered dispatcher is waiting for an
/// open or control operation. The reader must keep observing EOF and
/// cancellation instead of waiting on an unbounded work queue.
// Eight 1 MiB frames cap each stalled connection's decoded client backlog at
// roughly 8 MiB. The output path has its separate 1 MiB byte cap.
const TUNNEL_DISPATCH_QUEUE_ITEMS: usize = 8;

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
pub fn encode_tunnel_frame(kind: u8, payload: &[u8]) -> Vec<u8> {
    debug_assert!(payload.len() <= MAX_TUNNEL_FRAME_BYTES);
    let mut frame = Vec::with_capacity(HEADER_BYTES + payload.len());
    frame.extend_from_slice(&u32::try_from(payload.len()).unwrap_or(0).to_be_bytes());
    frame.push(kind);
    frame.extend_from_slice(payload);
    frame
}

pub fn encode_control_frame(frame: &Value) -> Vec<u8> {
    encode_tunnel_frame(FRAME_KIND_CONTROL, frame.to_string().as_bytes())
}

pub fn encode_pty_frame(bytes: &[u8]) -> Vec<u8> {
    encode_tunnel_frame(FRAME_KIND_PTY, bytes)
}

/// Incremental frame decoder. After one failure the decoder is poisoned: a
/// length-prefixed stream that desynced once can never be trusted again, so
/// the caller must close the connection.
pub struct TunnelFrameDecoder {
    buffer: BytesMut,
    storage_capacity: usize,
    failed: bool,
    max_frame_bytes: usize,
}

impl TunnelFrameDecoder {
    pub fn new(max_frame_bytes: usize) -> TunnelFrameDecoder {
        let max_frame_bytes = max_frame_bytes.clamp(1, MAX_TUNNEL_FRAME_BYTES);
        TunnelFrameDecoder {
            storage_capacity: 0,
            buffer: BytesMut::new(),
            failed: false,
            max_frame_bytes,
        }
    }

    pub fn push(&mut self, chunk: &[u8]) -> Result<Vec<TunnelFrame>, &'static str> {
        if self.failed {
            return Err("decoder_poisoned");
        }
        self.buffer.extend_from_slice(chunk);
        self.storage_capacity = self.storage_capacity.max(self.buffer.capacity());
        let mut frames = Vec::new();
        while self.buffer.len() >= HEADER_BYTES {
            let length = u32::from_be_bytes([
                self.buffer[0],
                self.buffer[1],
                self.buffer[2],
                self.buffer[3],
            ]) as usize;
            let kind = self.buffer[4];
            if length > self.max_frame_bytes {
                self.failed = true;
                return Err("frame_too_large");
            }
            if kind != FRAME_KIND_CONTROL && kind != FRAME_KIND_PTY {
                self.failed = true;
                return Err("unknown_frame_kind");
            }
            if self.buffer.len() < HEADER_BYTES + length {
                break;
            }
            self.buffer.advance(HEADER_BYTES);
            let payload = self.buffer.split_to(length).to_vec();
            frames.push(TunnelFrame { kind, payload });
        }
        // A single read may contain many frames. Keep the retained decoder
        // storage bounded by one maximum-size frame plus its header instead
        // of holding the capacity of that whole read forever.
        let retained_limit = self.max_frame_bytes + HEADER_BYTES;
        if self.storage_capacity > retained_limit && self.buffer.len() <= retained_limit {
            let mut compacted = BytesMut::with_capacity(retained_limit);
            compacted.extend_from_slice(&self.buffer);
            self.storage_capacity = compacted.capacity();
            self.buffer = compacted;
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
pub fn generate_session_name() -> String {
    const ALPHABET: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";
    let mut bytes = [0_u8; 4];
    let _ = getrandom::fill(&mut bytes);
    let suffix: String =
        bytes.iter().map(|byte| ALPHABET[*byte as usize % ALPHABET.len()] as char).collect();
    format!("web-{suffix}")
}

// ---------------------------------------------------------------------------
// One spliced connection = one terminal attachment
// ---------------------------------------------------------------------------

enum WriterMessage {
    Frame(Vec<u8>),
    /// Flush what is queued, then close the write half.
    End,
}

/// State shared between the reader task, the writer task, and the manager's
/// synchronous reply sink.
struct Connection {
    pty_id: String,
    manager: Arc<PtyManager>,
    writer_tx: mpsc::UnboundedSender<WriterMessage>,
    /// pty_flow requests from the writer's water marks (true = pause).
    flow_tx: mpsc::UnboundedSender<bool>,
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
        self.enqueue(WriterMessage::Frame(encode_control_frame(frame)));
    }

    fn enqueue(&self, message: WriterMessage) {
        if self.finished.load(Ordering::SeqCst) {
            return;
        }
        if let WriterMessage::Frame(frame) = &message {
            self.pending_out.fetch_add(frame.len() as u64, Ordering::SeqCst);
        }
        let _ = self.writer_tx.send(message);
    }

    /// Idempotent shutdown: flush queued frames, close the socket, and let
    /// the reader task settle the owed pty_close (detach, never kill — the
    /// session lives on for a later re-attach, the same rule a dropped
    /// relay-socket viewer follows).
    fn finish(&self) {
        if self.finished.swap(true, Ordering::SeqCst) {
            return;
        }
        let _ = self.writer_tx.send(WriterMessage::End);
        self.done.cancel();
    }

    fn protocol_error(&self, code: &str, message: &str) {
        if self.finished.load(Ordering::SeqCst) {
            return;
        }
        self.send_control(&json!({ "t": "error", "code": code, "message": message }));
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
                let Some(bytes) = frame
                    .get("dataB64")
                    .and_then(Value::as_str)
                    .and_then(|b64| BASE64.decode(b64).ok())
                    .filter(|bytes| !bytes.is_empty())
                else {
                    return;
                };
                self.enqueue(WriterMessage::Frame(encode_pty_frame(&bytes)));
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
                let mut error = json!({ "t": "error", "code": code });
                if let Some(message) = frame.get("message").and_then(Value::as_str) {
                    error["message"] = Value::from(message);
                }
                self.send_control(&error);
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
        FrameContext {
            send: Arc::new(move |frame: Value| sink.on_manager_frame(&frame)),
            buffered_amount: Arc::new(move || probe.pending_out.load(Ordering::SeqCst)),
            trust: "supervised".to_owned(),
            local_roots: None,
            owner_user_id: None,
            transport_id: Some(self.pty_id.clone()),
            cancellation: self.done.clone(),
        }
    }
}

async fn handle_client_frame(
    connection: &Arc<Connection>,
    context: &FrameContext,
    frame: TunnelFrame,
) {
    if connection.finished.load(Ordering::SeqCst) {
        return;
    }
    if frame.kind == FRAME_KIND_PTY {
        if !connection.open_sent.load(Ordering::SeqCst) {
            connection.protocol_error("bad_request", "bytes before open");
            return;
        }
        let input = json!({
            "version": PTY_PROTOCOL_VERSION,
            "type": "pty_input",
            "ptyId": connection.pty_id,
            "dataB64": BASE64.encode(&frame.payload),
        });
        connection.manager.handle_frame(&input, context).await;
        return;
    }
    let Some(parsed) = parse_tunnel_client_frame(&frame.payload) else {
        connection.protocol_error("bad_request", "invalid terminal request");
        return;
    };
    match parsed {
        ClientFrame::Open { session, surface, cols, rows } => {
            if connection.open_sent.swap(true, Ordering::SeqCst) {
                connection.protocol_error("bad_request", "duplicate open");
                return;
            }
            let mut open = json!({
                "version": PTY_PROTOCOL_VERSION,
                "type": "pty_open",
                "ptyId": connection.pty_id,
                "session": session.unwrap_or_else(generate_session_name),
                "cols": cols,
                "rows": rows,
            });
            if let Some(surface) = surface {
                open["surface"] = Value::from(surface);
            }
            connection.manager.handle_frame(&open, context).await;
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
            connection.manager.handle_frame(&resize, context).await;
        }
        ClientFrame::Detach => connection.finish(),
    }
}

async fn serve_connection(stream: TcpStream, manager: Arc<PtyManager>, parent: CancellationToken) {
    let _ = stream.set_nodelay(true);
    let (mut read_half, mut write_half) = stream.into_split();
    let (writer_tx, mut writer_rx) = mpsc::unbounded_channel::<WriterMessage>();
    let (flow_tx, mut flow_rx) = mpsc::unbounded_channel::<bool>();
    let done = parent.child_token();
    let connection = Arc::new(Connection {
        pty_id: format!("tunnel-{}", random_hex(8)),
        manager: Arc::clone(&manager),
        writer_tx,
        flow_tx,
        pending_out: AtomicU64::new(0),
        paused: AtomicBool::new(false),
        open_sent: AtomicBool::new(false),
        opened_seen: AtomicBool::new(false),
        finished: AtomicBool::new(false),
        done: done.clone(),
    });
    let context = connection.frame_context();

    // Keep socket reads independent from ordered manager work. In particular,
    // a slow or stalled open must not hide peer EOF or listener cancellation.
    // The bounded channel applies backpressure to the reader without allowing
    // decoded frames to accumulate without limit.
    let (dispatch_tx, mut dispatch_rx) = mpsc::channel::<TunnelFrame>(TUNNEL_DISPATCH_QUEUE_ITEMS);
    let dispatch_connection = Arc::clone(&connection);
    let dispatch_context = context.clone();
    let dispatch_done = connection.done.clone();
    let mut dispatcher = tokio::spawn(async move {
        while let Some(frame) = dispatch_rx.recv().await {
            let operation_connection = Arc::clone(&dispatch_connection);
            let operation_context = dispatch_context.clone();
            let mut operation = tokio::spawn(async move {
                handle_client_frame(&operation_connection, &operation_context, frame).await;
            });
            tokio::select! {
                biased;
                _ = dispatch_done.cancelled() => {
                    // A dropped JoinHandle detaches the operation. Abort and
                    // join it so its cancellation-aware PTY guards reach a
                    // defined boundary before this connection returns.
                    operation.abort();
                    let _ = (&mut operation).await;
                    break;
                }
                _ = &mut operation => {}
            }
        }
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
        let context = context.clone();
        tokio::spawn(async move {
            while let Some(pause) = flow_rx.recv().await {
                if connection.finished.load(Ordering::SeqCst) {
                    break;
                }
                let frame = json!({
                    "version": PTY_PROTOCOL_VERSION,
                    "type": "pty_flow",
                    "ptyId": connection.pty_id,
                    "pause": pause,
                });
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
    'reader: loop {
        tokio::select! {
            biased;
            _ = parent.cancelled() => {
                connection.finish();
                break;
            }
            _ = connection.done.cancelled() => break,
            _ = &mut open_deadline, if !connection.opened_seen.load(Ordering::SeqCst) => {
                connection.protocol_error("bad_request", "no open frame");
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
                            tokio::select! {
                                biased;
                                _ = connection.done.cancelled() => break 'reader,
                                _ = &mut open_deadline, if !connection.opened_seen.load(Ordering::SeqCst) => {
                                    connection.protocol_error("bad_request", "open timed out");
                                    break 'reader;
                                }
                                result = dispatch_tx.send(frame) => {
                                    if result.is_err() {
                                        connection.finish();
                                        break 'reader;
                                    }
                                }
                            }
                        }
                    }
                    Err(_) => {
                        connection.protocol_error("bad_request", "malformed frame");
                        break;
                    }
                }
            }
        }
    }
    connection.finish();
    drop(dispatch_tx);
    let _ = dispatcher.await;
    // Detach, never kill: the owed close releases only this connection's
    // attachment (transport-fenced), and the session lives on.
    if connection.open_sent.load(Ordering::SeqCst) {
        let close = json!({
            "version": PTY_PROTOCOL_VERSION,
            "type": "pty_close",
            "ptyId": connection.pty_id,
        });
        manager.handle_frame(&close, &context).await;
    }
    flow.abort();
    // A peer that stopped reading can wedge the final flush forever; the
    // attachment is already released above, so cap the flush and reap.
    if tokio::time::timeout(Duration::from_secs(30), &mut writer).await.is_err() {
        writer.abort();
        let _ = writer.await;
    }
    let _ = flow.await;
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
) -> std::io::Result<(u16, tokio::task::JoinHandle<()>)> {
    let listener = TcpListener::bind((host, port)).await?;
    let bound = listener.local_addr()?.port();
    let task = tokio::spawn(async move {
        let mut connections = tokio::task::JoinSet::new();
        loop {
            let accepted = tokio::select! {
                biased;
                _ = cancellation.cancelled() => {
                    // Each connection owns its dispatcher, writer, and flow
                    // tasks. Wait for their cancellation barriers instead of
                    // dropping detached JoinHandles during listener shutdown.
                    while connections.join_next().await.is_some() {}
                    break;
                }
                Some(_) = connections.join_next(), if !connections.is_empty() => continue,
                accepted = listener.accept() => accepted,
            };
            match accepted {
                Ok((stream, _)) => {
                    let manager = Arc::clone(&manager);
                    let child = cancellation.child_token();
                    connections.spawn(serve_connection(stream, manager, child));
                }
                Err(_) => {
                    // Transient accept errors (EMFILE and friends) must not
                    // spin; the listener itself stays up.
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
        }
    });
    Ok((bound, task))
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
    use tokio::sync::Notify;

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
        spawn_gate: Option<Arc<Notify>>,
        spawn_started: Option<Arc<Notify>>,
        spawn_dropped: Option<Arc<AtomicBool>>,
        spawn_completed: Option<Arc<AtomicBool>>,
    }

    struct SpawnDrop {
        dropped: Arc<AtomicBool>,
    }

    impl Drop for SpawnDrop {
        fn drop(&mut self) {
            self.dropped.store(true, Ordering::Release);
        }
    }

    #[async_trait]
    impl PtyDeps for FakeDeps {
        async fn spawn_pty(&self, _spec: SpawnSpec) -> PtyHandle {
            let _spawn_drop =
                self.spawn_dropped.as_ref().map(|flag| SpawnDrop { dropped: Arc::clone(flag) });
            if let Some(started) = &self.spawn_started {
                started.notify_one();
            }
            if let Some(gate) = &self.spawn_gate {
                gate.notified().await;
            }
            if let Some(completed) = &self.spawn_completed {
                completed.store(true, Ordering::Release);
            }
            let pty = FakePty { state: Arc::new(StdMutex::new(FakeState::default())) };
            self.spawned.lock().unwrap().push(pty.clone());
            PtyHandle { control: Arc::new(pty.clone()), output: Arc::new(pty), banner: None }
        }
        async fn resolve_cmux_tui(&self) -> Option<CmuxTui> {
            None
        }
        async fn ensure_daemon(
            &self,
            _cmux_tui: &CmuxTui,
            _session: &str,
            _socket_dir: &Path,
            _cwd: &crate::pty::ResolvedCwd,
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
        _listener: tokio::task::JoinHandle<()>,
    }

    async fn rig_with_limits(max_ptys: usize) -> Rig {
        let spawned = Arc::new(StdMutex::new(Vec::new()));
        let deps = Arc::new(FakeDeps {
            spawned: Arc::clone(&spawned),
            spawn_gate: None,
            spawn_started: None,
            spawn_dropped: None,
            spawn_completed: None,
        });
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
        let (port, listener) = start_tunnel_terminal_listener(
            Arc::clone(&manager),
            cancel.clone(),
            TUNNEL_TERMINAL_HOST,
            0,
        )
        .await
        .expect("bind test listener");
        Rig { manager, spawned, port, cancel, _listener: listener }
    }

    async fn rig_with_blocked_spawn()
    -> (Rig, Arc<Notify>, Arc<Notify>, Arc<AtomicBool>, Arc<AtomicBool>) {
        let spawned = Arc::new(StdMutex::new(Vec::new()));
        let started = Arc::new(Notify::new());
        let gate = Arc::new(Notify::new());
        let dropped = Arc::new(AtomicBool::new(false));
        let completed = Arc::new(AtomicBool::new(false));
        let deps = Arc::new(FakeDeps {
            spawned: Arc::clone(&spawned),
            spawn_gate: Some(Arc::clone(&gate)),
            spawn_started: Some(Arc::clone(&started)),
            spawn_dropped: Some(Arc::clone(&dropped)),
            spawn_completed: Some(Arc::clone(&completed)),
        });
        let env = HashMap::from([
            ("SHELL".to_owned(), "/bin/fakesh".to_owned()),
            ("HOME".to_owned(), std::env::temp_dir().to_string_lossy().into_owned()),
        ]);
        let manager =
            Arc::new(PtyManager::with_limits(deps, std::env::temp_dir(), env, 8, 32, 1_048_576));
        let cancel = CancellationToken::new();
        let (port, listener) = start_tunnel_terminal_listener(
            Arc::clone(&manager),
            cancel.clone(),
            TUNNEL_TERMINAL_HOST,
            0,
        )
        .await
        .expect("bind test listener");
        (
            Rig { manager, spawned, port, cancel, _listener: listener },
            started,
            gate,
            dropped,
            completed,
        )
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

    // -- pure codec/parse ---------------------------------------------------

    #[test]
    fn codec_round_trips_frames_split_at_every_byte_boundary() {
        let control = encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 }));
        let pty = encode_pty_frame(b"echo hi\r");
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
    fn decoder_handles_many_frames_without_retaining_batch_storage() {
        const MAX_FRAME_BYTES: usize = 8;
        const FRAME_COUNT: usize = 2_048;

        let mut stream = Vec::with_capacity(FRAME_COUNT * (HEADER_BYTES + 1));
        for index in 0..FRAME_COUNT {
            stream.extend_from_slice(&encode_tunnel_frame(
                if index % 2 == 0 { FRAME_KIND_CONTROL } else { FRAME_KIND_PTY },
                &[index as u8],
            ));
        }

        let mut decoder = TunnelFrameDecoder::new(MAX_FRAME_BYTES);
        let frames = decoder.push(&stream).expect("clean stream");

        assert_eq!(frames.len(), FRAME_COUNT);
        assert!(frames.iter().enumerate().all(|(index, frame)| {
            frame.kind == if index % 2 == 0 { FRAME_KIND_CONTROL } else { FRAME_KIND_PTY }
                && frame.payload == [index as u8]
        }));
        assert!(decoder.buffer.is_empty());
        assert!(
            decoder.storage_capacity <= MAX_FRAME_BYTES + HEADER_BYTES,
            "decoder retained {} bytes for a {} byte max frame",
            decoder.storage_capacity,
            MAX_FRAME_BYTES
        );
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
            let name = generate_session_name();
            let suffix = name.strip_prefix("web-").expect("web- prefix");
            assert_eq!(suffix.len(), 4);
            assert!(suffix.chars().all(|c| "abcdefghjkmnpqrstuvwxyz23456789".contains(c)));
        }
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
            .write_all(&encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })))
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

        write.write_all(&encode_pty_frame(b"ls\r")).await.unwrap();
        write
            .write_all(&encode_control_frame(&json!({ "t": "resize", "cols": 132, "rows": 43 })))
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
            .write_all(&encode_control_frame(
                &json!({ "t": "open", "session": session, "cols": 80, "rows": 24 }),
            ))
            .await
            .unwrap();
        let reopened = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
        assert_eq!(reopened["t"], "opened");
        assert_eq!(reopened["created"], false);
        rig.cancel.cancel();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn parent_cancellation_closes_a_pending_open() {
        let (rig, spawn_started, gate, spawn_dropped, spawn_completed) =
            rig_with_blocked_spawn().await;
        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        write
            .write_all(&encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })))
            .await
            .unwrap();

        tokio::time::timeout(Duration::from_secs(1), spawn_started.notified())
            .await
            .expect("open reached the blocked PTY spawn");
        rig.cancel.cancel();

        tokio::time::timeout(Duration::from_secs(1), read_eof(&mut read))
            .await
            .expect("parent cancellation must close the tunnel promptly");
        gate.notify_one();
        assert!(spawn_dropped.load(Ordering::Acquire), "blocked open task must be dropped");
        assert!(
            !spawn_completed.load(Ordering::Acquire),
            "cancellation must precede spawn completion"
        );
        assert_eq!(rig.manager.opening_count(), 0, "open reservation must be released");
        assert_eq!(rig.manager.attachment_count(), 0);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn peer_eof_closes_a_pending_open() {
        let (rig, spawn_started, gate, spawn_dropped, spawn_completed) =
            rig_with_blocked_spawn().await;
        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        write
            .write_all(&encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })))
            .await
            .unwrap();

        tokio::time::timeout(Duration::from_secs(1), spawn_started.notified())
            .await
            .expect("open reached the blocked PTY spawn");
        drop(write);

        tokio::time::timeout(Duration::from_secs(1), read_eof(&mut read))
            .await
            .expect("peer EOF must close the tunnel promptly");
        gate.notify_one();
        assert!(spawn_dropped.load(Ordering::Acquire), "blocked open task must be dropped");
        assert!(!spawn_completed.load(Ordering::Acquire), "peer EOF must precede spawn completion");
        assert_eq!(rig.manager.opening_count(), 0, "open reservation must be released");
        assert_eq!(rig.manager.attachment_count(), 0);
        rig.cancel.cancel();
    }

    #[tokio::test]
    async fn bytes_before_open_are_a_protocol_error() {
        let rig = rig().await;
        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        write.write_all(&encode_pty_frame(b"sneaky")).await.unwrap();
        let mut decoder = TunnelFrameDecoder::new(MAX_TUNNEL_FRAME_BYTES);
        let mut queue = Vec::new();
        let error = control_json(&next_frame(&mut read, &mut decoder, &mut queue).await);
        assert_eq!(error["t"], "error");
        assert_eq!(error["code"], "bad_request");
        read_eof(&mut read).await;
        rig.cancel.cancel();
    }

    #[tokio::test]
    async fn duplicate_open_is_a_protocol_error() {
        let rig = rig().await;
        let stream = connect(&rig).await;
        let (mut read, mut write) = stream.into_split();
        let open = encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 }));
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
        write.write_all(&encode_tunnel_frame(FRAME_KIND_CONTROL, b"{not json")).await.unwrap();
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
            .write_all(&encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })))
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
            .write_all(&encode_control_frame(&json!({ "t": "open", "cols": 80, "rows": 24 })))
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
}
