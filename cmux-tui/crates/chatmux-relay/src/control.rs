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
const MAX_EVENT_QUEUE: usize = 1_024;
// Keep the per-line parser cap separate from the total event budget. A short
// burst of large events must not consume the entire queue after one frame.
const MAX_EVENT_QUEUE_BYTES: usize = 4 * MAX_CONTROL_LINE_BYTES;

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
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
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
        event_handler: Mutex<Option<Arc<dyn Fn(&Value) + Send + Sync>>>,
        close_handler: Mutex<Option<CloseHandler>>,
        closed: AtomicBool,
        deliberate: AtomicBool,
        paused: AtomicBool,
        resume_notify: Notify,
        closed_notify: Notify,
        #[cfg(test)]
        read_done: Notify,
        #[cfg(test)]
        read_waiting: Mutex<Option<oneshot::Sender<()>>>,
        dispatch_tx: std::sync::mpsc::SyncSender<Dispatch>,
        close_signal_tx: std::sync::mpsc::SyncSender<()>,
        queued_event_bytes: AtomicUsize,
        worker_done: AtomicBool,
    }

    enum Dispatch {
        Event { value: Value, bytes: usize },
        Closed,
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
            // Serialize marker enqueue with on_close registration. The event
            // worker may receive the marker immediately, so the handler must
            // be either installed before enqueue or installed by on_close
            // while the worker waits on this same mutex.
            let _close_handler = self.close_handler.lock().expect("control close lock");
            let _ = self.dispatch_tx.try_send(Dispatch::Closed);
            // Keep closure delivery independent from the bounded event FIFO.
            // The event queue may be full while the worker is in a callback.
            let _ = self.close_signal_tx.try_send(());
        }

        fn reserve_event_bytes(&self, bytes: usize) -> bool {
            if bytes > MAX_EVENT_QUEUE_BYTES {
                return false;
            }
            let mut current = self.queued_event_bytes.load(Ordering::Acquire);
            loop {
                let Some(next) = current.checked_add(bytes) else { return false };
                if next > MAX_EVENT_QUEUE_BYTES {
                    return false;
                }
                match self.queued_event_bytes.compare_exchange_weak(
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

        fn release_event_bytes(&self, bytes: usize) -> bool {
            let mut current = self.queued_event_bytes.load(Ordering::Acquire);
            loop {
                let Some(next) = current.checked_sub(bytes) else { return false };
                match self.queued_event_bytes.compare_exchange_weak(
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

        fn finish_worker(&self) {
            self.worker_done.store(true, Ordering::Release);
        }
    }

    pub struct UnixControl {
        shared: Arc<Shared>,
        writer_tx: Sender<OutboundLine>,
        raw_fd: std::os::fd::RawFd,
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
        let (dispatch_tx, dispatch_rx) = std::sync::mpsc::sync_channel(MAX_EVENT_QUEUE);
        let (close_signal_tx, close_signal_rx) = std::sync::mpsc::sync_channel(1);
        let shared = Arc::new(Shared {
            pending: Mutex::new(HashMap::new()),
            event_handler: Mutex::new(None),
            close_handler: Mutex::new(None),
            closed: AtomicBool::new(false),
            deliberate: AtomicBool::new(false),
            paused: AtomicBool::new(false),
            resume_notify: Notify::new(),
            closed_notify: Notify::new(),
            #[cfg(test)]
            read_done: Notify::new(),
            #[cfg(test)]
            read_waiting: Mutex::new(None),
            dispatch_tx,
            close_signal_tx,
            queued_event_bytes: AtomicUsize::new(0),
            worker_done: AtomicBool::new(false),
        });
        let worker_shared = Arc::clone(&shared);
        std::thread::Builder::new()
            .name("chatmux-relay-control-events".to_owned())
            .spawn(move || {
                let shared = worker_shared;
                let deliver_event = |shared: &Arc<Shared>, event: Value, bytes: usize| {
                    if !shared.release_event_bytes(bytes) {
                        shared.settle_closed();
                        return false;
                    }
                    let handler = shared.event_handler.lock().expect("control event lock").clone();
                    if let Some(handler) = handler {
                        handler(&event);
                    }
                    true
                };
                let invoke_close = |shared: &Arc<Shared>| {
                    if !shared.deliberate.load(Ordering::SeqCst) {
                        let handler =
                            shared.close_handler.lock().expect("control close lock").take();
                        if let Some(handler) = handler {
                            handler();
                        }
                    }
                };
                loop {
                    let dispatch = match dispatch_rx.recv_timeout(Duration::from_millis(50)) {
                        Ok(dispatch) => dispatch,
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                            if shared.closed.load(Ordering::SeqCst) {
                                Dispatch::Closed
                            } else {
                                continue;
                            }
                        }
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    };
                    match dispatch {
                        Dispatch::Event { value: event, bytes } => {
                            if !deliver_event(&shared, event, bytes) {
                                invoke_close(&shared);
                                break;
                            }
                        }
                        Dispatch::Closed => {
                            while let Ok(Dispatch::Event { value: event, bytes }) =
                                dispatch_rx.try_recv()
                            {
                                if !deliver_event(&shared, event, bytes) {
                                    break;
                                }
                            }
                            invoke_close(&shared);
                            break;
                        }
                    }
                    // A close signal has its own one-slot channel, so it
                    // cannot be lost when the event FIFO is full. Drain all
                    // events accepted before EOF, then invoke close once.
                    if close_signal_rx.try_recv().is_ok() || shared.closed.load(Ordering::SeqCst) {
                        while let Ok(Dispatch::Event { value: event, bytes }) =
                            dispatch_rx.try_recv()
                        {
                            if !deliver_event(&shared, event, bytes) {
                                break;
                            }
                        }
                        invoke_close(&shared);
                        break;
                    }
                }
                shared.finish_worker();
            })
            .expect("spawn control event worker");
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
        }))
    }

    #[cfg(test)]
    pub(crate) async fn connect_control_for_test(
        socket_path: &std::path::Path,
        timeout_ms: u64,
    ) -> Result<Arc<UnixControl>, String> {
        connect_control_inner(socket_path, timeout_ms).await
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
                #[cfg(test)]
                if let Some(waiting) =
                    shared.read_waiting.lock().expect("control read waiter lock").take()
                {
                    let _ = waiting.send(());
                }
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
                } else if parsed.get("event").and_then(Value::as_str).is_some() {
                    let bytes = line.len();
                    if !shared.reserve_event_bytes(bytes) {
                        shared.settle_closed();
                        break 'read_loop;
                    }
                    if shared
                        .dispatch_tx
                        .try_send(Dispatch::Event { value: parsed, bytes })
                        .is_err()
                    {
                        let _ = shared.release_event_bytes(bytes);
                        shared.settle_closed();
                        break 'read_loop;
                    }
                }
                // Responses to fire-and-forget sends fall through silently.
            }
        }
        shared.settle_closed();
        #[cfg(test)]
        shared.read_done.notify_waiters();
    }

    impl UnixControl {
        #[cfg(test)]
        pub(crate) async fn wait_reader_done(&self) {
            self.shared.read_done.notified().await;
        }

        #[cfg(test)]
        pub(crate) fn arm_reader_waiting(&self) -> oneshot::Receiver<()> {
            let (sender, receiver) = oneshot::channel();
            *self.shared.read_waiting.lock().expect("control read waiter lock") = Some(sender);
            receiver
        }

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
            *self.shared.event_handler.lock().expect("control event lock") =
                Some(Arc::from(handler));
        }

        fn on_close(&self, handler: CloseHandler) {
            let mut slot = self.shared.close_handler.lock().expect("control close lock");
            if self.shared.closed.load(Ordering::SeqCst) {
                if self.shared.deliberate.load(Ordering::SeqCst) {
                    return;
                }
                if !self.shared.worker_done.load(Ordering::Acquire) {
                    *slot = Some(handler);
                    return;
                }
                drop(slot);
                handler();
            } else {
                *slot = Some(handler);
            }
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

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;
    use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _, AsyncWriteExt as _};
    use tokio::net::UnixListener;
    use tokio::sync::{Notify, oneshot};

    #[tokio::test]
    async fn end_wakes_paused_reader_and_closes_socket() {
        let socket_path = std::env::temp_dir()
            .join(format!("chatmux-relay-control-close-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path).expect("bind control close test socket");
        let (accepted_tx, accepted_rx) = oneshot::channel();
        let (paused_tx, paused_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("accept control close test socket");
            let (mut read_half, mut write_half) = stream.into_split();
            accepted_tx.send(()).expect("tell client that socket is accepted");
            paused_rx.await.expect("wait for client pause");
            write_half.write_all(b"{}\n").await.expect("wake paused reader");
            let mut bytes = Vec::new();
            read_half.read_to_end(&mut bytes).await.expect("read client close");
        });

        let control = unix::connect_control_for_test(&socket_path, 3_000)
            .await
            .expect("connect control close test socket");
        accepted_rx.await.expect("wait for control close test server");
        control.pause();

        // Register both waiters before end() so the test deterministically
        // exercises the paused-reader branch and the close wakeup.
        let read_waiting = control.arm_reader_waiting();
        paused_tx.send(()).expect("tell server that reader is paused");
        read_waiting.await.expect("paused reader entered wait");
        let waiter_control = Arc::clone(&control);
        let reader_done = tokio::spawn(async move { waiter_control.wait_reader_done().await });
        tokio::task::yield_now().await;
        control.end();

        tokio::time::timeout(Duration::from_secs(1), reader_done)
            .await
            .expect("paused reader exits after end")
            .expect("join paused reader waiter");
        tokio::time::timeout(Duration::from_secs(1), server)
            .await
            .expect("server observes client close")
            .expect("join control close test server");
        let _ = std::fs::remove_file(socket_path);
    }

    #[tokio::test]
    async fn close_broadcast_wakes_two_waiters() {
        let notify = Arc::new(Notify::new());
        let (first_ready_tx, first_ready_rx) = oneshot::channel();
        let (second_ready_tx, second_ready_rx) = oneshot::channel();
        let first_notify = Arc::clone(&notify);
        let first = tokio::spawn(async move {
            let notified = first_notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            first_ready_tx.send(()).expect("signal first waiter registration");
            notified.await;
        });
        let second_notify = Arc::clone(&notify);
        let second = tokio::spawn(async move {
            let notified = second_notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            second_ready_tx.send(()).expect("signal second waiter registration");
            notified.await;
        });
        first_ready_rx.await.expect("first waiter registered");
        second_ready_rx.await.expect("second waiter registered");
        notify.notify_waiters();
        tokio::time::timeout(Duration::from_secs(1), first)
            .await
            .expect("first waiter wakes")
            .expect("first waiter joins");
        tokio::time::timeout(Duration::from_secs(1), second)
            .await
            .expect("second waiter wakes")
            .expect("second waiter joins");
    }

    #[tokio::test]
    async fn event_callbacks_run_in_wire_order() {
        let socket_path = std::env::temp_dir()
            .join(format!("chatmux-relay-control-events-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path).expect("bind control event test socket");
        let (accepted_tx, accepted_rx) = oneshot::channel();
        let (start_tx, start_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept control event socket");
            accepted_tx.send(()).expect("tell client that socket is accepted");
            start_rx.await.expect("wait for event handler");
            stream
                .write_all(b"{\"event\":\"first\"}\n{\"event\":\"second\"}\n")
                .await
                .expect("write control events");
            let mut bytes = Vec::new();
            stream.read_to_end(&mut bytes).await.expect("read client close");
        });

        let control =
            connect_control(&socket_path, 3_000).await.expect("connect control event test socket");
        accepted_rx.await.expect("wait for control event server");
        let seen = Arc::new(Mutex::new(Vec::new()));
        let (done_tx, done_rx) = oneshot::channel();
        let done_tx = Arc::new(Mutex::new(Some(done_tx)));
        let seen_for_handler = Arc::clone(&seen);
        let done_tx_for_handler = Arc::clone(&done_tx);
        control.on_event(Box::new(move |event| {
            let mut seen = seen_for_handler.lock().expect("event record lock");
            seen.push(event["event"].as_str().expect("event name").to_owned());
            if seen.len() == 2 {
                if let Some(done_tx) = done_tx_for_handler.lock().expect("event done lock").take() {
                    let _ = done_tx.send(());
                }
            }
        }));
        start_tx.send(()).expect("start control event stream");

        tokio::time::timeout(Duration::from_secs(1), done_rx)
            .await
            .expect("ordered event callbacks complete")
            .expect("ordered event callback signal");
        assert_eq!(
            *seen.lock().expect("event record lock"),
            vec!["first".to_owned(), "second".to_owned()]
        );
        control.end();
        tokio::time::timeout(Duration::from_secs(1), server)
            .await
            .expect("server observes client close")
            .expect("join control event server");
        let _ = std::fs::remove_file(socket_path);
    }

    #[tokio::test]
    async fn close_callback_survives_a_full_event_queue() {
        let socket_path = std::env::temp_dir()
            .join(format!("chatmux-relay-control-event-overflow-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path).expect("bind control overflow socket");
        let (accepted_tx, accepted_rx) = oneshot::channel();
        let (start_tx, start_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept control overflow socket");
            accepted_tx.send(()).expect("tell client that socket is accepted");
            start_rx.await.expect("wait for event handler");
            for index in 0..=MAX_EVENT_QUEUE {
                let line = format!("{{\"event\":\"queued-{index}\"}}\n");
                stream.write_all(line.as_bytes()).await.expect("write queued event");
            }
            // EOF is the unexpected close that must still reach on_close.
        });

        let control = unix::connect_control_for_test(&socket_path, 3_000)
            .await
            .expect("connect overflow socket");
        accepted_rx.await.expect("wait for control overflow server");
        let (entered_tx, entered_rx) = oneshot::channel();
        let entered_tx = Arc::new(Mutex::new(Some(entered_tx)));
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let closed = Arc::new(Notify::new());
        let closed_for_handler = Arc::clone(&closed);
        let entered_for_handler = Arc::clone(&entered_tx);
        control.on_event(Box::new(move |_| {
            if let Some(entered_tx) = entered_for_handler.lock().expect("entry signal lock").take()
            {
                let _ = entered_tx.send(());
                release_rx.recv().expect("release first event callback");
            }
        }));
        control.on_close(Box::new(move || closed_for_handler.notify_waiters()));
        start_tx.send(()).expect("start control event overflow");
        tokio::time::timeout(Duration::from_secs(1), entered_rx)
            .await
            .expect("first callback entered")
            .expect("entry signal");

        let closed_wait = closed.notified();
        tokio::pin!(closed_wait);
        // Drop the public handle while the worker is blocked in the first
        // callback. Closure delivery must retain its own shared state until
        // the queued events and close notification are drained.
        drop(control);
        release_tx.send(()).expect("release first event callback");
        tokio::time::timeout(Duration::from_secs(2), &mut closed_wait)
            .await
            .expect("close callback survives full event queue");
        server.await.expect("join control overflow server");
        let _ = std::fs::remove_file(socket_path);
    }

    #[tokio::test]
    async fn close_callback_survives_event_queue_byte_overflow() {
        let socket_path = std::env::temp_dir()
            .join(format!("chatmux-relay-control-event-bytes-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path).expect("bind control byte socket");
        let (accepted_tx, accepted_rx) = oneshot::channel();
        let (start_tx, start_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept control byte socket");
            accepted_tx.send(()).expect("tell client that socket is accepted");
            start_rx.await.expect("wait for event handler");
            let payload = "x".repeat(MAX_CONTROL_LINE_BYTES / 2);
            for _ in 0..=MAX_EVENT_QUEUE_BYTES / (MAX_CONTROL_LINE_BYTES / 2) {
                let line = format!("{{\"event\":\"{payload}\"}}\n");
                stream.write_all(line.as_bytes()).await.expect("write byte-limited event");
            }
        });

        let control = unix::connect_control_for_test(&socket_path, 3_000)
            .await
            .expect("connect byte-limited socket");
        accepted_rx.await.expect("wait for control byte server");
        let (entered_tx, entered_rx) = oneshot::channel();
        let entered_tx = Arc::new(Mutex::new(Some(entered_tx)));
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let closed = Arc::new(Notify::new());
        let closed_for_handler = Arc::clone(&closed);
        let entered_for_handler = Arc::clone(&entered_tx);
        control.on_event(Box::new(move |_| {
            if let Some(entered_tx) = entered_for_handler.lock().expect("entry signal lock").take()
            {
                let _ = entered_tx.send(());
                release_rx.recv().expect("release first byte callback");
            }
        }));
        control.on_close(Box::new(move || closed_for_handler.notify_waiters()));
        start_tx.send(()).expect("start control byte overflow");
        tokio::time::timeout(Duration::from_secs(1), entered_rx)
            .await
            .expect("first byte callback entered")
            .expect("entry signal");

        let closed_wait = closed.notified();
        tokio::pin!(closed_wait);
        release_tx.send(()).expect("release first byte callback");
        tokio::time::timeout(Duration::from_secs(2), &mut closed_wait)
            .await
            .expect("close callback survives byte overflow");
        server.await.expect("join control byte server");
        let _ = std::fs::remove_file(socket_path);
    }

    #[tokio::test]
    async fn late_close_registration_invokes_callback() {
        let socket_path = std::env::temp_dir()
            .join(format!("chatmux-relay-control-late-close-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path).expect("bind control late-close socket");
        let (accepted_tx, accepted_rx) = oneshot::channel();
        let (start_tx, start_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("accept control late-close socket");
            accepted_tx.send(()).expect("tell client that socket is accepted");
            start_rx.await.expect("wait for reader arm");
            drop(stream);
        });

        let control = unix::connect_control_for_test(&socket_path, 3_000)
            .await
            .expect("connect late-close socket");
        accepted_rx.await.expect("wait for control late-close server");
        let reader_control = Arc::clone(&control);
        let reader_done = tokio::spawn(async move { reader_control.wait_reader_done().await });
        tokio::task::yield_now().await;
        start_tx.send(()).expect("start late close");
        tokio::time::timeout(Duration::from_secs(1), reader_done)
            .await
            .expect("reader observed late close")
            .expect("reader waiter task");
        let closed = Arc::new(Notify::new());
        let closed_for_handler = Arc::clone(&closed);
        control.on_close(Box::new(move || closed_for_handler.notify_waiters()));
        tokio::time::timeout(Duration::from_secs(1), closed.notified())
            .await
            .expect("late close registration invokes callback");
        server.await.expect("join control late-close server");
        let _ = std::fs::remove_file(socket_path);
    }

    #[tokio::test]
    async fn late_close_registration_waits_for_queued_events() {
        let socket_path = std::env::temp_dir()
            .join(format!("chatmux-relay-control-late-order-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path).expect("bind control late-order socket");
        let (accepted_tx, accepted_rx) = oneshot::channel();
        let (start_tx, start_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut stream, _) =
                listener.accept().await.expect("accept control late-order socket");
            accepted_tx.send(()).expect("tell client that socket is accepted");
            start_rx.await.expect("wait for event handler");
            stream.write_all(b"{\"event\":\"queued\"}\n").await.expect("write queued event");
            drop(stream);
        });

        let control = unix::connect_control_for_test(&socket_path, 3_000)
            .await
            .expect("connect late-order socket");
        accepted_rx.await.expect("wait for control late-order server");
        let (entered_tx, entered_rx) = oneshot::channel();
        let entered_tx = Arc::new(Mutex::new(Some(entered_tx)));
        let release = Arc::new(std::sync::Barrier::new(2));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let entered_for_handler = Arc::clone(&entered_tx);
        let release_for_handler = Arc::clone(&release);
        let seen_for_event = Arc::clone(&seen);
        control.on_event(Box::new(move |_| {
            seen_for_event.lock().expect("event order lock").push("event");
            if let Some(entered_tx) = entered_for_handler.lock().expect("entry signal lock").take()
            {
                let _ = entered_tx.send(());
            }
            release_for_handler.wait();
        }));
        let control_for_reader = Arc::clone(&control);
        let reader_done = tokio::spawn(async move { control_for_reader.wait_reader_done().await });
        tokio::task::yield_now().await;
        start_tx.send(()).expect("start late-order event");
        tokio::time::timeout(Duration::from_secs(1), entered_rx)
            .await
            .expect("event callback entered")
            .expect("entry signal");
        tokio::time::timeout(Duration::from_secs(1), reader_done)
            .await
            .expect("reader sees peer close")
            .expect("reader waiter task");

        let seen_for_close = Arc::clone(&seen);
        let (close_tx, close_rx) = oneshot::channel();
        let close_tx = Arc::new(Mutex::new(Some(close_tx)));
        let close_signal = Arc::clone(&close_tx);
        let control_for_close = Arc::clone(&control);
        let close_registration = std::thread::spawn(move || {
            control_for_close.on_close(Box::new(move || {
                seen_for_close.lock().expect("close order lock").push("close");
                if let Some(close_tx) = close_signal.lock().expect("close signal lock").take() {
                    let _ = close_tx.send(());
                }
            }));
        });
        close_registration.join().expect("late close registration");
        release.wait();
        tokio::time::timeout(Duration::from_secs(1), close_rx)
            .await
            .expect("close callback after queued event")
            .expect("close callback signal");
        assert_eq!(*seen.lock().expect("event order lock"), vec!["event", "close"]);
        tokio::time::timeout(Duration::from_secs(1), server)
            .await
            .expect("join control late-order server")
            .expect("late-order server task");
        let _ = std::fs::remove_file(socket_path);
    }

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
