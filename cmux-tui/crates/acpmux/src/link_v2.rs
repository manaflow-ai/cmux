//! The v2 list stream on a peer link, beside v1's watch (the design doc, "The list": "During
//! migration the list rides the v1 link").
//!
//! A frame travels as one v1 notification,
//! `{"jsonrpc":"2.0","method":"_acpmux/v2","params":{"kind":K,"payload":P}}`: K is the frame's
//! kind byte and P its payload as its own JSON bytes. [`Adapter`] gives a v2 connection
//! (`acpmux_core::conn::run`, or the client in a test) an ordered byte stream over those
//! notifications, and holds at most one frame each way:
//!
//! - Toward the peer, the connection's write waits for the link writer's [`Slot`] of one. A frame
//!   never enters the link's queue of 4,096 v1 lines, and the writer takes v1's lines first
//!   ([`next_line`]).
//! - From the peer, the link's reader waits until the connection has read the frame before it.
//!
//! No frame of a running connection is dropped. A frame with no connection is dropped and
//! counted, and so is every `_acpmux/v2` notification on a connection that is not a link, or with
//! `peers` off. The first `hello` on a link starts its one connection, served with
//! [`Role::Peer`], which nothing in a frame changes; a second `hello` ends it and is the first
//! frame of the next.

use acpmux_core::conn::{HubSource, Role};
use serde::Deserialize;
use std::borrow::Cow;
use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll, Waker};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{Notify, mpsc};

/// The `initialize` feature a link names when it carries the stream.
pub const FEATURE: &str = "listStream";

/// How every frame line starts. The reader knows the method from these bytes, before it parses.
const PREFIX: &str = r#"{"jsonrpc":"2.0","method":"_acpmux/v2","params":{"kind":"#;

/// v1 lines the writer takes in a row while a frame waits in the slot; then the frame goes.
pub const V1_BURST: u32 = 32;

const HEADER_BYTES: usize = 4;
const KIND_REQUEST: u8 = 9;

/// What a daemon's links share: the v2 handle when `acpmux.v2` holds `list` and `peers`, and
/// the counters.
#[derive(Default)]
pub struct Shared {
    v2: OnceLock<Arc<acpmux_core::life::V2>>,
    pub counters: Counters,
}

impl Shared {
    /// Links serve the stream from here on. Only with `list` and `peers` in the set.
    pub fn install(&self, v2: Arc<acpmux_core::life::V2>) {
        if v2.allows_surfaces(&["list", "peers"]) {
            let _ = self.v2.set(v2);
        }
    }

    pub fn v2(&self) -> Option<&Arc<acpmux_core::life::V2>> {
        self.v2.get()
    }

    /// A link transport's slot, made at the connection's start, only when links serve the
    /// stream. With none, its writer reads v1's queue alone, as before the stream.
    pub fn slot(self: &Arc<Self>) -> Option<Arc<Slot>> {
        self.v2().is_some().then(|| Slot::new(Some(self.clone())))
    }
}

#[derive(Default)]
pub struct Counters {
    /// Frames dropped because no connection was there to take them.
    pub dropped: AtomicU64,
    /// A `hello` that ended a running connection.
    pub second_hello: AtomicU64,
    /// `_acpmux/v2` lines parsed into a whole `Value` (the reader's fast path missed them).
    pub value_parses: AtomicU64,
    /// Frames toward the peer left in the slot when a new connection began or the link ended.
    pub stale: AtomicU64,
    /// Bytes the adapters of this daemon hold: the slot's line and a frame not yet read.
    pub held_bytes: AtomicU64,
}

impl Counters {
    pub fn drop_one(&self) {
        self.dropped.fetch_add(1, Ordering::Relaxed);
    }

    /// What `_acpmux/status` reports under `gauges.v2PeerLink`.
    pub fn status(&self) -> serde_json::Value {
        let read = |counter: &AtomicU64| counter.load(Ordering::Relaxed);
        serde_json::json!({
            "dropped": read(&self.dropped),
            "secondHello": read(&self.second_hello),
            "valueParses": read(&self.value_parses),
            "stale": read(&self.stale),
            "heldBytes": read(&self.held_bytes),
        })
    }
}

/// Whether `line` is a frame line, by its first bytes.
pub fn is_frame_line(line: &str) -> bool {
    line.starts_with(PREFIX)
}

/// One frame read off a link: its kind byte and its payload's JSON, borrowed from the line.
pub struct Incoming<'a> {
    pub kind: u8,
    pub payload: &'a [u8],
}

#[derive(Deserialize)]
struct Line<'a> {
    #[serde(borrow)]
    params: Params<'a>,
}

#[derive(Deserialize)]
struct Params<'a> {
    kind: u8,
    #[serde(borrow)]
    payload: &'a serde_json::value::RawValue,
}

#[derive(Deserialize)]
struct Method<'a> {
    #[serde(borrow, default)]
    method: Option<Cow<'a, str>>,
}

/// Takes a frame line apart without building a tree: P is checked as JSON and kept as its bytes.
pub fn parse(line: &str) -> Option<Incoming<'_>> {
    let line: Line<'_> = serde_json::from_str(line.trim_end()).ok()?;
    let payload = line.params.payload.get().as_bytes();
    (payload.len() + HEADER_BYTES < acpmux_core::wire::MAX_FRAME_BYTES)
        .then_some(Incoming { kind: line.params.kind, payload })
}

impl Incoming<'_> {
    fn is_hello(&self) -> bool {
        self.kind == KIND_REQUEST
            && serde_json::from_slice::<Method<'_>>(self.payload)
                .is_ok_and(|m| m.method.as_deref() == Some("hello"))
    }

    fn encoded(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_BYTES + 1 + self.payload.len());
        out.extend_from_slice(&((1 + self.payload.len()) as u32).to_be_bytes());
        out.push(self.kind);
        out.extend_from_slice(self.payload);
        out
    }
}

/// The one frame line from `kind` and `payload`. A payload that is not a JSON object's text has
/// no form on a link.
fn frame_line(kind: u8, payload: &[u8]) -> io::Result<String> {
    let text = std::str::from_utf8(payload).map_err(|_| not_json())?;
    if !text.trim_start().starts_with('{') {
        return Err(not_json());
    }
    let mut line = String::with_capacity(PREFIX.len() + text.len() + 20);
    line.push_str(PREFIX);
    line.push_str(&kind.to_string());
    line.push_str(r#","payload":"#);
    line.push_str(text);
    line.push_str("}}\n");
    Ok(line)
}

fn not_json() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "a frame whose payload is not JSON has no form on a link",
    )
}

fn replaced() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "a new connection began on the link")
}

/// The link writer's slot of one frame line toward the peer.
pub struct Slot {
    state: Mutex<SlotState>,
    filled: Notify,
    counters: Option<Arc<Shared>>,
    reader_ended: AtomicBool,
    ended: Notify,
}

#[derive(Default)]
struct SlotState {
    line: Option<String>,
    generation: u64,
    waker: Option<Waker>,
}

impl Slot {
    pub fn new(shared: Option<Arc<Shared>>) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::default(),
            filled: Notify::new(),
            counters: shared,
            reader_ended: AtomicBool::new(false),
            ended: Notify::new(),
        })
    }

    /// The transport's reader ended: no connection writes here again, a waiting write fails
    /// now, and a wait to hand the connection a frame is cancelled.
    fn end_reader(&self) {
        self.reader_ended.store(true, Ordering::Release);
        self.retire();
        self.ended.notify_waiters();
    }

    fn is_reader_ended(&self) -> bool {
        self.reader_ended.load(Ordering::Acquire)
    }

    /// Resolves once the transport's reader has ended.
    pub async fn reader_ended(&self) {
        loop {
            let ended = self.ended.notified();
            if self.is_reader_ended() {
                return;
            }
            ended.await;
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, SlotState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn held(&self, delta: i64) {
        if let Some(shared) = &self.counters {
            if delta >= 0 {
                shared.counters.held_bytes.fetch_add(delta as u64, Ordering::Relaxed);
            } else {
                shared.counters.held_bytes.fetch_sub(delta.unsigned_abs(), Ordering::Relaxed);
            }
        }
    }

    /// A new connection's writes go here from now on; an older one's are refused, and a frame
    /// of it the writer has not taken is dropped.
    fn begin(&self) -> u64 {
        let mut state = self.lock();
        state.generation += 1;
        if let Some(line) = state.line.take() {
            self.held(-(line.len() as i64));
            if let Some(shared) = &self.counters {
                shared.counters.stale.fetch_add(1, Ordering::Relaxed);
            }
        }
        if let Some(waker) = state.waker.take() {
            waker.wake();
        }
        state.generation
    }

    /// No connection writes here any more: the running one's writes fail, its waiting write is
    /// woken, and a line of it the writer has not taken is dropped.
    fn retire(&self) {
        self.begin();
    }

    fn poll_room(&self, generation: u64, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let mut state = self.lock();
        if state.generation != generation {
            return Poll::Ready(Err(replaced()));
        }
        if state.line.is_some() {
            state.waker = Some(cx.waker().clone());
            return Poll::Pending;
        }
        Poll::Ready(Ok(()))
    }

    fn put(&self, generation: u64, line: String) -> io::Result<()> {
        let mut state = self.lock();
        if state.generation != generation {
            return Err(replaced());
        }
        debug_assert!(state.line.is_none(), "one writer per generation, after poll_room");
        self.held(line.len() as i64);
        state.line = Some(line);
        drop(state);
        self.filled.notify_one();
        Ok(())
    }

    /// The frame line waiting, if one is; its writer may then write the next.
    pub fn take(&self) -> Option<String> {
        let mut state = self.lock();
        let line = state.line.take()?;
        self.held(-(line.len() as i64));
        if let Some(waker) = state.waker.take() {
            waker.wake();
        }
        Some(line)
    }

    pub fn holds(&self) -> bool {
        self.lock().line.is_some()
    }

    /// The next frame line, when one comes. Cancel safe: a line is taken only when returned.
    pub async fn next(&self) -> String {
        loop {
            let filled = self.filled.notified();
            tokio::pin!(filled);
            filled.as_mut().enable();
            if let Some(line) = self.take() {
                return line;
            }
            filled.await;
        }
    }
}

/// The link writer's next line: v1's first, so the list never holds a v1 reply back. A frame
/// waiting in the slot goes after at most [`V1_BURST`] v1 lines in a row, so a v1 flood delays
/// it and cannot starve it. `streak` counts those lines; the caller keeps it between calls.
pub async fn next_line(
    outbound: &mut mpsc::Receiver<String>,
    slot: Option<&Slot>,
    streak: &mut u32,
) -> Option<String> {
    let Some(slot) = slot else { return outbound.recv().await };
    if *streak >= V1_BURST
        && let Some(line) = slot.take()
    {
        *streak = 0;
        return Some(line);
    }
    tokio::select! {
        biased;
        line = outbound.recv() => {
            *streak = if slot.holds() { streak.saturating_add(1) } else { 0 };
            line
        }
        line = slot.next() => {
            *streak = 0;
            Some(line)
        }
    }
}

/// Toward the peer: the connection writes encoded frames; each whole frame becomes one line in
/// the slot. Bytes are taken only while the slot is empty, so the adapter holds one frame.
pub struct Writer {
    slot: Arc<Slot>,
    generation: u64,
    frame: Vec<u8>,
}

impl AsyncWrite for Writer {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        match this.slot.poll_room(this.generation, cx) {
            Poll::Pending => return Poll::Pending,
            Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
            Poll::Ready(Ok(())) => {}
        }
        let mut taken = 0;
        while taken < data.len() {
            let want = if this.frame.len() < HEADER_BYTES {
                HEADER_BYTES - this.frame.len()
            } else {
                // Past the header's length here; a zero length is refused below.
                let body = this
                    .frame
                    .first_chunk::<HEADER_BYTES>()
                    .map_or(0, |header| u32::from_be_bytes(*header) as usize);
                if body == 0 || body + HEADER_BYTES > acpmux_core::wire::MAX_FRAME_BYTES {
                    return Poll::Ready(Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "invalid frame length",
                    )));
                }
                HEADER_BYTES + body - this.frame.len()
            };
            let n = want.min(data.len() - taken);
            this.frame.extend_from_slice(data.get(taken..taken + n).unwrap_or_default());
            taken += n;
            if this.frame.len() > HEADER_BYTES && n == want {
                let frame = std::mem::take(&mut this.frame);
                let (Some(&kind), Some(payload)) =
                    (frame.get(HEADER_BYTES), frame.get(HEADER_BYTES + 1..))
                else {
                    return Poll::Ready(Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "a frame without its kind",
                    )));
                };
                let line = frame_line(kind, payload)?;
                this.slot.put(this.generation, line)?;
                // The slot is full now: the next frame's bytes wait for its room.
                break;
            }
        }
        Poll::Ready(Ok(taken))
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

/// From the peer: one encoded frame the connection has not read yet.
struct Inbound {
    state: Mutex<InState>,
    taken: Notify,
    counters: Option<Arc<Shared>>,
}

#[derive(Default)]
struct InState {
    frame: Vec<u8>,
    offset: usize,
    closed: bool,
    waker: Option<Waker>,
}

impl Inbound {
    fn lock(&self) -> std::sync::MutexGuard<'_, InState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn close(&self) {
        let mut state = self.lock();
        state.closed = true;
        if let Some(shared) = &self.counters {
            let held = (state.frame.len() - state.offset) as u64;
            shared.counters.held_bytes.fetch_sub(held, Ordering::Relaxed);
        }
        state.frame = Vec::new();
        state.offset = 0;
        if let Some(waker) = state.waker.take() {
            waker.wake();
        }
        drop(state);
        self.taken.notify_waiters();
    }
}

/// The connection's reader: the frames the link brought, in order, then the end of the stream.
pub struct Reader {
    inbound: Arc<Inbound>,
}

impl AsyncRead for Reader {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let inbound = &self.inbound;
        let mut state = inbound.lock();
        if state.offset < state.frame.len() {
            let n = buf.remaining().min(state.frame.len() - state.offset);
            let start = state.offset;
            buf.put_slice(state.frame.get(start..start + n).unwrap_or_default());
            state.offset += n;
            if let Some(shared) = &inbound.counters {
                shared.counters.held_bytes.fetch_sub(n as u64, Ordering::Relaxed);
            }
            if state.offset == state.frame.len() {
                state.frame = Vec::new();
                state.offset = 0;
                drop(state);
                inbound.taken.notify_waiters();
            }
            return Poll::Ready(Ok(()));
        }
        if state.closed {
            return Poll::Ready(Ok(()));
        }
        state.waker = Some(cx.waker().clone());
        Poll::Pending
    }
}

/// One connection's byte stream over a link: the half the link feeds and the half it drains.
/// The serving end gives [`Reader`] and [`Writer`] to `conn::run`; a test's dialing end gives
/// them to the client.
pub struct Adapter {
    inbound: Arc<Inbound>,
    slot: Arc<Slot>,
}

impl Adapter {
    /// A new connection on `slot`'s link: frames of the connection before it are refused.
    pub fn new(slot: Arc<Slot>) -> (Self, Reader, Writer) {
        let generation = slot.begin();
        let inbound = Arc::new(Inbound {
            state: Mutex::default(),
            taken: Notify::new(),
            counters: slot.counters.clone(),
        });
        let reader = Reader { inbound: inbound.clone() };
        let writer = Writer { slot: slot.clone(), generation, frame: Vec::new() };
        (Self { inbound, slot }, reader, writer)
    }

    /// Hands one frame to the connection, after it has read the one before. `false` when the
    /// connection ended first: the frame had no connection.
    pub async fn deliver(&self, frame: &Incoming<'_>) -> bool {
        let encoded = frame.encoded();
        loop {
            let taken = self.inbound.taken.notified();
            tokio::pin!(taken);
            taken.as_mut().enable();
            {
                let mut state = self.inbound.lock();
                if state.closed {
                    return false;
                }
                if state.frame.is_empty() {
                    if let Some(shared) = &self.inbound.counters {
                        shared
                            .counters
                            .held_bytes
                            .fetch_add(encoded.len() as u64, Ordering::Relaxed);
                    }
                    state.frame = encoded;
                    state.offset = 0;
                    if let Some(waker) = state.waker.take() {
                        waker.wake();
                    }
                    return true;
                }
            }
            taken.await;
        }
    }

    /// The connection's stream ends: its reader reads the end, and a frame waiting for it is
    /// one with no connection.
    pub fn close(&self) {
        self.inbound.close();
    }

    pub fn closed(&self) -> bool {
        self.inbound.lock().closed
    }

    pub fn slot(&self) -> &Arc<Slot> {
        &self.slot
    }
}

/// A link's serving end: its one connection, started by a `hello`.
pub struct Link {
    hub: Arc<crate::hub::Hub>,
    v2: Arc<acpmux_core::life::V2>,
    slot: Arc<Slot>,
    running: Option<(Adapter, tokio::task::JoinHandle<Option<()>>)>,
}

impl Link {
    /// The serving end of a link whose writer drains `slot`, when links serve the stream.
    /// The slot this link's connection writes to.
    pub fn slot(&self) -> Arc<Slot> {
        self.slot.clone()
    }

    pub fn serving(hub: &Arc<crate::hub::Hub>, slot: Arc<Slot>) -> Option<Self> {
        let v2 = hub.link_v2.v2()?.clone();
        Some(Self { hub: hub.clone(), v2, slot, running: None })
    }

    fn counters(&self) -> &Counters {
        &self.hub.link_v2.counters
    }

    /// One frame line from the peer. Waits, when a connection runs, until it has read the
    /// frame before; any wait ends when the connection does.
    pub async fn take(&mut self, line: &str) {
        let Some(frame) = parse(line) else {
            self.counters().drop_one();
            return;
        };
        // Its reader gone, a link starts no connection and hands it nothing.
        if self.slot.is_reader_ended() {
            self.end();
            self.counters().drop_one();
            return;
        }
        let running = self.running.as_ref().is_some_and(|(adapter, _)| !adapter.closed());
        if frame.is_hello() {
            if running {
                self.counters().second_hello.fetch_add(1, Ordering::Relaxed);
            }
            self.end();
            self.start();
        } else if !running {
            self.counters().drop_one();
            return;
        }
        let Some((adapter, _)) = &self.running else { return };
        if !adapter.deliver(&frame).await {
            self.counters().drop_one();
        }
    }

    fn start(&mut self) {
        let (adapter, reader, writer) = Adapter::new(self.slot.clone());
        let source = Arc::new(HubSource::for_peer(self.v2.hub()));
        let daemon_id = self.hub.run_id();
        let inbound = adapter.inbound.clone();
        // It ends when its stream does (`end`), or with the daemon.
        let task = self.hub.scope.spawn_until_cancelled("v2 peer link connection", async move {
            // The role is this link's, fixed here: nothing a frame says changes it.
            let surfaces = ["list".to_owned()];
            let result =
                acpmux_core::conn::run(reader, writer, source, daemon_id, &surfaces, Role::Peer)
                    .await;
            if let Err(error) = result {
                tracing::debug!(%error, "a v2 connection on a peer link ended");
            }
            inbound.close();
        });
        self.running = Some((adapter, task));
    }

    /// The link's connection ends: its reader reads the end of the stream, and its writer's
    /// next write fails. A connection that stopped reading (its requests wait on a write) still
    /// sees the end at the write, so its task returns and its subscriptions are cleaned up.
    pub fn end(&mut self) {
        if let Some((adapter, _task)) = self.running.take() {
            adapter.close();
            adapter.slot.retire();
        }
    }
}

/// Held by a transport's read task. Dropped when the reader ends (end of input, a read error,
/// or the abort a revoked credential sends), it ends the link's slot: the link's connection
/// is ended even while the peer stops reading, so revoking a machine stops its access at once.
pub struct ReaderEnd(Option<Arc<Slot>>);

impl ReaderEnd {
    pub fn new(slot: Option<Arc<Slot>>) -> Self {
        Self(slot)
    }
}

impl Drop for ReaderEnd {
    fn drop(&mut self) {
        if let Some(slot) = &self.0 {
            slot.end_reader();
        }
    }
}

impl Drop for Link {
    fn drop(&mut self) {
        self.end();
    }
}

#[cfg(test)]
#[path = "link_v2_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "link_v2_gates.rs"]
mod gates;
