//! A take-over moves the accepted socket connections that hold no state to the next daemon
//! (RFD 0082 path 3; Leo 2026-11-23: "we ought to have more graceful handoffs... and
//! fundamentally be able to reconnect ... faster"). The listener handover
//! (`daemon/listener_handover.rs`) keeps the listen queue open, so no connect is refused; a
//! connection the old daemon had already accepted still ended with it, and its client's next
//! request failed and redialed: one failed request per client per take-over.
//!
//! A connection is plain while every line it sent was a `_acpmux/status` request: it has no
//! `initialize`, no subscription, no session, nothing the old daemon keeps for it, so the next
//! daemon can serve the same socket as a connection it accepted itself. For those, at the stop:
//!
//! 1. [`park`] asks each plain connection's reader to stop. It stops only between lines (nothing
//!    read and not yet parsed) and reads no more: what the client sends from then on waits in the
//!    socket for the next daemon.
//! 2. [`hand`] waits, within [`SETTLE_WITHIN`], for the answers to what each parked connection
//!    already read to be written, and sends each such socket to the next daemon by descriptor.
//!    From then on this daemon writes nothing to it and never shuts it down ([`KeepOpen`]), so
//!    the client reads no end of file. This runs before the stop's drain (`shutdown_drain.rs`),
//!    which refuses what a connection reads after it.
//! 3. The next daemon serves each as an accepted connection (`serve_accepted`).
//!
//! Any other connection (one that said `initialize`, attached a chat, has a line half read, or
//! whose answer did not leave in time) ends as before: its client is told `daemon.restarting`
//! and redials into the queue the next daemon serves. The cost is one map entry per local
//! connection and, until its first other line, one parse of each line.

#![cfg_attr(not(unix), allow(dead_code))]

use std::collections::HashMap;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::io::AsyncWrite;

/// How long [`hand`] waits for the parked connections' readers to stop and answers to leave.
// timeout: a connection not settled then ends as before (its client redials); the stop goes on.
pub(crate) const SETTLE_WITHIN: Duration = Duration::from_millis(100);
/// How often that wait looks again: it reads atomics.
const LOOK: Duration = Duration::from_millis(2);

const SERVING: u8 = 0;
const PARKED: u8 = 1;
const KEPT: u8 = 2;

/// One local connection, as the handover sees it.
pub(crate) struct Movable {
    /// The connection's socket. Read only while the reader is parked: it holds the read half
    /// then, so the descriptor is open.
    #[cfg(unix)]
    fd: std::os::fd::RawFd,
    /// Every line so far was a `_acpmux/status` request.
    plain: AtomicBool,
    /// Lines the reader gave the server, each a request that gets one answer.
    forwarded: AtomicU64,
    /// Lines written to the socket.
    written: AtomicU64,
    park: tokio::sync::Notify,
    state: AtomicU8,
    /// Sent to the next daemon: no write, no shutdown.
    moved: AtomicBool,
}

static LIVE: Mutex<Option<HashMap<u64, Arc<Movable>>>> = Mutex::new(None);
static NEXT: AtomicU64 = AtomicU64::new(0);

/// A connection's entry among the live ones; dropped with the connection.
pub(crate) struct Watched {
    id: u64,
    pub(crate) movable: Arc<Movable>,
}

impl Drop for Watched {
    fn drop(&mut self) {
        if let Some(live) = LIVE.lock().unwrap_or_else(PoisonError::into_inner).as_mut() {
            live.remove(&self.id);
        }
    }
}

/// Watch a connection just accepted on `stream`.
#[cfg(unix)]
pub(crate) fn watch(stream: &crate::local_stream::Stream) -> Option<Watched> {
    use std::os::fd::AsRawFd as _;
    let movable = Arc::new(Movable {
        fd: stream.as_raw_fd(),
        plain: AtomicBool::new(true),
        forwarded: AtomicU64::new(0),
        written: AtomicU64::new(0),
        park: tokio::sync::Notify::new(),
        state: AtomicU8::new(SERVING),
        moved: AtomicBool::new(false),
    });
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    LIVE.lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get_or_insert_with(HashMap::new)
        .insert(id, movable.clone());
    Some(Watched { id, movable })
}

/// No descriptor passing off Unix: no connection is watched.
#[cfg(not(unix))]
pub(crate) fn watch(_stream: &crate::local_stream::Stream) -> Option<Watched> {
    None
}

/// Whether `line` is a `_acpmux/status` request with an id: a read that leaves nothing behind
/// on its connection and gets exactly one answer.
fn plain_request(line: &str) -> bool {
    if line.len() > 512 || !line.contains(crate::rpc::method::MUX_STATUS) {
        return false;
    }
    matches!(
        crate::rpc::Message::parse(line),
        Ok(crate::rpc::Message::Request { method, .. }) if method == crate::rpc::method::MUX_STATUS
    )
}

impl Movable {
    /// The reader read `line` (None: one it does not give the server as a request).
    pub(crate) fn saw(&self, line: Option<&str>) {
        if !self.plain.load(Ordering::Relaxed) {
            return;
        }
        if line.is_some_and(plain_request) {
            self.forwarded.fetch_add(1, Ordering::SeqCst);
        } else {
            self.plain.store(false, Ordering::SeqCst);
        }
    }

    /// Resolves once the stop asks this connection's reader to park.
    pub(crate) async fn park_asked(&self) {
        self.park.notified().await;
    }

    /// The reader's answer to [`Movable::park_asked`]: it parks (true, and must read no more)
    /// only when the connection is plain and `between_lines` (it holds no byte read and not yet
    /// given to the server); otherwise it reads on as before.
    pub(crate) fn settle(&self, between_lines: bool) -> bool {
        let parks = between_lines && self.plain.load(Ordering::SeqCst);
        self.state.store(if parks { PARKED } else { KEPT }, Ordering::SeqCst);
        parks
    }

    fn settled(&self) -> bool {
        match self.state.load(Ordering::SeqCst) {
            SERVING => false,
            PARKED => self.written.load(Ordering::SeqCst) >= self.forwarded.load(Ordering::SeqCst),
            _ => true,
        }
    }

    fn movable(&self) -> bool {
        self.state.load(Ordering::SeqCst) == PARKED && self.settled()
    }
}

/// The connections asked to park.
pub(crate) struct Parked(Vec<Arc<Movable>>);

/// Ask every plain connection's reader to park, so it reads nothing the next daemon should
/// answer.
pub(crate) fn park() -> Parked {
    let asked: Vec<Arc<Movable>> = LIVE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .flat_map(HashMap::values)
        .filter(|m| m.plain.load(Ordering::SeqCst))
        .cloned()
        .collect();
    for movable in &asked {
        movable.park.notify_one();
    }
    Parked(asked)
}

/// Give each parked connection whose answers all left to `send` (its socket), in order, until
/// one fails. How many went.
#[cfg(unix)]
pub(crate) async fn hand(
    parked: Parked,
    mut send: impl FnMut(std::os::fd::BorrowedFd<'_>) -> std::io::Result<()>,
) -> usize {
    let until = tokio::time::Instant::now() + SETTLE_WITHIN;
    while !parked.0.iter().all(|m| m.settled()) && tokio::time::Instant::now() < until {
        tokio::time::sleep(LOOK).await;
    }
    let mut sent = 0;
    for movable in parked.0.iter().filter(|m| m.movable()) {
        // Before the send: from here this daemon neither writes to the socket nor shuts it down.
        movable.moved.store(true, Ordering::SeqCst);
        // SAFETY: the reader parked ([`Movable::settle`]) and holds its read half for good, so
        // the descriptor is this connection's open socket for the whole call.
        let fd = unsafe { std::os::fd::BorrowedFd::borrow_raw(movable.fd) };
        if let Err(e) = send(fd) {
            movable.moved.store(false, Ordering::SeqCst);
            tracing::warn!("connection handover stopped after {sent}: {e}");
            break;
        }
        sent += 1;
    }
    sent
}

/// A connection's write half. Counts the lines written; once the connection moved to the next
/// daemon it writes nothing more, and its drop leaves the socket open (dropping a unix write
/// half shuts the socket's write side down, which the next daemon's copy would share).
pub(crate) struct KeepOpen<W> {
    inner: Option<W>,
    movable: Option<Arc<Movable>>,
}

impl<W> KeepOpen<W> {
    pub(crate) fn new(inner: W, movable: Option<Arc<Movable>>) -> Self {
        Self { inner: Some(inner), movable }
    }

    fn moved(&self) -> bool {
        self.movable.as_ref().is_some_and(|m| m.moved.load(Ordering::SeqCst))
    }
}

impl<W> Drop for KeepOpen<W> {
    fn drop(&mut self) {
        if self.moved() {
            std::mem::forget(self.inner.take());
        }
    }
}

fn moved_error() -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::BrokenPipe, "the connection moved to the next daemon")
}

impl<W: AsyncWrite + Unpin> AsyncWrite for KeepOpen<W> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        if self.moved() {
            return Poll::Ready(Err(moved_error()));
        }
        let this = &mut *self;
        let Some(inner) = this.inner.as_mut() else {
            return Poll::Ready(Err(moved_error()));
        };
        let wrote = Pin::new(inner).poll_write(cx, buf);
        if let (Poll::Ready(Ok(n)), Some(movable)) = (&wrote, &this.movable)
            && movable.plain.load(Ordering::Relaxed)
        {
            let lines = buf.iter().take(*n).filter(|b| **b == b'\n').count() as u64;
            movable.written.fetch_add(lines, Ordering::SeqCst);
        }
        wrote
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match self.inner.as_mut() {
            Some(inner) => Pin::new(inner).poll_flush(cx),
            None => Poll::Ready(Ok(())),
        }
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        if self.moved() {
            return Poll::Ready(Ok(()));
        }
        match self.inner.as_mut() {
            Some(inner) => Pin::new(inner).poll_shutdown(cx),
            None => Poll::Ready(Ok(())),
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt as _;

    #[test]
    fn only_status_requests_keep_a_connection_plain() {
        assert!(plain_request(r#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/status","params":{}}"#));
        assert!(!plain_request(r#"{"jsonrpc":"2.0","method":"_acpmux/status"}"#));
        assert!(!plain_request(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#));
        assert!(!plain_request(
            r#"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"t":"_acpmux/status"}}"#
        ));
    }

    /// A moved connection's write half writes nothing more and leaves the socket open; one that
    /// did not move ends the client's read as it always did.
    #[tokio::test]
    async fn a_moved_write_half_leaves_the_socket_open() {
        use tokio::io::AsyncReadExt as _;
        for moves in [true, false] {
            let (server, mut client) = tokio::net::UnixStream::pair().unwrap();
            let watched = watch(&server).unwrap();
            let (rd, wr) = server.into_split();
            let mut wr = KeepOpen::new(wr, Some(watched.movable.clone()));
            watched.movable.saw(Some(r#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/status"}"#));
            // Not `park()`: that asks every live connection of this test process.
            let parked = Parked(vec![watched.movable.clone()]);
            assert!(!watched.movable.settled(), "its reader has not answered");
            assert!(watched.movable.settle(true));
            assert!(!watched.movable.settled(), "its answer has not left");
            wr.write_all(b"{\"id\":1}\n").await.unwrap();
            assert!(watched.movable.settled());
            if moves {
                let mut seen = 0;
                let sent = hand(parked, |_| {
                    seen += 1;
                    Ok(())
                })
                .await;
                assert_eq!((sent, seen), (1, 1));
                assert!(wr.write_all(b"late\n").await.is_err());
            }
            drop(wr);
            let mut got = vec![0u8; 64];
            let n = client.read(&mut got).await.unwrap();
            assert_eq!(&got[..n], b"{\"id\":1}\n");
            let end = tokio::time::timeout(Duration::from_millis(100), client.read(&mut got)).await;
            if moves {
                assert!(end.is_err(), "a moved connection reads no end of file");
            } else {
                assert_eq!(end.unwrap().unwrap(), 0);
            }
            drop(rd);
        }
    }
}
