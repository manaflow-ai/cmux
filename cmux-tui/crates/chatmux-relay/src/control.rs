//! cmux-tui control socket client (JSON Lines over the session's unix
//! socket, cmux-tui docs/protocol.md). Behavior port of the JS relay's
//! `defaultConnectControl` (`packages/relay/bin/pty.mjs`): every failure
//! mode resolves requests with `None` instead of erroring (callers
//! feature-detect); torn lines never kill the attachment; `pause` stops
//! reading so PTY backpressure applies naturally.

use serde_json::Value;

/// Per-request budget on a cmux-tui control connection.
pub const CONTROL_TIMEOUT_MS: u64 = 3_000;
const MAX_CONTROL_LINE_BYTES: usize = 1_048_576;
const MAX_WRITER_QUEUE: usize = 256;
const MAX_PENDING_REQUESTS: usize = 256;

pub type EventHandler = Box<dyn Fn(&Value) + Send + Sync>;
pub type CloseHandler = Box<dyn Fn() + Send + Sync>;

/// One control connection to a cmux-tui session socket. The trait exists so
/// the PTY manager's unit tests can inject a scripted control plane, exactly
/// like the JS test harness does.
pub trait ControlHandle: Send + Sync {
    /// Round-trip one command; `None` on timeout, close, or write failure.
    fn request(
        &self,
        cmd: &str,
        params: Value,
    ) -> std::pin::Pin<Box<dyn Future<Output = Option<Value>> + Send + '_>>;
    /// Fire-and-forget (input/resize hot paths); the response line drops.
    fn send(&self, cmd: &str, params: Value);
    fn on_event(&self, handler: EventHandler);
    /// Fires on unexpected close only (not after `end()`).
    fn on_close(&self, handler: CloseHandler);
    fn pause(&self);
    fn resume(&self);
    fn end(&self);
}

#[cfg(unix)]
pub use unix::connect_control;

#[cfg(unix)]
mod unix {
    use super::*;
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    use tokio::net::UnixStream;
    use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
    use tokio::sync::mpsc::{self, Receiver, Sender};
    use tokio::sync::{Mutex as AsyncMutex, Notify, oneshot};

    struct OutboundLine {
        bytes: Vec<u8>,
        // Requests wait for this acknowledgement. Fire-and-forget sends
        // leave it empty, but still use the same FIFO writer queue.
        written: Option<oneshot::Sender<bool>>,
    }

    struct Shared {
        pending: Mutex<HashMap<u64, oneshot::Sender<Value>>>,
        event_handler: Mutex<Option<EventHandler>>,
        close_handler: Mutex<Option<CloseHandler>>,
        closed: AtomicBool,
        deliberate: AtomicBool,
        paused: AtomicBool,
        resume_notify: Notify,
        closed_notify: Notify,
    }

    impl Shared {
        fn settle_closed(&self) {
            if self.closed.swap(true, Ordering::SeqCst) {
                return;
            }
            // Resolve every pending request with "no reply".
            self.pending.lock().expect("control pending lock").clear();
            // Both the writer and a paused reader wait on this state. Keep a
            // broadcast wakeup so either task can observe closure without
            // consuming the other's permit.
            self.closed_notify.notify_waiters();
            if !self.deliberate.load(Ordering::SeqCst)
                && let Some(handler) =
                    self.close_handler.lock().expect("control close lock").as_ref()
            {
                handler();
            }
        }
    }

    pub struct UnixControl {
        shared: Arc<Shared>,
        writer_tx: Sender<OutboundLine>,
        /// A duplicate of the stream's descriptor, owned here, so `end()`
        /// shuts the socket down even after both halves dropped and never
        /// touches a descriptor number another resource reused. `end()` also
        /// closes it: on macOS the daemon's blocking read can miss the wake of
        /// a shutdown while the relay keeps any descriptor of the socket.
        shutdown_fd: Mutex<Option<std::os::fd::OwnedFd>>,
        next_id: AtomicU64,
        timeout_ms: u64,
    }

    /// Connect a JSON-lines control client to a cmux-tui session socket.
    pub async fn connect_control(
        socket_path: &std::path::Path,
        timeout_ms: u64,
    ) -> Result<Arc<dyn ControlHandle>, String> {
        Ok(connect_control_inner(socket_path, timeout_ms).await?)
    }

    async fn connect_control_inner(
        socket_path: &std::path::Path,
        timeout_ms: u64,
    ) -> Result<Arc<UnixControl>, String> {
        // SAFETY: getuid is always safe.
        connect_control_as(socket_path, timeout_ms, unsafe { libc::getuid() }).await
    }

    /// Connect to a session socket served by `expected_uid`.
    async fn connect_control_as(
        socket_path: &std::path::Path,
        timeout_ms: u64,
        expected_uid: u32,
    ) -> Result<Arc<UnixControl>, String> {
        let connect = UnixStream::connect(socket_path);
        let stream = tokio::time::timeout(Duration::from_millis(timeout_ms), connect)
            .await
            .map_err(|_| format!("cmux-tui control connect timed out ({})", socket_path.display()))?
            .map_err(|error| error.to_string())?;
        require_peer_uid(&stream, expected_uid)?;
        let shutdown_fd = {
            use std::os::fd::AsFd as _;
            stream
                .as_fd()
                .try_clone_to_owned()
                .map_err(|error| format!("cmux-tui control descriptor: {error}"))?
        };
        let (read_half, write_half) = stream.into_split();
        let shared = Arc::new(Shared {
            pending: Mutex::new(HashMap::new()),
            event_handler: Mutex::new(None),
            close_handler: Mutex::new(None),
            closed: AtomicBool::new(false),
            deliberate: AtomicBool::new(false),
            paused: AtomicBool::new(false),
            resume_notify: Notify::new(),
            closed_notify: Notify::new(),
        });
        // Keep one async writer for every connection. The queue makes the
        // synchronous `send` API safe without spawning one task per input;
        // `write_all` below waits for socket backpressure and never exposes a
        // partial JSON line to the peer.
        let writer = Arc::new(AsyncMutex::new(write_half));
        let (writer_tx, writer_rx) = mpsc::channel(MAX_WRITER_QUEUE);
        tokio::spawn(write_loop(writer, writer_rx, Arc::clone(&shared)));
        tokio::spawn(read_loop(read_half, Arc::clone(&shared)));
        Ok(Arc::new(UnixControl {
            shared,
            writer_tx,
            shutdown_fd: Mutex::new(Some(shutdown_fd)),
            next_id: AtomicU64::new(1),
            timeout_ms,
        }))
    }

    /// Session sockets can live in shared fallback directories, so check who
    /// serves one before sending anything on it.
    fn require_peer_uid(stream: &UnixStream, expected_uid: u32) -> Result<(), String> {
        let peer_uid = stream
            .peer_cred()
            .map_err(|error| format!("cmux-tui control peer check failed: {error}"))?
            .uid();
        if peer_uid == expected_uid {
            Ok(())
        } else {
            Err(format!(
                "cmux-tui control socket is served by uid {peer_uid}, not uid {expected_uid}"
            ))
        }
    }

    async fn write_loop(
        writer: Arc<AsyncMutex<OwnedWriteHalf>>,
        mut receiver: Receiver<OutboundLine>,
        shared: Arc<Shared>,
    ) {
        loop {
            let closed = shared.closed_notify.notified();
            tokio::pin!(closed);
            closed.as_mut().enable();
            if shared.closed.load(Ordering::SeqCst) {
                break;
            }
            let next_line = tokio::select! {
                line = receiver.recv() => line,
                _ = closed => None,
            };
            let Some(line) = next_line else {
                break;
            };
            if shared.closed.load(Ordering::SeqCst) {
                if let Some(written) = line.written {
                    let _ = written.send(false);
                }
                continue;
            }
            let result = {
                let mut writer = writer.lock().await;
                writer.write_all(&line.bytes).await
            };
            let succeeded = result.is_ok();
            if let Some(written) = line.written {
                let _ = written.send(succeeded);
            }
            if result.is_err() {
                shared.settle_closed();
                break;
            }
        }
        // Resolve queued request acknowledgements when the writer exits. This
        // makes shutdown cancellation prompt instead of waiting for each
        // request timeout while preserving FIFO correlation for delivered lines.
        while let Ok(line) = receiver.try_recv() {
            if let Some(written) = line.written {
                let _ = written.send(false);
            }
        }
    }

    async fn read_loop(mut reader: OwnedReadHalf, shared: Arc<Shared>) {
        let mut buffer: Vec<u8> = Vec::new();
        let mut chunk = [0_u8; 16_384];
        'read_loop: loop {
            // Create the waiter before checking the flag. `Notify` retains a
            // permit when resume races this check, so a pause cannot leave
            // the reader asleep after the wakeup.
            loop {
                let resumed = shared.resume_notify.notified();
                let closed = shared.closed_notify.notified();
                tokio::pin!(closed);
                closed.as_mut().enable();
                if shared.closed.load(Ordering::SeqCst) {
                    break 'read_loop;
                }
                if !shared.paused.load(Ordering::SeqCst) {
                    break;
                }
                tokio::select! {
                    _ = resumed => {}
                    _ = closed => break 'read_loop,
                }
            }
            let count = match reader.read(&mut chunk).await {
                Ok(0) | Err(_) => break,
                Ok(count) => count,
            };
            buffer.extend_from_slice(&chunk[..count]);
            if buffer.len() > MAX_CONTROL_LINE_BYTES {
                // A peer that withholds a newline must not grow relay memory.
                break;
            }
            while let Some(newline) = buffer.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = buffer.drain(..=newline).collect();
                let Ok(text) = std::str::from_utf8(&line[..line.len() - 1]) else { continue };
                if text.trim().is_empty() {
                    continue;
                }
                // A torn or non-JSON line must not kill the attachment.
                let Ok(parsed) = serde_json::from_str::<Value>(text) else { continue };
                if !parsed.is_object() {
                    continue;
                }
                let id = parsed.get("id").and_then(Value::as_u64);
                let waiting = id.and_then(|id| {
                    shared.pending.lock().expect("control pending lock").remove(&id)
                });
                if let Some(sender) = waiting {
                    let _ = sender.send(parsed);
                } else if parsed.get("event").and_then(Value::as_str).is_some()
                    && let Some(handler) =
                        shared.event_handler.lock().expect("control event lock").as_ref()
                {
                    handler(&parsed);
                }
                // Responses to fire-and-forget sends fall through silently.
            }
        }
        shared.settle_closed();
    }

    impl UnixControl {
        fn encode_line(id: u64, cmd: &str, params: Value) -> Vec<u8> {
            let mut frame = match params {
                Value::Object(map) => map,
                _ => serde_json::Map::new(),
            };
            frame.insert("id".to_owned(), Value::from(id));
            frame.insert("cmd".to_owned(), Value::from(cmd));
            let mut line = Value::Object(frame).to_string();
            line.push('\n');
            line.into_bytes()
        }

        fn enqueue_line(
            &self,
            id: u64,
            cmd: &str,
            params: Value,
            written: Option<oneshot::Sender<bool>>,
        ) -> bool {
            self.writer_tx
                .try_send(OutboundLine { bytes: Self::encode_line(id, cmd, params), written })
                .is_ok()
        }
    }

    impl ControlHandle for UnixControl {
        fn request(
            &self,
            cmd: &str,
            params: Value,
        ) -> std::pin::Pin<Box<dyn Future<Output = Option<Value>> + Send + '_>> {
            let cmd = cmd.to_owned();
            Box::pin(async move {
                if self.shared.closed.load(Ordering::SeqCst) {
                    return None;
                }
                let id = self.next_id.fetch_add(1, Ordering::SeqCst);
                let (sender, receiver) = oneshot::channel();
                {
                    let mut pending = self.shared.pending.lock().expect("control pending lock");
                    if pending.len() >= MAX_PENDING_REQUESTS {
                        return None;
                    }
                    pending.insert(id, sender);
                }
                let deadline = tokio::time::Instant::now() + Duration::from_millis(self.timeout_ms);
                let (written, write_result) = oneshot::channel();
                if !self.enqueue_line(id, &cmd, params, Some(written)) {
                    self.shared.pending.lock().expect("control pending lock").remove(&id);
                    return None;
                }
                let write_ok =
                    matches!(tokio::time::timeout_at(deadline, write_result).await, Ok(Ok(true)));
                if !write_ok {
                    self.shared.pending.lock().expect("control pending lock").remove(&id);
                    return None;
                }
                if let Ok(Ok(value)) = tokio::time::timeout_at(deadline, receiver).await {
                    Some(value)
                } else {
                    self.shared.pending.lock().expect("control pending lock").remove(&id);
                    None
                }
            })
        }

        fn send(&self, cmd: &str, params: Value) {
            if self.shared.closed.load(Ordering::SeqCst) {
                return;
            }
            let id = self.next_id.fetch_add(1, Ordering::SeqCst);
            let _ = self.enqueue_line(id, cmd, params, None);
        }

        fn on_event(&self, handler: EventHandler) {
            *self.shared.event_handler.lock().expect("control event lock") = Some(handler);
        }

        fn on_close(&self, handler: CloseHandler) {
            *self.shared.close_handler.lock().expect("control close lock") = Some(handler);
        }

        fn pause(&self) {
            self.shared.paused.store(true, Ordering::SeqCst);
        }

        fn resume(&self) {
            self.shared.paused.store(false, Ordering::SeqCst);
            self.shared.resume_notify.notify_waiters();
        }

        fn end(&self) {
            self.shared.deliberate.store(true, Ordering::SeqCst);
            self.shared.settle_closed();
            // Shut both directions so the read loop sees EOF and any blocked
            // writer unblocks. shutdown acts on the socket, so the owned
            // duplicate reaches it; a socket already shut down is harmless.
            let shutdown_fd = match self.shutdown_fd.lock() {
                Ok(mut shutdown_fd) => shutdown_fd.take(),
                Err(poisoned) => poisoned.into_inner().take(),
            };
            if let Some(shutdown_fd) = shutdown_fd {
                // SAFETY: shutdown on a descriptor this handle owns.
                unsafe {
                    use std::os::fd::AsRawFd as _;
                    libc::shutdown(shutdown_fd.as_raw_fd(), libc::SHUT_RDWR);
                }
                drop(shutdown_fd);
            }
        }
    }
}

#[cfg(all(test, unix))]
mod tests;
