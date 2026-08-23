//! cmux-tui control socket client (JSON Lines over the session's unix
//! socket, cmux-tui docs/protocol.md). Behavior port of the JS relay's
//! `defaultConnectControl` (`packages/relay/bin/pty.mjs`): every failure
//! mode resolves requests with `None` instead of erroring (callers
//! feature-detect); torn lines never kill the attachment; `pause` stops
//! reading so PTY backpressure applies naturally.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::Value;

/// Per-request budget on a cmux-tui control connection.
pub const CONTROL_TIMEOUT_MS: u64 = 3_000;
const MAX_CONTROL_LINE_BYTES: usize = 1_048_576;

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
    use tokio::io::AsyncReadExt as _;
    use tokio::net::UnixStream;
    use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
    use tokio::sync::{Notify, oneshot};

    struct Shared {
        pending: Mutex<HashMap<u64, oneshot::Sender<Value>>>,
        event_handler: Mutex<Option<EventHandler>>,
        close_handler: Mutex<Option<CloseHandler>>,
        closed: AtomicBool,
        deliberate: AtomicBool,
        paused: AtomicBool,
        resume_notify: Notify,
    }

    impl Shared {
        fn settle_closed(&self) {
            if self.closed.swap(true, Ordering::SeqCst) {
                return;
            }
            // Resolve every pending request with "no reply".
            self.pending.lock().expect("control pending lock").clear();
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
        writer: Mutex<OwnedWriteHalf>,
        raw_fd: std::os::fd::RawFd,
        next_id: AtomicU64,
        timeout_ms: u64,
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
        });
        tokio::spawn(read_loop(read_half, Arc::clone(&shared)));
        Ok(Arc::new(UnixControl {
            shared,
            writer: Mutex::new(write_half),
            raw_fd,
            next_id: AtomicU64::new(1),
            timeout_ms,
        }))
    }

    async fn read_loop(mut reader: OwnedReadHalf, shared: Arc<Shared>) {
        let mut buffer: Vec<u8> = Vec::new();
        let mut chunk = [0_u8; 16_384];
        loop {
            while shared.paused.load(Ordering::SeqCst) {
                shared.resume_notify.notified().await;
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
        fn write_line(&self, id: u64, cmd: &str, params: Value) -> bool {
            let mut frame = match params {
                Value::Object(map) => map,
                _ => serde_json::Map::new(),
            };
            frame.insert("id".to_owned(), Value::from(id));
            frame.insert("cmd".to_owned(), Value::from(cmd));
            let mut line = Value::Object(frame).to_string();
            line.push('\n');
            let writer = self.writer.lock().expect("control writer lock");
            // try_write on the owned half: control lines are tiny and the
            // socket buffer absorbs them; a full buffer reads as a failure
            // (the JS write() try/catch equivalent).
            writer.try_write(line.as_bytes()).is_ok()
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
                self.shared.pending.lock().expect("control pending lock").insert(id, sender);
                if !self.write_line(id, &cmd, params) {
                    self.shared.pending.lock().expect("control pending lock").remove(&id);
                    return None;
                }
                match tokio::time::timeout(Duration::from_millis(self.timeout_ms), receiver).await {
                    Ok(Ok(value)) => Some(value),
                    _ => {
                        self.shared.pending.lock().expect("control pending lock").remove(&id);
                        None
                    }
                }
            })
        }

        fn send(&self, cmd: &str, params: Value) {
            if self.shared.closed.load(Ordering::SeqCst) {
                return;
            }
            let id = self.next_id.fetch_add(1, Ordering::SeqCst);
            let _ = self.write_line(id, cmd, params);
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
            // writer unblocks; the halves drop and close the fd afterwards.
            // SAFETY: shutdown on a socket fd this handle owns for the split
            // stream's lifetime; a failure (already closed) is harmless.
            unsafe {
                libc::shutdown(self.raw_fd, libc::SHUT_RDWR);
            }
        }
    }
}
