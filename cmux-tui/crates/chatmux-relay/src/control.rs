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
    /// Send one mutating command and wait for an ordered daemon barrier before
    /// allowing the next session command. The default is for deterministic
    /// test controls; UnixControl overrides it with a FIFO `identify` reply.
    fn ordered_send(
        &self,
        cmd: &str,
        params: Value,
    ) -> std::pin::Pin<Box<dyn Future<Output = bool> + Send + '_>> {
        self.send(cmd, params);
        Box::pin(std::future::ready(true))
    }
    fn on_event(&self, handler: EventHandler);
    /// Fires on unexpected close only (not after `end()`).
    fn on_close(&self, handler: CloseHandler);
    fn pause(&self);
    fn resume(&self);
    fn end(&self);
    /// Close this transport only after the daemon has observed all commands
    /// already queued on it. Test controls and older transports that have no
    /// acknowledgement primitive may return `true` immediately; the Unix
    /// implementation overrides this with an ordered `identify` barrier.
    fn end_and_wait(&self) -> std::pin::Pin<Box<dyn Future<Output = bool> + Send + '_>> {
        self.end();
        Box::pin(std::future::ready(true))
    }
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
        /// Set only after the read half observes the peer's EOF/error. This
        /// is separate from `closed`, which is set immediately for deliberate
        /// local shutdown and therefore cannot prove peer observation.
        peer_closed: AtomicBool,
        peer_closed_notify: Notify,
    }

    impl Shared {
        fn settle_closed(&self) {
            if self.closed.swap(true, Ordering::SeqCst) {
                return;
            }
            // Resolve every pending request with "no reply".
            self.pending.lock().expect("control pending lock").clear();
            self.closed_notify.notify_one();
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
        raw_fd: std::os::fd::RawFd,
        next_id: AtomicU64,
        timeout_ms: u64,
        ended: AtomicBool,
        barrier_completed: AtomicBool,
    }

    /// Connect a JSON-lines control client to a cmux-tui session socket.
    pub async fn connect_control(
        socket_path: &std::path::Path,
        timeout_ms: u64,
    ) -> Result<Arc<dyn ControlHandle>, String> {
        let connect = UnixStream::connect(socket_path);
        let stream = tokio::time::timeout(Duration::from_millis(timeout_ms), connect)
            .await
            .map_err(|_| format!("cmux-tui control connect timed out ({})", socket_path.display()))?
            .map_err(|error| error.to_string())?;
        let raw_fd = {
            use std::os::fd::AsRawFd as _;
            stream.as_raw_fd()
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
            peer_closed: AtomicBool::new(false),
            peer_closed_notify: Notify::new(),
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
            raw_fd,
            next_id: AtomicU64::new(1),
            timeout_ms,
            ended: AtomicBool::new(false),
            barrier_completed: AtomicBool::new(false),
        }))
    }

    async fn write_loop(
        writer: Arc<AsyncMutex<OwnedWriteHalf>>,
        mut receiver: Receiver<OutboundLine>,
        shared: Arc<Shared>,
    ) {
        loop {
            let closed = shared.closed_notify.notified();
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
            let result = {
                let mut writer = writer.lock().await;
                // Re-check only after acquiring the writer lock. `end()` can
                // close the shared state while this task is waiting for a
                // previous write; checking before the lock allowed a stale
                // line to pass that check and be written after teardown.
                if shared.closed.load(Ordering::SeqCst) {
                    Err(std::io::Error::new(
                        std::io::ErrorKind::BrokenPipe,
                        "control writer closed",
                    ))
                } else {
                    writer.write_all(&line.bytes).await
                }
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
        loop {
            // Create the waiter before checking the flag. `Notify` retains a
            // permit when resume races this check, so a pause cannot leave
            // the reader asleep after the wakeup.
            loop {
                let notified = shared.resume_notify.notified();
                if !shared.paused.load(Ordering::SeqCst) {
                    break;
                }
                notified.await;
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
        shared.peer_closed.store(true, Ordering::SeqCst);
        shared.peer_closed_notify.notify_waiters();
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

        fn ordered_send(
            &self,
            cmd: &str,
            params: Value,
        ) -> std::pin::Pin<Box<dyn Future<Output = bool> + Send + '_>> {
            let cmd = cmd.to_owned();
            Box::pin(async move {
                if self.shared.closed.load(Ordering::Acquire) {
                    return false;
                }
                let id = self.next_id.fetch_add(1, Ordering::SeqCst);
                if !self.enqueue_line(id, &cmd, params, None) {
                    return false;
                }
                // JSON-lines requests are processed in read order by the
                // daemon. The identify reply therefore acknowledges this
                // command and every earlier command on this socket.
                tokio::time::timeout(
                    Duration::from_millis(self.timeout_ms),
                    self.request("identify", serde_json::json!({})),
                )
                .await
                .ok()
                .flatten()
                .is_some_and(|response| response.get("ok").and_then(Value::as_bool) == Some(true))
            })
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
            if self.ended.swap(true, Ordering::SeqCst) {
                return;
            }
            self.shared.deliberate.store(true, Ordering::SeqCst);
            self.shared.settle_closed();
            // Shut both directions so the read loop sees EOF and any blocked
            // writer unblocks; the halves drop and close the fd afterwards.
            // SAFETY: shutdown on a socket fd this handle owns for the split
            // stream's lifetime; a failure (already closed) is harmless.
            unsafe {
                libc::shutdown(self.raw_fd, libc::SHUT_RDWR);
            }
        }

        fn end_and_wait(&self) -> std::pin::Pin<Box<dyn Future<Output = bool> + Send + '_>> {
            Box::pin(async move {
                if self.barrier_completed.load(Ordering::Acquire) {
                    return true;
                }
                if self.shared.closed.load(Ordering::Acquire) {
                    return false;
                }
                // `identify` is side-effect free and is ordered behind all
                // earlier control commands on this JSON-lines connection.
                // Its response is the daemon-observed close barrier. If the
                // transport is already closed, no new claim may be admitted.
                let barrier = tokio::time::timeout(
                    Duration::from_millis(self.timeout_ms),
                    self.request("identify", serde_json::json!({})),
                )
                .await
                .ok()
                .flatten()
                .is_some_and(|response| response.get("ok").and_then(Value::as_bool) == Some(true));
                if !barrier {
                    self.end();
                    return false;
                }
                self.barrier_completed.store(true, Ordering::Release);
                self.end();
                // The identify response is the daemon-observed barrier. Do
                // not wait for peer EOF after local shutdown: EOF ordering is
                // transport-dependent and cannot strengthen the protocol
                // guarantee.
                true
            })
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _};
    use tokio::net::UnixListener;
    use tokio::sync::oneshot;

    #[tokio::test]
    async fn writer_queue_preserves_complete_fifo_lines() {
        let socket_path =
            std::env::temp_dir().join(format!("chatmux-relay-control-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path).expect("bind control test socket");
        let (accepted_tx, accepted_rx) = oneshot::channel();
        let (release_tx, release_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("accept control test socket");
            let (read_half, mut write_half) = stream.into_split();
            accepted_tx.send(()).expect("tell client that socket is accepted");
            // Hold the reader while the client queues several large lines.
            // This exercises the writer's backpressure path without relying
            // on a platform-specific socket buffer size.
            release_rx.await.expect("release control test reader");
            let mut reader = tokio::io::BufReader::new(read_half);
            let mut lines = Vec::new();
            for _ in 0..9 {
                let mut line = String::new();
                reader.read_line(&mut line).await.expect("read control line");
                lines.push(line);
            }
            let request: Value =
                serde_json::from_str(lines[8].trim_end()).expect("decode request line");
            let id = request.get("id").and_then(Value::as_u64).expect("request id");
            let response = format!("{{\"id\":{id},\"ok\":true}}\n");
            write_half.write_all(response.as_bytes()).await.expect("write response line");
            lines
        });

        let control =
            connect_control(&socket_path, 3_000).await.expect("connect control test socket");
        accepted_rx.await.expect("wait for control test server");
        let payload = "x".repeat(128 * 1024);
        for index in 0..8 {
            control.send("send", json!({ "index": index, "payload": payload.clone() }));
        }
        release_tx.send(()).expect("release control test reader");
        let response = control.request("probe", json!({})).await;
        assert_eq!(response.and_then(|value| value.get("ok").and_then(Value::as_bool)), Some(true));

        let lines = server.await.expect("join control test server");
        assert!(lines.iter().all(|line| line.ends_with('\n')));
        for (index, line) in lines.iter().take(8).enumerate() {
            let value: Value = serde_json::from_str(line.trim_end()).expect("decode send line");
            assert_eq!(value.get("cmd").and_then(Value::as_str), Some("send"));
            assert_eq!(value.get("index").and_then(Value::as_u64), Some(index as u64));
            assert_eq!(
                value.get("payload").and_then(Value::as_str).map(str::len),
                Some(128 * 1024)
            );
        }
        let request: Value = serde_json::from_str(lines[8].trim_end()).expect("decode probe line");
        assert_eq!(request.get("cmd").and_then(Value::as_str), Some("probe"));

        control.end();
        let _ = std::fs::remove_file(socket_path);
    }
}
