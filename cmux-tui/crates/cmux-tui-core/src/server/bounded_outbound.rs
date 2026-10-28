//! Per-connection bounded outbound queues: the control FIFO and the stream
//! lanes with their item and byte budgets, connection permits, the writer
//! thread loop that frames JSON lines or WebSocket text frames, and the
//! queued message sink over a synchronized TCP stream.
//!
//! Write order (plans/cmux-next/chrome-parity/p05-ipc.md 3.4): `initial`
//! stream state, then the lanes of `cmux_ipc::LaneWriter`, highest first:
//! input streams, the control FIFO, bulk streams, background streams, with
//! its starvation bound (server/outbound_lanes.rs). The control FIFO holds
//! replies, stream terminals and the items of control-sequence streams in
//! enqueue order, so a reply is never written before a control event
//! enqueued ahead of it (spec/transports.md "Reply and event order"). Like
//! Mojo's associated interfaces
//! (mojo/public/cpp/bindings/associated_receiver.h), events and replies that
//! must stay ordered share one pipe; unrelated streams do not. A stream frame
//! longer than the connection's chunk size (BULK_FRAME_MAX) leaves in chunks,
//! so a reply waits for at most one chunk of it.
//!
//! The writer thread takes every ready item, in that order, up to
//! [`WRITE_BATCH_BYTES`] and writes them with one `writev` of their buffers
//! (headers and payloads unconcatenated), as Mojo's
//! `ChannelPosix::WriteOutgoingMessagesWithWritev` (mojo/core/channel_posix.cc)
//! writes its queued messages. A chunk ends its batch, so the one-chunk bound
//! above holds for the batched writer too.
//!
//! On an idle connection a producer writes its item inline, without waking
//! the writer thread (task 140, server/inline_write.rs); what the socket
//! did not take leaves first in the writer's next batch.

use super::BACKPRESSURE_RECHECK;
use super::BudgetedText;
use super::MAX_SERVER_CONNECTIONS;
use super::OUTBOUND_BACKPRESSURED_STREAM_CAPACITY;
use super::OUTBOUND_BYTE_CAPACITY;
use super::OUTBOUND_CAPACITY;
use super::OUTBOUND_CONNECTION_BYTE_CAPACITY;
use super::OUTBOUND_CONNECTION_CAPACITY;
use super::OUTBOUND_CONTROL_BYTE_RESERVE;
use super::OUTBOUND_CONTROL_RESERVE;
use super::OutboundStream;
use super::RoomWaker;
use super::attach_streams::AttachStreamAdmission;
use super::attach_streams::AttachStreamError;
use super::attach_streams::ClientStreamId;
use super::attach_streams::ClientStreams;
use crate::panic_free::RecoverPoison;
use cmux_ipc::FrameHeader;
use cmux_ipc::StreamLane;
use cmux_ipc::lane_writer::BULK_FRAME_MAX;
use cmux_threads::checked::sync as waits;
use cmux_threads::sync::Condvar;
use cmux_threads::sync::Mutex;
use std::collections::HashMap;
use std::collections::VecDeque;
use std::ops::Range;
use std::sync::Arc;
use std::sync::MutexGuard;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::time::Duration;

use crate::stream_interrupt::ReadyHook;

fn duration_millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

#[path = "outbound_lanes.rs"]
mod lanes;
#[path = "queued_sink.rs"]
mod queued_sink;
pub(crate) use lanes::bulk_frame_max_from_env;
use lanes::{LaneTurns, RegularOutbound, StreamLanes};
#[cfg(test)]
pub(super) use queued_sink::websocket_server_frame_header;
pub(super) use queued_sink::{QueuedSink, SinkControl, SynchronizedTcpStream};

#[path = "inline_write.rs"]
mod inline_write;
pub(super) use inline_write::InlineSocket;
use inline_write::WriterState;

#[cfg(test)]
#[path = "bounded_outbound_tests.rs"]
mod tests;

#[path = "outbound_batch.rs"]
mod batch;
#[cfg(any(test, not(unix)))]
pub(super) use batch::write_counted_turn;
#[cfg(test)]
pub(super) use batch::write_line_outbound_item;
#[cfg(unix)]
pub(super) use batch::{BatchPoll, count_sent, write_batch_nonblocking};

pub(super) struct BoundedOutbound {
    pub(super) state: Mutex<BoundedOutboundState>,
    pub(super) changed: Condvar,
    /// Run after an item is queued, an inline write leaves a rest, and
    /// when the queue closes: the mux-io loop's doorbell for a connection it
    /// writes (server/mux_io.rs), which takes items with
    /// [`BoundedOutbound::try_recv_turn`] instead of waiting on `changed`.
    ready: ReadyHook,
    /// How long a write may make no progress before the connection closes,
    /// in milliseconds: the socket's write timeout for the mux-io loop,
    /// which writes without blocking (`MessageWriter::set_write_timeout`).
    write_timeout_ms: AtomicU64,
    /// Where producers write inline when nothing waits; `None` for none.
    inline: Option<InlineSocket>,
}

impl Default for BoundedOutbound {
    fn default() -> Self {
        Self::with_chunk_bytes(BULK_FRAME_MAX)
    }
}

pub(super) struct BoundedOutboundState {
    pub(super) initial: VecDeque<RegularOutbound>,
    pub(super) control: VecDeque<ControlOutbound>,
    /// The FIFOs of input, bulk and background streams.
    lanes: StreamLanes,
    turns: LaneTurns,
    pub(super) stream_usage: HashMap<u64, StreamOutboundUsage>,
    /// Replies and terminals in `control`: the control reserve's use.
    pub(super) control_messages: usize,
    pub(super) control_bytes: usize,
    /// Stream items queued on this connection, wherever their sequence puts
    /// them: the sum of the `stream_usage` messages.
    stream_items: usize,
    pub(super) regular_bytes: usize,
    pub(super) closed: bool,
    writer: WriterState,
    /// Client-minted stream ids held until their terminal is queued
    /// (attach-streams-v1): freeing one is part of queuing its terminal.
    pub(super) client_streams: ClientStreams,
    /// Producers that got room under the lock: woken once it is released.
    space_woken: SpaceWoken,
    /// Drains whose ordered terminal found no room
    /// ([`BoundedOutbound::try_push_ordered_terminal`]): woken by the next
    /// item that leaves the queue, or by its close.
    room_waiters: Vec<RoomWaker>,
}

/// Producers woken under the queue's lock, run once it is released.
#[derive(Default)]
pub(super) struct SpaceWoken {
    /// Streams with a space hook that dropped below their backpressure cap.
    streams: Vec<OutboundStream>,
    /// Room waiters of ordered terminals.
    room: Vec<RoomWaker>,
}

impl SpaceWoken {
    pub(super) fn wake(self) {
        for stream in self.streams {
            stream.space_hook.wake();
        }
        for waker in self.room {
            waker();
        }
    }
}

impl BoundedOutboundState {
    /// `stream`'s terminal is queued (or will never be): nothing more of it
    /// is admitted, and its client-minted id is free.
    fn mark_terminal_queued(&mut self, stream: &OutboundStream) -> bool {
        self.client_streams.release(stream);
        stream.terminal_enqueued.swap(true, Ordering::AcqRel)
    }
}

pub(super) struct StreamOutboundUsage {
    messages: usize,
    bytes: usize,
    stream: OutboundStream,
}

pub(super) enum ControlOutbound {
    Text(Arc<BudgetedText>),
    /// A framed request's REPLY or ERROR: counted like `Text`.
    Frame(FrameHeader, Arc<BudgetedText>),
    /// An item of a control-sequence stream, in FIFO order with replies.
    Stream(RegularOutbound),
    Flush(std::sync::mpsc::SyncSender<()>),
}

pub(super) enum OutboundItem {
    Text(Arc<BudgetedText>),
    /// A frame: `header`, then the text as its payload, with no delimiter.
    Frame(FrameHeader, Arc<BudgetedText>),
    /// One chunk of a longer frame: `header`, then the payload bytes `range`.
    Chunk {
        header: FrameHeader,
        text: Arc<BudgetedText>,
        range: Range<usize>,
    },
    Flush(std::sync::mpsc::SyncSender<()>),
}

#[derive(Clone)]
pub(super) struct ConnectionPermit {
    pub(super) _lease: Arc<ConnectionPermitLease>,
}

pub(super) struct ConnectionPermitLease(Arc<crate::diagnostics::ConnectionStats>);

impl Drop for ConnectionPermitLease {
    fn drop(&mut self) {
        self.0.release();
    }
}

pub(super) fn claim_connection(
    connections: &Arc<crate::diagnostics::ConnectionStats>,
) -> Option<ConnectionPermit> {
    connections
        .try_claim(MAX_SERVER_CONNECTIONS as u64)
        .then(|| ConnectionPermit { _lease: Arc::new(ConnectionPermitLease(connections.clone())) })
}

impl BoundedOutbound {
    /// A queue whose stream frames longer than `chunk_bytes` leave in chunks.
    pub(super) fn with_chunk_bytes(chunk_bytes: usize) -> Self {
        Self {
            state: Mutex::new(BoundedOutboundState::new(chunk_bytes)),
            changed: Condvar::new(),
            ready: ReadyHook::default(),
            write_timeout_ms: AtomicU64::new(duration_millis(super::STREAM_WRITE_TIMEOUT)),
            inline: None,
        }
    }

    /// Runs `hook` after each queued item and at the close; false when a
    /// hook is set already.
    pub(super) fn on_ready(&self, hook: impl Fn() + Send + Sync + 'static) -> bool {
        self.ready.set(hook)
    }

    /// An item was queued or the queue closed: wake whoever writes it.
    fn notify_item(&self) {
        self.changed.notify_all();
        self.ready.wake();
    }

    /// How long a write may make no progress before the connection closes.
    pub(super) fn write_timeout(&self) -> Duration {
        Duration::from_millis(self.write_timeout_ms.load(Ordering::Relaxed))
    }

    /// Sets [`Self::write_timeout`]; `None` keeps the current one (a socket
    /// with no write timeout would wait for a stuck peer forever).
    pub(super) fn set_write_timeout(&self, timeout: Option<Duration>) {
        if let Some(timeout) = timeout {
            self.write_timeout_ms.store(duration_millis(timeout).max(1), Ordering::Relaxed);
        }
    }

    pub(super) fn push_regular(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.push_stream_item(RegularOutbound::line(text, stream), false)
    }

    pub(super) fn push_initial(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.push_stream_item(RegularOutbound::line(text, stream), true)
    }

    /// Queues `text` as the payload of a frame with `header` on `stream`'s
    /// FIFO; it leaves in chunks when longer than the connection's cut.
    pub(super) fn push_stream_frame(
        &self,
        header: FrameHeader,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        if header.len() as usize != text.len() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "a frame header's length differs from its payload",
            ));
        }
        self.push_stream_item(RegularOutbound::frame(header, text, stream), false)
    }

    fn push_stream_item(&self, message: RegularOutbound, initial: bool) -> std::io::Result<()> {
        let mut state = self.state.lock().recover_poison();
        let wire_bytes = message.frame.map_or(message.text.len() + 1, |header| header.frame_len());
        let inline = self.inline_ready(&state, wire_bytes);
        let result = Self::push_regular_locked(&mut state, message, initial);
        let finished = self.finish_push(state, inline && result.is_ok());
        result.and(finished)
    }

    pub(super) fn push_regular_backpressured(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().recover_poison();
        loop {
            if state.closed {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "connection closed",
                ));
            }
            if !stream.is_open() {
                return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stream closed"));
            }
            let pending =
                state.stream_usage.get(&stream.id).map(|usage| usage.messages).unwrap_or_default();
            if pending < OUTBOUND_BACKPRESSURED_STREAM_CAPACITY {
                let inline = self.inline_ready(&state, text.len() + 1);
                let message = RegularOutbound::line(text, stream);
                let result = Self::push_regular_locked(&mut state, message, false);
                let finished = self.finish_push(state, inline && result.is_ok());
                return result.and(finished);
            }
            let (next, _) = self.changed.wait_timeout(state, BACKPRESSURE_RECHECK).recover_poison();
            state = next;
        }
    }

    pub(super) fn push_regular_locked(
        state: &mut BoundedOutboundState,
        message: RegularOutbound,
        initial: bool,
    ) -> std::io::Result<()> {
        let stream = &message.stream;
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        if !stream.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stream closed"));
        }
        let bytes = message.text.len();
        if bytes > OUTBOUND_BYTE_CAPACITY {
            Self::terminate_stream_locked(state, stream)?;
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound queue overflowed",
            ));
        }
        let (stream_messages, stream_bytes) = state
            .stream_usage
            .get(&stream.id)
            .map(|usage| (usage.messages, usage.bytes))
            .unwrap_or_default();
        if stream_messages >= OUTBOUND_CAPACITY
            || bytes > OUTBOUND_BYTE_CAPACITY.saturating_sub(stream_bytes)
        {
            Self::terminate_stream_locked(state, stream)?;
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound stream queue overflowed",
            ));
        }
        loop {
            let byte_full =
                bytes > OUTBOUND_CONNECTION_BYTE_CAPACITY.saturating_sub(state.regular_bytes);
            let count_full = state.stream_items >= OUTBOUND_CONNECTION_CAPACITY;
            if !byte_full && !count_full {
                break;
            }
            let Some(victim) = Self::largest_stream(state, byte_full) else {
                Self::terminate_stream_locked(state, stream)?;
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "outbound queue overflowed",
                ));
            };
            let incoming_terminated = victim.id == stream.id;
            Self::terminate_stream_locked(state, &victim)?;
            if incoming_terminated {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "outbound queue overflowed",
                ));
            }
        }
        Self::admit_stream_item_locked(state, message, initial);
        Ok(())
    }

    /// Counts an item that fits in its stream's and the connection's
    /// budgets, and queues it.
    fn admit_stream_item_locked(
        state: &mut BoundedOutboundState,
        message: RegularOutbound,
        initial: bool,
    ) {
        let bytes = message.text.len();
        state.regular_bytes += bytes;
        let usage = state.stream_usage.entry(message.stream.id).or_insert_with(|| {
            StreamOutboundUsage { messages: 0, bytes: 0, stream: message.stream.clone() }
        });
        usage.messages += 1;
        usage.bytes += bytes;
        state.enqueue_stream_item(message, initial);
    }

    /// Takes `stream`'s client-minted id until its terminal is queued.
    pub(super) fn claim_client_stream(
        &self,
        stream: &OutboundStream,
        admission: &Arc<AttachStreamAdmission>,
    ) -> Result<(), AttachStreamError> {
        self.state.lock().recover_poison().client_streams.claim(stream, admission)
    }

    pub(super) fn client_stream(&self, id: ClientStreamId) -> Option<OutboundStream> {
        self.state.lock().recover_poison().client_streams.get(id)
    }

    /// Moves `stream` to `lane` (`set-stream-priority`): what it
    /// still queues keeps its order and is written in `lane`'s turn from now
    /// on, as is every later item. Under the lock every lane read holds.
    pub(super) fn set_stream_lane(&self, stream: &OutboundStream, lane: StreamLane) {
        let mut state = self.state.lock().recover_poison();
        let old = stream.lane();
        if old == lane {
            return;
        }
        stream.set_lane_locked(lane);
        if let Some(ready) = state.lanes.move_stream(stream.id, old, lane) {
            state.turns.became_ready(ready);
        }
        drop(state);
        self.notify_item();
    }

    pub(super) fn push_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        let mut state = self.state.lock().recover_poison();
        let inline = self.inline_ready(&state, text.len() + 1);
        Self::push_control_locked(&mut state, text)?;
        self.finish_push(state, inline)
    }

    pub(super) fn flush_control(&self, timeout: Duration) -> std::io::Result<()> {
        let (flushed_tx, flushed_rx) = std::sync::mpsc::sync_channel(1);
        let mut state = self.state.lock().recover_poison();
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        state.enqueue_control(ControlOutbound::Flush(flushed_tx));
        drop(state);
        self.notify_item();
        match waits::recv_timeout(&flushed_rx, timeout) {
            Ok(()) => Ok(()),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "timed out while flushing the shutdown response",
            )),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "connection closed while flushing the shutdown response",
            )),
        }
    }

    pub(super) fn push_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().recover_poison();
        stream.close();
        Self::purge_stream_locked(&mut state, stream.id);
        if state.mark_terminal_queued(stream) {
            return Ok(());
        }
        Self::push_control_locked(&mut state, text)?;
        drop(state);
        self.notify_item();
        Ok(())
    }

    /// Ends `stream` now: closes it, drops its unwritten items, and queues
    /// `text` in the control FIFO, in one step. Unlike `push_terminal`, it
    /// queues `text` when the stream queued its own terminal already.
    pub(super) fn push_stream_end(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().recover_poison();
        stream.close();
        Self::purge_stream_locked(&mut state, stream.id);
        state.mark_terminal_queued(stream);
        Self::push_control_locked(&mut state, text)?;
        drop(state);
        self.notify_item();
        Ok(())
    }

    /// Gracefully closes a stream after every item already admitted for it.
    ///
    /// Overflow and cancellation use `push_terminal`, which intentionally
    /// purges stale items. Successful bounded replay must preserve FIFO order.
    pub(super) fn push_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().recover_poison();
        while !Self::admit_ordered_terminal_locked(&mut state, &text, stream)? {
            let (next, _) = self.changed.wait_timeout(state, BACKPRESSURE_RECHECK).recover_poison();
            state = next;
        }
        drop(state);
        self.notify_item();
        Ok(())
    }

    /// [`Self::push_ordered_terminal`] for a producer that must not wait (a
    /// drain on the sequenced pool): `Ok(false)` while the stream or the
    /// connection has no room for the terminal; the queue then holds
    /// `on_room` and runs it once an item leaves it or it closes.
    pub(super) fn try_push_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
        on_room: RoomWaker,
    ) -> std::io::Result<bool> {
        let mut state = self.state.lock().recover_poison();
        if !Self::admit_ordered_terminal_locked(&mut state, &text, stream)? {
            state.room_waiters.push(on_room);
            return Ok(false);
        }
        drop(state);
        self.notify_item();
        Ok(true)
    }

    /// Queues `stream`'s ordered terminal behind its items if the stream's
    /// and the connection's budgets have room: false when they do not.
    fn admit_ordered_terminal_locked(
        state: &mut BoundedOutboundState,
        text: &Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<bool> {
        let bytes = text.len();
        if bytes > OUTBOUND_BYTE_CAPACITY {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound stream terminal exceeds its byte capacity",
            ));
        }
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        if stream.terminal_enqueued.load(Ordering::Acquire) {
            return Ok(true);
        }
        if !stream.is_open() {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stream closed"));
        }
        let (stream_messages, stream_bytes) = state
            .stream_usage
            .get(&stream.id)
            .map(|usage| (usage.messages, usage.bytes))
            .unwrap_or_default();
        let stream_full = stream_messages >= OUTBOUND_CAPACITY
            || bytes > OUTBOUND_BYTE_CAPACITY.saturating_sub(stream_bytes);
        let connection_full = state.stream_items >= OUTBOUND_CONNECTION_CAPACITY
            || bytes > OUTBOUND_CONNECTION_BYTE_CAPACITY.saturating_sub(state.regular_bytes);
        if stream_full || connection_full {
            return Ok(false);
        }
        Self::admit_stream_item_locked(state, RegularOutbound::line(text.clone(), stream), false);
        state.mark_terminal_queued(stream);
        stream.close();
        Ok(true)
    }

    pub(super) fn terminate_stream_locked(
        state: &mut BoundedOutboundState,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        stream.close();
        Self::purge_stream_locked(state, stream.id);
        if state.mark_terminal_queued(stream) {
            return Ok(());
        }
        let overflow_text = stream.overflow_text.lock().recover_poison().clone();
        if let Err(error) = Self::push_control_locked(state, overflow_text) {
            state.closed = true;
            return Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                format!("could not report stream overflow: {error}"),
            ));
        }
        Ok(())
    }

    pub(super) fn purge_stream_locked(state: &mut BoundedOutboundState, stream_id: u64) {
        let Some(usage) = state.stream_usage.remove(&stream_id) else {
            return;
        };
        state.initial.retain(|message| message.stream.id != stream_id);
        state.control.retain(
            |item| !matches!(item, ControlOutbound::Stream(message) if message.stream.id == stream_id),
        );
        state.lanes.purge(stream_id, usage.stream.lane());
        state.stream_items = state.stream_items.saturating_sub(usage.messages);
        state.regular_bytes = state.regular_bytes.saturating_sub(usage.bytes);
    }

    pub(super) fn largest_stream(
        state: &BoundedOutboundState,
        by_bytes: bool,
    ) -> Option<OutboundStream> {
        state
            .stream_usage
            .values()
            .filter(|usage| !usage.stream.terminal_enqueued.load(Ordering::Acquire))
            .max_by_key(|usage| if by_bytes { usage.bytes } else { usage.messages })
            .map(|usage| usage.stream.clone())
    }

    /// Queues a framed request's reply in the control FIFO, under the same
    /// reserve as a reply line.
    pub(super) fn push_frame(
        &self,
        header: FrameHeader,
        text: Arc<BudgetedText>,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().recover_poison();
        let inline = self.inline_ready(&state, header.frame_len());
        Self::admit_control_locked(&mut state, text.len())?;
        state.enqueue_control(ControlOutbound::Frame(header, text));
        self.finish_push(state, inline)
    }

    pub(super) fn push_control_locked(
        state: &mut BoundedOutboundState,
        text: Arc<BudgetedText>,
    ) -> std::io::Result<()> {
        Self::admit_control_locked(state, text.len())?;
        state.enqueue_control(ControlOutbound::Text(text));
        Ok(())
    }

    /// Counts one control message of `bytes` against the control reserve.
    fn admit_control_locked(state: &mut BoundedOutboundState, bytes: usize) -> std::io::Result<()> {
        if state.closed {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "connection closed"));
        }
        if state.control_messages >= OUTBOUND_CONTROL_RESERVE
            || bytes > OUTBOUND_CONTROL_BYTE_RESERVE.saturating_sub(state.control_bytes)
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "outbound control reserve overflowed",
            ));
        }
        state.control_messages += 1;
        state.control_bytes += bytes;
        Ok(())
    }

    /// The next item's text (a frame's payload, a chunk's bytes), in write
    /// order.
    #[cfg(test)]
    pub(super) fn try_pop(&self) -> Option<String> {
        loop {
            let mut state = self.state.lock().recover_poison();
            let item = state.pop();
            let woken = state.take_space_woken();
            drop(state);
            if item.is_some() {
                self.changed.notify_all();
            }
            woken.wake();
            match item? {
                OutboundItem::Text(text) | OutboundItem::Frame(_, text) => {
                    return Some(text.to_string());
                }
                OutboundItem::Chunk { text, range, .. } => {
                    let bytes = text.as_bytes().get(range).unwrap_or_default();
                    return Some(String::from_utf8_lossy(bytes).into_owned());
                }
                OutboundItem::Flush(flushed) => {
                    let _ = flushed.send(());
                }
            }
        }
    }

    /// The writer's next item, or `None` once the queue is closed and empty.
    /// Only the connection's writer (`mux-line-out`, `mux-ws-out`) calls it,
    /// at the top of its loop: with nothing queued it is idle, holding no
    /// one else's work, so the wait is an idle wait (Chromium's
    /// `WaitableEvent::declare_only_used_while_idle`, which
    /// `MessagePumpDefault` uses), not a blocking call (p02-threads 308).
    pub(super) fn recv(&self) -> Option<OutboundItem> {
        let mut state = self.state.lock().recover_poison();
        loop {
            if let Some(item) = state.pop() {
                let woken = state.take_space_woken();
                drop(state);
                self.changed.notify_all();
                woken.wake();
                return Some(item);
            }
            if state.closed {
                return None;
            }
            state = self.changed.idle().wait(state).recover_poison();
        }
    }

    pub(super) fn is_open(&self) -> bool {
        !self.state.lock().recover_poison().closed
    }

    /// Stream items queued on the connection, against its budget.
    #[cfg(test)]
    pub(super) fn queued_stream_items(&self) -> usize {
        self.state.lock().recover_poison().stream_items
    }

    pub(super) fn has_backpressure_room(&self, stream: &OutboundStream) -> bool {
        self.state.lock().recover_poison().has_backpressure_room(stream)
    }

    pub(super) fn close(&self) {
        let mut state = self.state.lock().recover_poison();
        state.closed = true;
        state.control.retain(|item| !matches!(item, ControlOutbound::Flush(_)));
        state.client_streams.clear();
        self.release_closed(state);
    }

    pub(super) fn abort(&self) {
        let mut state = self.state.lock().recover_poison();
        state.closed = true;
        state.drop_rest();
        state.clear_streams();
        state.control.clear();
        state.control_messages = 0;
        state.control_bytes = 0;
        self.release_closed(state);
    }

    pub(super) fn close_after_control(&self) {
        let mut state = self.state.lock().recover_poison();
        state.clear_streams();
        state.closed = true;
        self.release_closed(state);
    }

    /// Unlocks a queue that just closed and wakes everything waiting on it:
    /// a room waiter sees the close and ends its stream.
    fn release_closed(&self, mut state: MutexGuard<'_, BoundedOutboundState>) {
        let room = std::mem::take(&mut state.room_waiters);
        drop(state);
        self.notify_item();
        for waker in room {
            waker();
        }
    }
}
