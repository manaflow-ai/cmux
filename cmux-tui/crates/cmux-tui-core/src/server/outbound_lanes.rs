//! The lane order of one connection's outbound queue: which queued item the
//! writer takes next (plans/cmux-next/chrome-parity/p05-ipc.md 3.4, task 072).
//!
//! This is the policy of `cmux_ipc::LaneWriter` (cmux-ipc/src/lane_writer.rs)
//! over the daemon's budgeted items, so a JSON line and a frame queue the same
//! way. Lanes, highest first: input streams, the control FIFO (replies,
//! terminals and control events, kept in `BoundedOutboundState`), bulk
//! streams, background streams. Lanes are strict priority with
//! `STARVATION_BOUND`, as Chromium's
//! base/task/sequence_manager/task_queue_selector.cc keeps low-priority work
//! moving; a starvation grant is never followed by another. Streams of one
//! lane take turns of `STREAM_CREDIT` frames, as QUIC's write scheduler does
//! (net/third_party/quiche/src/quiche/quic/core/quic_write_blocked_list.cc).
//!
//! A frame longer than the connection's chunk size (BULK_FRAME_MAX) leaves
//! as several frames, cut by `LaneWriter`'s rules: the chunk is the
//! preemption boundary, so a reply waits for at most one chunk of a queued
//! snapshot. A JSON line is written whole. `BoundedOutboundState`'s queueing
//! and pop order live here; its budgets stay in server/bounded_outbound.rs.

use super::super::OUTBOUND_BACKPRESSURED_STREAM_CAPACITY;
use super::BoundedOutbound;
use super::BoundedOutboundState;
use super::BudgetedText;
use super::ClientStreams;
use super::ControlOutbound;
use super::OutboundItem;
use super::OutboundStream;
use super::SpaceWoken;
use cmux_ipc::lane_writer::{BULK_FRAME_MAX, STARVATION_BOUND, STREAM_CREDIT};
use cmux_ipc::{
    Aux, BadMessage, CallFlags, FrameHeader, FrameKind, Lane, MAX_FRAME_PAYLOAD, StreamLane,
};
use std::collections::HashMap;
use std::collections::VecDeque;
use std::sync::Arc;

/// The environment variable that sets the daemon's frame cut for a run (the
/// bulk-interference bench sweeps it).
const BULK_FRAME_MAX_ENV: &str = "CMUX_IPC_BULK_FRAME_MAX";

/// Smallest frame cut the variable may set: below it headers dominate.
pub(super) const BULK_FRAME_MIN: usize = 4 * 1024;

/// The daemon's frame cut: `CMUX_IPC_BULK_FRAME_MAX` bytes when it holds a
/// size from `BULK_FRAME_MIN` to `MAX_FRAME_PAYLOAD`, else `BULK_FRAME_MAX`.
/// Read once, when the mux is built.
pub(crate) fn bulk_frame_max_from_env() -> usize {
    parse_bulk_frame_max(std::env::var(BULK_FRAME_MAX_ENV).ok().as_deref())
}

pub(super) fn parse_bulk_frame_max(value: Option<&str>) -> usize {
    value
        .and_then(|value| value.trim().parse::<usize>().ok())
        .filter(|bytes| (BULK_FRAME_MIN..=MAX_FRAME_PAYLOAD as usize).contains(bytes))
        .unwrap_or(BULK_FRAME_MAX)
}

/// A stream item: a line, or a frame's payload and how much of it left.
pub(in crate::server) struct RegularOutbound {
    pub(super) text: Arc<BudgetedText>,
    pub(super) stream: OutboundStream,
    /// The frame's header when `text` is a frame payload; `None` for a line.
    pub(super) frame: Option<FrameHeader>,
    /// Payload bytes already written as chunks.
    sent: usize,
}

impl RegularOutbound {
    pub(super) fn line(text: Arc<BudgetedText>, stream: &OutboundStream) -> Self {
        Self { text, stream: stream.clone(), frame: None, sent: 0 }
    }

    pub(super) fn frame(
        header: FrameHeader,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> Self {
        Self { frame: Some(header), ..Self::line(text, stream) }
    }

    /// The item written whole: the line, or the frame with all its payload.
    fn whole_item(&self) -> OutboundItem {
        match self.frame {
            Some(header) => OutboundItem::Frame(header, self.text.clone()),
            None => OutboundItem::Text(self.text.clone()),
        }
    }
}

/// The turn counters of `LaneWriter::select` and `account_pop`.
#[derive(Debug, Default)]
pub(super) struct LaneTurns {
    control_waited: u32,
    bulk_waited: u32,
    background_waited: u32,
    control_since_bulk: bool,
    control_since_background: bool,
    granted_last: bool,
}

/// Which lanes have something to write.
#[derive(Clone, Copy, Debug, Default)]
pub(super) struct ReadyLanes {
    pub(super) input: bool,
    pub(super) control: bool,
    pub(super) bulk: bool,
    pub(super) background: bool,
}

impl ReadyLanes {
    fn get(self, lane: Lane) -> bool {
        match lane {
            Lane::Input => self.input,
            Lane::Control => self.control,
            Lane::Bulk => self.bulk,
            Lane::Background => self.background,
        }
    }
}

impl LaneTurns {
    /// Frames written while `lane` waited; input never waits.
    fn waited(&self, lane: Lane) -> u32 {
        match lane {
            Lane::Input => 0,
            Lane::Control => self.control_waited,
            Lane::Bulk => self.bulk_waited,
            Lane::Background => self.background_waited,
        }
    }

    fn control_since(&self, lane: Lane) -> bool {
        match lane {
            Lane::Input | Lane::Control => true,
            Lane::Bulk => self.control_since_bulk,
            Lane::Background => self.control_since_background,
        }
    }

    /// The lane of the next item and whether it is a starvation grant. A due
    /// bulk or background lane yields its grant to waiting control when
    /// control has not written since that lane's last item.
    pub(super) fn select(&self, ready: ReadyLanes) -> Option<(Lane, bool)> {
        let highest = Lane::ALL.into_iter().find(|&lane| ready.get(lane))?;
        if self.granted_last {
            return Some((highest, false));
        }
        let due =
            |lane: Lane| lane > highest && ready.get(lane) && self.waited(lane) >= STARVATION_BOUND;
        let lower = [Lane::Bulk, Lane::Background].into_iter().find(|&lane| due(lane));
        let control_waits = Lane::Control > highest && ready.control;
        let control_first = lower.is_some_and(|lane| control_waits && !self.control_since(lane));
        if due(Lane::Control) || control_first {
            return Some((Lane::Control, true));
        }
        lower.map(|lane| (lane, true)).or(Some((highest, false)))
    }

    /// After an item of `lane`, with `ready` read after the pop: `lane`
    /// stops waiting and every other ready lane waited one more item.
    pub(super) fn account_pop(&mut self, lane: Lane, granted: bool, ready: ReadyLanes) {
        self.granted_last = granted;
        let next = |other: Lane| {
            if other != lane && ready.get(other) { self.waited(other).saturating_add(1) } else { 0 }
        };
        (self.control_waited, self.bulk_waited, self.background_waited) =
            (next(Lane::Control), next(Lane::Bulk), next(Lane::Background));
        match lane {
            Lane::Input => {}
            Lane::Control => {
                self.control_since_bulk = true;
                self.control_since_background = true;
            }
            Lane::Bulk => self.control_since_bulk = false,
            Lane::Background => self.control_since_background = false,
        }
    }

    /// `lane` was empty and got an item: it starts waiting from zero.
    pub(super) fn became_ready(&mut self, lane: Lane) {
        match lane {
            Lane::Input => {}
            Lane::Control => self.control_waited = 0,
            Lane::Bulk => self.bulk_waited = 0,
            Lane::Background => self.background_waited = 0,
        }
    }
}

/// The ready streams of one lane in turn order, and the front stream's use
/// of its credit.
#[derive(Debug, Default)]
struct Ring {
    order: VecDeque<u64>,
    turn_used: u32,
}

impl Ring {
    fn remove(&mut self, stream: u64) {
        if let Some(index) = self.order.iter().position(|&id| id == stream) {
            if index == 0 {
                self.turn_used = 0;
            }
            self.order.remove(index);
        }
    }
}

/// What one stream pop gave the writer.
pub(super) enum StreamPop {
    /// The next item or chunk. `done` is the item that left whole with it,
    /// for its stream's budget.
    Item { item: OutboundItem, done: Option<RegularOutbound> },
    /// A chunk header failed frame validation: the owner ends the stream.
    Refused(RegularOutbound),
}

/// The per-stream FIFOs of the input, bulk and background lanes.
pub(super) struct StreamLanes {
    chunk_bytes: usize,
    streams: HashMap<u64, VecDeque<RegularOutbound>>,
    input: Ring,
    bulk: Ring,
    background: Ring,
}

impl StreamLanes {
    pub(super) fn new(chunk_bytes: usize) -> Self {
        Self {
            chunk_bytes: chunk_bytes.max(1),
            streams: HashMap::new(),
            input: Ring::default(),
            bulk: Ring::default(),
            background: Ring::default(),
        }
    }

    fn ring(&mut self, lane: StreamLane) -> &mut Ring {
        match lane {
            StreamLane::Input => &mut self.input,
            StreamLane::Bulk => &mut self.bulk,
            StreamLane::Background => &mut self.background,
        }
    }

    pub(super) fn ready(&self, control: bool) -> ReadyLanes {
        ReadyLanes {
            input: !self.input.order.is_empty(),
            control,
            bulk: !self.bulk.order.is_empty(),
            background: !self.background.order.is_empty(),
        }
    }

    /// Queues `message` on its stream's FIFO; returns the lane when it was
    /// empty before (a lane that may have become ready).
    pub(super) fn push(&mut self, message: RegularOutbound) -> Option<Lane> {
        let (id, lane) = (message.stream.id, message.stream.lane());
        let fifo = self.streams.entry(id).or_default();
        let was_empty = fifo.is_empty();
        fifo.push_back(message);
        if !was_empty {
            return None;
        }
        let ring = self.ring(lane);
        let lane_was_empty = ring.order.is_empty();
        ring.order.push_back(id);
        lane_was_empty.then_some(lane.lane())
    }

    /// Moves `stream`'s place in turn from `from`'s ring to the back of
    /// `to`'s; its FIFO stays as it is. Returns `to`'s lane when it got its
    /// first ready stream.
    pub(super) fn move_stream(
        &mut self,
        stream: u64,
        from: StreamLane,
        to: StreamLane,
    ) -> Option<Lane> {
        if from == to || !self.ring(from).order.contains(&stream) {
            return None;
        }
        self.ring(from).remove(stream);
        let ring = self.ring(to);
        let was_empty = ring.order.is_empty();
        ring.order.push_back(stream);
        was_empty.then_some(to.lane())
    }

    /// Drops what `stream` has queued.
    pub(super) fn purge(&mut self, stream: u64, lane: StreamLane) {
        self.streams.remove(&stream);
        self.ring(lane).remove(stream);
    }

    pub(super) fn clear(&mut self) {
        self.streams.clear();
        for lane in [StreamLane::Input, StreamLane::Bulk, StreamLane::Background] {
            *self.ring(lane) = Ring::default();
        }
    }

    /// The next item or chunk of `lane`'s front stream; `None` when that
    /// stream had nothing left (it leaves the ring).
    pub(super) fn pop(&mut self, lane: StreamLane) -> Option<StreamPop> {
        let chunk_bytes = self.chunk_bytes;
        let stream = *self.ring(lane).order.front()?;
        let Some(fifo) = self.streams.get_mut(&stream) else {
            self.ring(lane).remove(stream);
            return None;
        };
        let Some(front) = fifo.front_mut() else {
            self.streams.remove(&stream);
            self.ring(lane).remove(stream);
            return None;
        };
        let popped = match front.frame.map(|header| next_chunk(header, front, chunk_bytes)) {
            Some(Some(Err(_))) => {
                let message = fifo.pop_front()?;
                self.purge(stream, lane);
                return Some(StreamPop::Refused(message));
            }
            Some(Some(Ok((item, last)))) => {
                let done = if last { fifo.pop_front() } else { None };
                StreamPop::Item { item, done }
            }
            Some(None) | None => {
                let message = fifo.pop_front()?;
                StreamPop::Item { item: message.whole_item(), done: Some(message) }
            }
        };
        let drained = fifo.is_empty();
        if drained {
            self.streams.remove(&stream);
        }
        let ring = self.ring(lane);
        ring.turn_used = ring.turn_used.saturating_add(1);
        if drained {
            ring.order.pop_front();
            ring.turn_used = 0;
        } else if ring.turn_used >= STREAM_CREDIT.max(1) {
            ring.order.rotate_left(1);
            ring.turn_used = 0;
        }
        Some(popped)
    }
}

/// How a kind is cut into chunks (`LaneWriter`'s chunk rule).
#[derive(Clone, Copy)]
enum ChunkRule {
    /// Each chunk carries the PTY offset of its first byte.
    Offset,
    /// SNAPSHOT, then SNAPSHOT_MORE with the same offset.
    Snapshot,
    /// The same call aux, MORE on every chunk but the last, FDS on the first.
    Call,
}

const fn chunk_rule(kind: FrameKind) -> Option<ChunkRule> {
    match kind {
        FrameKind::Output | FrameKind::Replay => Some(ChunkRule::Offset),
        FrameKind::Snapshot | FrameKind::SnapshotMore => Some(ChunkRule::Snapshot),
        FrameKind::Request | FrameKind::Reply | FrameKind::Error | FrameKind::TypedEvent => {
            Some(ChunkRule::Call)
        }
        FrameKind::Grid
        | FrameKind::Event
        | FrameKind::Ring
        | FrameKind::RingAdvance
        | FrameKind::Input
        | FrameKind::SharedBuffer
        | FrameKind::RingAck
        | FrameKind::Cancel => None,
    }
}

/// The next chunk of the frame `message` carries with `header`, and whether
/// it is the last; `None` when the frame leaves whole.
fn next_chunk(
    header: FrameHeader,
    message: &mut RegularOutbound,
    chunk_bytes: usize,
) -> Option<Result<(OutboundItem, bool), BadMessage>> {
    let len = message.text.len();
    let start = message.sent;
    let rule = chunk_rule(header.kind()).filter(|_| start > 0 || len > chunk_bytes)?;
    let end = len.min(start.saturating_add(chunk_bytes));
    let last = end >= len;
    let chunk = chunk_header(header, rule, start, end, last);
    message.sent = end;
    Some(chunk.map(|chunk| {
        (OutboundItem::Chunk { header: chunk, text: message.text.clone(), range: start..end }, last)
    }))
}

/// The header of the chunk carrying payload bytes `start..end`.
fn chunk_header(
    header: FrameHeader,
    rule: ChunkRule,
    start: usize,
    end: usize,
    last: bool,
) -> Result<FrameHeader, BadMessage> {
    let (kind, aux) = match (rule, header.aux()) {
        (ChunkRule::Offset, Aux::Offset(offset)) => {
            (header.kind(), Aux::Offset(offset.saturating_add(start as u64)))
        }
        (ChunkRule::Snapshot, aux) if start > 0 => (FrameKind::SnapshotMore, aux),
        (ChunkRule::Call, Aux::Call(mut call)) => {
            if !last {
                call.flags = call.flags.with(CallFlags::MORE);
            }
            if start > 0 {
                call.flags = call.flags.without(CallFlags::FDS);
            }
            (header.kind(), Aux::Call(call))
        }
        (_, aux) => (header.kind(), aux),
    };
    let len = u32::try_from(end.saturating_sub(start)).unwrap_or(u32::MAX);
    FrameHeader::new(kind, header.stream(), len, aux)
}

impl BoundedOutboundState {
    pub(super) fn new(chunk_bytes: usize) -> Self {
        Self {
            initial: VecDeque::new(),
            control: VecDeque::new(),
            lanes: StreamLanes::new(chunk_bytes),
            turns: LaneTurns::default(),
            stream_usage: HashMap::new(),
            control_messages: 0,
            control_bytes: 0,
            stream_items: 0,
            regular_bytes: 0,
            closed: false,
            writer: Default::default(),
            client_streams: ClientStreams::default(),
            space_woken: SpaceWoken::default(),
            room_waiters: Vec::new(),
        }
    }

    /// Queues an admitted stream item: a control-sequence stream's item goes
    /// to the control FIFO behind every reply enqueued before it, `initial`
    /// state of another stream ahead of everything, the rest to its stream's
    /// FIFO in the stream's lane.
    pub(super) fn enqueue_stream_item(&mut self, message: RegularOutbound, initial: bool) {
        self.stream_items += 1;
        if message.stream.control_sequence {
            self.enqueue_control(ControlOutbound::Stream(message));
        } else if initial {
            self.initial.push_back(message);
        } else if let Some(lane) = self.lanes.push(message) {
            self.turns.became_ready(lane);
        }
    }

    pub(super) fn enqueue_control(&mut self, item: ControlOutbound) {
        if self.control.is_empty() {
            self.turns.became_ready(Lane::Control);
        }
        self.control.push_back(item);
    }

    /// The next item in write order. Any item that leaves frees budget, so
    /// it wakes the room waiters of ordered terminals.
    pub(super) fn pop(&mut self) -> Option<OutboundItem> {
        let item = self.pop_next();
        if item.is_some() {
            self.space_woken.room.append(&mut self.room_waiters);
        }
        item
    }

    fn pop_next(&mut self) -> Option<OutboundItem> {
        if let Some(message) = self.initial.pop_front() {
            self.record_stream_pop(&message);
            return Some(message.whole_item());
        }
        loop {
            let (lane, granted) = self.turns.select(self.lanes.ready(!self.control.is_empty()))?;
            let popped = match lane {
                Lane::Control => self.pop_control(),
                Lane::Input => self.pop_stream(StreamLane::Input),
                Lane::Bulk => self.pop_stream(StreamLane::Bulk),
                Lane::Background => self.pop_stream(StreamLane::Background),
            };
            let ready = self.lanes.ready(!self.control.is_empty());
            self.turns.account_pop(lane, granted, ready);
            if popped.is_some() {
                return popped;
            }
        }
    }

    fn pop_control(&mut self) -> Option<OutboundItem> {
        Some(match self.control.pop_front()? {
            ControlOutbound::Text(text) => {
                self.release_control(text.len());
                OutboundItem::Text(text)
            }
            ControlOutbound::Frame(header, text) => {
                self.release_control(text.len());
                OutboundItem::Frame(header, text)
            }
            ControlOutbound::Stream(message) => {
                self.record_stream_pop(&message);
                message.whole_item()
            }
            ControlOutbound::Flush(flushed) => OutboundItem::Flush(flushed),
        })
    }

    fn release_control(&mut self, bytes: usize) {
        self.control_messages = self.control_messages.saturating_sub(1);
        self.control_bytes = self.control_bytes.saturating_sub(bytes);
    }

    fn pop_stream(&mut self, lane: StreamLane) -> Option<OutboundItem> {
        match self.lanes.pop(lane)? {
            StreamPop::Item { item, done } => {
                if let Some(message) = done {
                    self.record_stream_pop(&message);
                }
                Some(item)
            }
            StreamPop::Refused(message) => {
                // A failed overflow report has closed the connection already.
                let _ = BoundedOutbound::terminate_stream_locked(self, &message.stream);
                None
            }
        }
    }

    fn record_stream_pop(&mut self, message: &RegularOutbound) {
        let bytes = message.text.len();
        self.stream_items = self.stream_items.saturating_sub(1);
        self.regular_bytes = self.regular_bytes.saturating_sub(bytes);
        let Some(usage) = self.stream_usage.get_mut(&message.stream.id) else { return };
        let was_full = usage.messages >= OUTBOUND_BACKPRESSURED_STREAM_CAPACITY;
        usage.messages = usage.messages.saturating_sub(1);
        usage.bytes = usage.bytes.saturating_sub(bytes);
        let remove = usage.messages == 0;
        // A producer that stopped at the cap is woken once the lock is
        // released (`BoundedOutbound::recv`).
        if was_full && message.stream.space_hook.is_set() {
            self.space_woken.streams.push(message.stream.clone());
        }
        if remove {
            self.stream_usage.remove(&message.stream.id);
        }
    }

    /// The streams that got room since the last call, to wake outside the
    /// lock.
    pub(super) fn take_space_woken(&mut self) -> SpaceWoken {
        std::mem::take(&mut self.space_woken)
    }

    /// Whether `stream` holds fewer queued items than its backpressure cap.
    /// A closed connection or stream answers true: the send reports why.
    pub(super) fn has_backpressure_room(&self, stream: &OutboundStream) -> bool {
        self.closed
            || !stream.is_open()
            || self.stream_usage.get(&stream.id).map_or(0, |usage| usage.messages)
                < OUTBOUND_BACKPRESSURED_STREAM_CAPACITY
    }

    /// Closes every stream and drops its items; replies, terminals and
    /// flushes stay.
    pub(super) fn clear_streams(&mut self) {
        for usage in self.stream_usage.values() {
            usage.stream.close();
        }
        self.initial.clear();
        self.lanes.clear();
        self.control.retain(|item| !matches!(item, ControlOutbound::Stream(_)));
        self.stream_usage.clear();
        self.client_streams.clear();
        self.stream_items = 0;
        self.regular_bytes = 0;
    }
}
