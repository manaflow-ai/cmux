//! The outbound priority policy of one framed connection
//! (plans/cmux-next/chrome-parity/p05-ipc.md, sections 3.2 and 3.4, task 052;
//! spec/transports.md "Reply and event order").
//!
//! `LaneWriter` is pure: producers push frames, the connection's writer pops
//! the next frame to write. It does no I/O, takes no lock and never blocks a
//! producer; the owner (the daemon's outbound writer, the app's frame writer)
//! wraps it in its own synchronization.
//!
//! Four lanes, highest first:
//!
//! - `Input`: streams whose items ride the person's input priority (a focused
//!   terminal's output, input echoes).
//! - `Control`: the connection's control sequence, ONE FIFO. Replies, errors,
//!   control events and the items of control-sequence streams leave in the
//!   order they were pushed, so a reply never passes an event emitted before
//!   it. Nothing reorders this FIFO, and a message cut into chunks keeps the
//!   FIFO until its last chunk.
//! - `Bulk`: snapshots, replays, journal and file reads.
//! - `Background`: hidden and idle streams.
//!
//! Every client-minted stream outside the control sequence has its own FIFO
//! and one lane at a time (`set_stream_lane` moves the whole FIFO, so a
//! stream's order never depends on its lane). Streams of one lane take turns:
//! the stream at the front writes at most `stream_credit` frames, then the
//! next ready stream goes, as QUIC's write scheduler rotates streams of equal
//! priority after a batch (chromium
//! net/third_party/quiche/src/quiche/quic/core/quic_write_blocked_list.cc).
//!
//! Lanes are strict priority with a starvation bound, as Chromium's
//! base/task/sequence_manager/task_queue_selector.cc keeps low-priority work
//! moving: control, bulk and background each count the frames written while
//! they were ready and passed over, and at `starvation_bound` the lane is due
//! one frame (a starvation grant). Control goes first: a due bulk or
//! background lane gives its grant to waiting control when control has not
//! written since that lane's last frame, so during an input flood control
//! writes at least once per lower grant. A grant is never
//! followed by another, so a frame of a higher lane waits at most one lower
//! frame. The price is that bulk waits at most `starvation_bound + 2` higher
//! frames (a control grant and the frame after it come first), and background
//! at most `starvation_bound + 4`.
//!
//! A payload longer than `chunk_bytes` leaves as several frames; the chunk is
//! the preemption boundary. Call kinds set `CallFlags::MORE` on every chunk but
//! the last; OUTPUT chunks carry the PTY offset of their first byte; a REPLAY
//! (a meta envelope, not PTY bytes) keeps its cut offset on every chunk; a
//! SNAPSHOT continues as SNAPSHOT_MORE. Other kinds are written whole.
//! Chunks share the pushed payload (`Bytes::slice`), and a pop allocates
//! nothing.
//!
//! The queue is bounded in bytes, as Mojo bounds a pipe's unread data
//! (chromium mojo/public/c/system/quota.h) and reports the overrun instead of
//! blocking the writer: a push that would pass `max_queued_bytes` ends the
//! largest bulk or background stream until the push fits (`take_ended` names
//! each ended stream so the owner can tell the peer and the producer). When no
//! other such stream is left, a bulk or background push ends its own stream
//! (`LaneError::StreamEnded`); an input or control push fails with
//! `LaneError::Overflow`, and the owner closes the connection. Input and
//! control frames are never dropped.
//!
//! Coalescing (task 141) hooks in through the `*_coalescing` pushes: when the
//! unsent tail of the FIFO has the same `CoalesceKey`, it is replaced by what
//! the caller's merge returns, as Blink coalesces continuous input only into
//! the last queued event
//! (third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc).
//! A frame queued in between stops the merge, so coalescing never moves
//! content past an item pushed before it.

use std::collections::{HashMap, VecDeque};
use std::fmt;

use crate::frame::{Aux, BadMessage, CallFlags, Frame, FrameKind, HEADER_LEN, PriorityHint};

/// Default chunk size: the preemption boundary for long payloads. The
/// daemon's outbound writer picks its value from the 16/32/64 KiB bench
/// (task 072).
pub const BULK_FRAME_MAX: usize = 32 * 1024;

/// Frames a stream writes in a row while another stream of its lane is ready.
pub const STREAM_CREDIT: u32 = 2;

/// Frames of higher lanes written in a row while a lower lane waits.
pub const STARVATION_BOUND: u32 = 8;

/// Default byte bound of everything queued: four maximal frames.
pub const MAX_QUEUED_BYTES: usize = 4 * crate::frame::MAX_FRAME_PAYLOAD as usize;

/// A freed FIFO keeps no more than this many slots of capacity.
const IDLE_CAPACITY: usize = 16;

/// An outbound lane, highest priority first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Lane {
    Input,
    Control,
    Bulk,
    Background,
}

impl Lane {
    /// Every lane, highest priority first.
    pub const ALL: [Lane; 4] = [Lane::Input, Lane::Control, Lane::Bulk, Lane::Background];

    /// The lane of a schema priority.
    pub const fn from_priority(priority: PriorityHint) -> Lane {
        match priority {
            PriorityHint::Input => Lane::Input,
            PriorityHint::Control => Lane::Control,
            PriorityHint::Bulk => Lane::Bulk,
            PriorityHint::Background => Lane::Background,
        }
    }
}

/// The lane of a stream with its own FIFO. Control-sequence items go through
/// `LaneWriter::push_control`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StreamLane {
    Input,
    Bulk,
    Background,
}

impl StreamLane {
    /// The outbound lane.
    pub const fn lane(self) -> Lane {
        match self {
            StreamLane::Input => Lane::Input,
            StreamLane::Bulk => Lane::Bulk,
            StreamLane::Background => Lane::Background,
        }
    }

    /// Whether an overflow may end a stream of this lane.
    const fn is_droppable(self) -> bool {
        !matches!(self, StreamLane::Input)
    }
}

/// The policy's numbers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LaneWriterConfig {
    /// Longest payload written as one frame; longer ones are chunked.
    pub chunk_bytes: usize,
    /// Bound on queued bytes (unsent payload plus one header per frame).
    pub max_queued_bytes: usize,
    /// Frames a stream writes per turn among the ready streams of its lane.
    pub stream_credit: u32,
    /// Higher-lane frames written in a row while a lower lane waits.
    pub starvation_bound: u32,
}

impl Default for LaneWriterConfig {
    fn default() -> Self {
        LaneWriterConfig {
            chunk_bytes: BULK_FRAME_MAX,
            max_queued_bytes: MAX_QUEUED_BYTES,
            stream_credit: STREAM_CREDIT,
            starvation_bound: STARVATION_BOUND,
        }
    }
}

/// Identifies frames that replace each other while unsent: the producer
/// derives it from the method or event id and the schema `coalesce` key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CoalesceKey(pub u64);

/// What a successful push did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pushed {
    /// The frame joined the back of its FIFO.
    Queued,
    /// The frame was merged into the FIFO's unsent tail, which had its key.
    Coalesced,
}

/// Why the policy ended a stream on its own.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndReason {
    /// The byte bound was reached and this was the largest droppable stream.
    Overflow,
    /// A chunk of the stream's frame failed frame validation.
    Refused(BadMessage),
}

/// A stream whose queued frames the policy dropped. The owner tells the
/// peer and the producer; pushes to it fail until it is opened again.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EndedStream {
    pub stream: u16,
    /// Bytes that were queued for it, counted like `queued_bytes`.
    pub dropped_bytes: usize,
    pub reason: EndReason,
}

/// Why a push or a stream call was refused. Nothing is queued on an error.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LaneError {
    /// Stream 0 is the control sequence; it has no stream FIFO.
    ControlStream,
    /// No open stream has this id.
    UnknownStream { stream: u16 },
    /// The stream is already open.
    StreamOpen { stream: u16 },
    /// The stream was closed and drains what it has.
    StreamClosing { stream: u16 },
    /// The policy ended the stream (`take_ended`).
    StreamEnded { stream: u16 },
    /// A control-sequence push named a stream that has its own FIFO.
    NotControlSequence { stream: u16 },
    /// A coalescing merge returned a frame of another stream.
    CoalesceChangedStream { stream: u16 },
    /// An input or control push does not fit and no bulk or background
    /// stream is left to end: the peer stopped reading, and the owner closes
    /// the connection.
    Overflow { queued: usize, need: usize, max: usize },
}

impl fmt::Display for LaneError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LaneError::ControlStream => write!(f, "stream 0 is the control sequence"),
            LaneError::UnknownStream { stream } => write!(f, "stream {stream} is not open"),
            LaneError::StreamOpen { stream } => write!(f, "stream {stream} is already open"),
            LaneError::StreamClosing { stream } => write!(f, "stream {stream} is closing"),
            LaneError::StreamEnded { stream } => write!(f, "stream {stream} was ended"),
            LaneError::NotControlSequence { stream } => {
                write!(f, "stream {stream} has its own FIFO, not the control sequence")
            }
            LaneError::CoalesceChangedStream { stream } => {
                write!(f, "coalescing changed the stream of a stream {stream} frame")
            }
            LaneError::Overflow { queued, need, max } => {
                write!(f, "outbound queue of {queued} bytes cannot take {need} more (bound {max})")
            }
        }
    }
}

impl std::error::Error for LaneError {}

/// A queued frame and how much of its payload has been written.
#[derive(Debug)]
struct Queued {
    frame: Frame,
    sent: usize,
    key: Option<CoalesceKey>,
}

impl Queued {
    fn cost(&self) -> usize {
        HEADER_LEN.saturating_add(self.frame.payload().len().saturating_sub(self.sent))
    }
}

/// The cost of a frame not yet queued.
fn frame_cost(frame: &Frame) -> usize {
    HEADER_LEN.saturating_add(frame.payload().len())
}

/// One FIFO: the control sequence or one stream.
#[derive(Debug, Default)]
struct Fifo {
    items: VecDeque<Queued>,
    bytes: usize,
}

/// Makes a payload that `pop` will chunk shareable now: the first slice of a
/// Vec-backed payload allocates, and doing it at push keeps it out of `pop`.
fn prepare_chunks(frame: &Frame, chunk_bytes: usize) {
    if frame.payload().len() > chunk_bytes && chunk_rule(frame.header().kind()).is_some() {
        drop(frame.payload().clone());
    }
}

impl Fifo {
    fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    fn push(&mut self, frame: Frame, key: Option<CoalesceKey>, chunk_bytes: usize) {
        prepare_chunks(&frame, chunk_bytes);
        let item = Queued { frame, sent: 0, key };
        self.bytes = self.bytes.saturating_add(item.cost());
        self.items.push_back(item);
    }

    /// The index of the tail item when it is unsent and has `key`.
    fn coalesce_index(&self, key: CoalesceKey) -> Option<usize> {
        let index = self.items.len().checked_sub(1)?;
        let item = self.items.get(index)?;
        (item.sent == 0 && item.key == Some(key)).then_some(index)
    }

    /// Replaces the unsent item at `index`; returns false if it is gone.
    fn replace(&mut self, index: usize, frame: Frame, chunk_bytes: usize) -> bool {
        let Some(item) = self.items.get_mut(index) else {
            return false;
        };
        prepare_chunks(&frame, chunk_bytes);
        let old = item.cost();
        item.frame = frame;
        let new = item.cost();
        self.bytes = self.bytes.saturating_sub(old).saturating_add(new);
        true
    }

    /// Takes the next frame or chunk of the front item. On a refused chunk
    /// the front item is dropped and the error returned.
    fn pop_chunk(&mut self, chunk_bytes: usize) -> Option<Result<Frame, BadMessage>> {
        let front = self.items.front_mut()?;
        let len = front.frame.payload().len();
        let start = front.sent;
        let rule = chunk_rule(front.frame.header().kind());
        let Some(rule) = rule.filter(|_| start > 0 || len > chunk_bytes) else {
            return self.pop_front_item().map(|item| Ok(item.frame));
        };
        let end = len.min(start.saturating_add(chunk_bytes.max(1)));
        let chunk = chunk_frame(&front.frame, rule, start, end);
        front.sent = end;
        self.bytes = self.bytes.saturating_sub(end.saturating_sub(start));
        if chunk.is_err() || end >= len {
            self.pop_front_item();
        }
        Some(chunk)
    }

    fn pop_front_item(&mut self) -> Option<Queued> {
        let item = self.items.pop_front()?;
        self.bytes = self.bytes.saturating_sub(item.cost());
        if self.items.is_empty() {
            self.release_idle();
        }
        Some(item)
    }

    /// Frees the memory of an empty FIFO beyond a small reserve. Only frees.
    fn release_idle(&mut self) {
        if self.items.capacity() > IDLE_CAPACITY {
            self.items = VecDeque::new();
        }
    }

    /// Drops everything; returns the bytes dropped.
    fn clear(&mut self) -> usize {
        let dropped = self.bytes;
        self.items.clear();
        self.bytes = 0;
        self.release_idle();
        dropped
    }
}

/// How a kind is cut into chunks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ChunkRule {
    /// Each chunk carries the PTY offset of its first byte.
    Offset,
    /// Every chunk keeps the frame's kind and aux: the payload is an
    /// envelope whose bytes are not PTY bytes, so the offset stays the cut.
    SameAux,
    /// SNAPSHOT, then SNAPSHOT_MORE with the same offset.
    Snapshot,
    /// The same call aux, with MORE on every chunk but the last and FDS only
    /// on the first: the descriptors ride with the first chunk.
    Call,
}

const fn chunk_rule(kind: FrameKind) -> Option<ChunkRule> {
    match kind {
        FrameKind::Output => Some(ChunkRule::Offset),
        FrameKind::Replay => Some(ChunkRule::SameAux),
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

/// The frame carrying `frame`'s payload bytes `start..end`.
fn chunk_frame(
    frame: &Frame,
    rule: ChunkRule,
    start: usize,
    end: usize,
) -> Result<Frame, BadMessage> {
    let header = frame.header();
    let last = end >= frame.payload().len();
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
    Frame::new(kind, header.stream(), aux, frame.payload().slice(start..end))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StreamState {
    Open,
    /// Removed once its FIFO drains.
    Closing,
    /// Dropped by the policy; refuses pushes until reopened.
    Ended,
}

#[derive(Debug)]
struct StreamQueue {
    lane: StreamLane,
    state: StreamState,
    fifo: Fifo,
}

/// The ready streams of one lane, in turn order, and the front stream's use
/// of its credit.
#[derive(Debug, Default)]
struct Ring {
    order: VecDeque<u16>,
    turn_used: u32,
}

impl Ring {
    fn remove(&mut self, stream: u16) {
        if let Some(index) = self.order.iter().position(|&id| id == stream) {
            if index == 0 {
                self.turn_used = 0;
            }
            self.order.remove(index);
        }
    }
}

#[derive(Debug, Default)]
struct Rings {
    input: Ring,
    bulk: Ring,
    background: Ring,
}

impl Rings {
    fn get(&self, lane: StreamLane) -> &Ring {
        match lane {
            StreamLane::Input => &self.input,
            StreamLane::Bulk => &self.bulk,
            StreamLane::Background => &self.background,
        }
    }

    fn get_mut(&mut self, lane: StreamLane) -> &mut Ring {
        match lane {
            StreamLane::Input => &mut self.input,
            StreamLane::Bulk => &mut self.bulk,
            StreamLane::Background => &mut self.background,
        }
    }
}

/// The policy. See the module documentation.
#[derive(Debug)]
pub struct LaneWriter {
    config: LaneWriterConfig,
    control: Fifo,
    streams: HashMap<u16, StreamQueue>,
    rings: Rings,
    queued_bytes: usize,
    /// Frames of other lanes written since control last wrote, while it waited.
    control_waited: u32,
    /// Frames of other lanes written since bulk last wrote, while it waited.
    bulk_waited: u32,
    /// Frames of other lanes written since background last wrote, while it waited.
    background_waited: u32,
    /// Control wrote a frame since bulk last wrote.
    control_since_bulk: bool,
    /// Control wrote a frame since background last wrote.
    control_since_background: bool,
    /// The last frame was a starvation grant.
    granted_last: bool,
    ended: VecDeque<EndedStream>,
}

impl Default for LaneWriter {
    fn default() -> Self {
        LaneWriter::new(LaneWriterConfig::default())
    }
}

impl LaneWriter {
    pub fn new(config: LaneWriterConfig) -> LaneWriter {
        LaneWriter {
            config,
            control: Fifo::default(),
            streams: HashMap::new(),
            rings: Rings::default(),
            queued_bytes: 0,
            control_waited: 0,
            bulk_waited: 0,
            background_waited: 0,
            control_since_bulk: false,
            control_since_background: false,
            granted_last: false,
            ended: VecDeque::new(),
        }
    }

    pub fn config(&self) -> LaneWriterConfig {
        self.config
    }

    /// Bytes queued: unsent payload plus one header per queued frame.
    pub fn queued_bytes(&self) -> usize {
        self.queued_bytes
    }

    /// Whether nothing waits to be written.
    pub fn is_empty(&self) -> bool {
        Lane::ALL.into_iter().all(|lane| !self.lane_ready(lane))
    }

    /// The lane of an open or closing stream.
    pub fn stream_lane(&self, stream: u16) -> Option<StreamLane> {
        self.streams
            .get(&stream)
            .filter(|queue| queue.state != StreamState::Ended)
            .map(|queue| queue.lane)
    }

    /// Opens a stream FIFO on `lane`; reopens a stream the policy ended.
    pub fn open_stream(&mut self, stream: u16, lane: StreamLane) -> Result<(), LaneError> {
        if stream == 0 {
            return Err(LaneError::ControlStream);
        }
        match self.streams.get_mut(&stream) {
            Some(queue) if queue.state == StreamState::Ended => {
                queue.lane = lane;
                queue.state = StreamState::Open;
                Ok(())
            }
            Some(_) => Err(LaneError::StreamOpen { stream }),
            None => {
                let queue = StreamQueue { lane, state: StreamState::Open, fifo: Fifo::default() };
                self.streams.insert(stream, queue);
                Ok(())
            }
        }
    }

    /// Moves a stream and everything it has queued to `lane`.
    pub fn set_stream_lane(&mut self, stream: u16, lane: StreamLane) -> Result<(), LaneError> {
        let queue = Self::live_stream(&mut self.streams, stream)?;
        let old = queue.lane;
        if old == lane {
            return Ok(());
        }
        queue.lane = lane;
        if !queue.fifo.is_empty() {
            self.rings.get_mut(old).remove(stream);
            self.mark_ready(stream, lane);
        }
        Ok(())
    }

    /// Closes a stream after what it has queued is written. Idempotent.
    pub fn close_stream(&mut self, stream: u16) {
        let Some(queue) = self.streams.get_mut(&stream) else {
            return;
        };
        if queue.fifo.is_empty() {
            self.streams.remove(&stream);
        } else {
            queue.state = StreamState::Closing;
        }
    }

    /// Drops a stream and what it has queued now; returns the dropped bytes.
    pub fn abort_stream(&mut self, stream: u16) -> usize {
        let Some(mut queue) = self.streams.remove(&stream) else {
            return 0;
        };
        self.rings.get_mut(queue.lane).remove(stream);
        let dropped = queue.fifo.clear();
        self.queued_bytes = self.queued_bytes.saturating_sub(dropped);
        dropped
    }

    /// The next stream the policy ended, oldest first.
    pub fn take_ended(&mut self) -> Option<EndedStream> {
        self.ended.pop_front()
    }

    /// Queues a control-sequence frame: a reply, an error, a control event,
    /// or an item of a control-sequence stream (one without a stream FIFO).
    pub fn push_control(&mut self, frame: Frame) -> Result<Pushed, LaneError> {
        self.check_control(&frame)?;
        self.make_room(frame_cost(&frame), None)?;
        self.queue_control(frame, None);
        Ok(Pushed::Queued)
    }

    /// `push_control`, merged into the unsent control frame with `key`.
    /// `merge` gets the queued frame and the new one and returns the frame
    /// that takes the queued frame's place.
    pub fn push_control_coalescing(
        &mut self,
        frame: Frame,
        key: CoalesceKey,
        merge: impl FnOnce(&Frame, Frame) -> Frame,
    ) -> Result<Pushed, LaneError> {
        self.check_control(&frame)?;
        let Some(index) = self.control.coalesce_index(key) else {
            self.make_room(frame_cost(&frame), None)?;
            self.queue_control(frame, Some(key));
            return Ok(Pushed::Queued);
        };
        let merged = Self::merged(&self.control, index, frame, merge)?;
        self.make_room(Self::growth(&self.control, index, &merged), None)?;
        let before = self.control.bytes;
        self.control.replace(index, merged, self.config.chunk_bytes);
        self.account_change(before, self.control.bytes);
        Ok(Pushed::Coalesced)
    }

    /// Queues a frame on its stream's FIFO.
    pub fn push_stream(&mut self, frame: Frame) -> Result<Pushed, LaneError> {
        let stream = frame.header().stream();
        self.check_stream(stream)?;
        self.make_room(frame_cost(&frame), Some(stream))?;
        self.queue_stream(frame, None)?;
        Ok(Pushed::Queued)
    }

    /// `push_stream`, merged into the stream's unsent frame with `key`; see
    /// `push_control_coalescing`.
    pub fn push_stream_coalescing(
        &mut self,
        frame: Frame,
        key: CoalesceKey,
        merge: impl FnOnce(&Frame, Frame) -> Frame,
    ) -> Result<Pushed, LaneError> {
        let stream = frame.header().stream();
        let queue = self.check_stream(stream)?;
        let Some(index) = queue.fifo.coalesce_index(key) else {
            self.make_room(frame_cost(&frame), Some(stream))?;
            self.queue_stream(frame, Some(key))?;
            return Ok(Pushed::Queued);
        };
        let merged = Self::merged(&queue.fifo, index, frame, merge)?;
        let growth = Self::growth(&queue.fifo, index, &merged);
        self.make_room(growth, Some(stream))?;
        let chunk_bytes = self.config.chunk_bytes;
        let queue = Self::live_stream(&mut self.streams, stream)?;
        let before = queue.fifo.bytes;
        queue.fifo.replace(index, merged, chunk_bytes);
        let after = queue.fifo.bytes;
        self.account_change(before, after);
        Ok(Pushed::Coalesced)
    }

    /// The next frame to write, or `None` when nothing is queued. Allocates
    /// nothing.
    pub fn pop(&mut self) -> Option<Frame> {
        loop {
            let (lane, granted) = self.select()?;
            let popped = match lane {
                Lane::Control => self.pop_control(),
                Lane::Input => self.pop_stream(StreamLane::Input),
                Lane::Bulk => self.pop_stream(StreamLane::Bulk),
                Lane::Background => self.pop_stream(StreamLane::Background),
            };
            self.account_pop(lane, granted);
            if let Some(frame) = popped {
                return Some(frame);
            }
        }
    }

    /// Pops frames into `out` until at least `max_bytes` (headers included)
    /// are in it or nothing is queued: one `writev`. Returns the bytes added.
    /// A batch is written whole, so `max_bytes` near `chunk_bytes` keeps the
    /// preemption boundary.
    pub fn pop_batch(&mut self, out: &mut Vec<Frame>, max_bytes: usize) -> usize {
        let mut bytes = 0_usize;
        while bytes < max_bytes.max(1) {
            let Some(frame) = self.pop() else {
                break;
            };
            bytes = bytes.saturating_add(frame.header().frame_len());
            out.push(frame);
        }
        bytes
    }

    fn lane_ready(&self, lane: Lane) -> bool {
        match lane {
            Lane::Control => !self.control.is_empty(),
            Lane::Input => !self.rings.input.order.is_empty(),
            Lane::Bulk => !self.rings.bulk.order.is_empty(),
            Lane::Background => !self.rings.background.order.is_empty(),
        }
    }

    /// The frames written while `lane` waited; input never waits.
    fn waited(&self, lane: Lane) -> u32 {
        match lane {
            Lane::Input => 0,
            Lane::Control => self.control_waited,
            Lane::Bulk => self.bulk_waited,
            Lane::Background => self.background_waited,
        }
    }

    /// Whether control wrote since `lane` last wrote.
    fn control_since(&self, lane: Lane) -> bool {
        match lane {
            Lane::Input | Lane::Control => true,
            Lane::Bulk => self.control_since_bulk,
            Lane::Background => self.control_since_background,
        }
    }

    /// The lane of the next frame, and whether it is a starvation grant. A
    /// due bulk or background lane yields its grant to waiting control when
    /// control has not written since that lane's last frame.
    fn select(&self) -> Option<(Lane, bool)> {
        let highest = Lane::ALL.into_iter().find(|&lane| self.lane_ready(lane))?;
        if self.granted_last {
            return Some((highest, false));
        }
        let bound = self.config.starvation_bound;
        let due =
            |lane: Lane| lane > highest && self.lane_ready(lane) && self.waited(lane) >= bound;
        let lower = [Lane::Bulk, Lane::Background].into_iter().find(|&lane| due(lane));
        let control_waits = Lane::Control > highest && self.lane_ready(Lane::Control);
        let control_first = lower.is_some_and(|lane| control_waits && !self.control_since(lane));
        if due(Lane::Control) || control_first {
            return Some((Lane::Control, true));
        }
        lower.map(|lane| (lane, true)).or(Some((highest, false)))
    }

    /// After a frame of `lane`: it stops waiting, and every other ready lane
    /// waited one more frame.
    fn account_pop(&mut self, lane: Lane, granted: bool) {
        self.granted_last = granted;
        let next = |other: Lane| {
            if other != lane && self.lane_ready(other) {
                self.waited(other).saturating_add(1)
            } else {
                0
            }
        };
        let (control, bulk, background) =
            (next(Lane::Control), next(Lane::Bulk), next(Lane::Background));
        self.control_waited = control;
        self.bulk_waited = bulk;
        self.background_waited = background;
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

    fn pop_control(&mut self) -> Option<Frame> {
        let before = self.control.bytes;
        let popped = self.control.pop_chunk(self.config.chunk_bytes);
        self.account_change(before, self.control.bytes);
        match popped? {
            Ok(frame) => Some(frame),
            Err(refused) => {
                let reason = EndReason::Refused(refused);
                let dropped = before.saturating_sub(self.control.bytes);
                self.ended.push_back(EndedStream { stream: 0, dropped_bytes: dropped, reason });
                None
            }
        }
    }

    fn pop_stream(&mut self, lane: StreamLane) -> Option<Frame> {
        let stream = *self.rings.get(lane).order.front()?;
        let Some(queue) = self.streams.get_mut(&stream) else {
            self.rings.get_mut(lane).remove(stream);
            return None;
        };
        let before = queue.fifo.bytes;
        let popped = queue.fifo.pop_chunk(self.config.chunk_bytes);
        let (after, drained, closing) =
            (queue.fifo.bytes, queue.fifo.is_empty(), queue.state == StreamState::Closing);
        self.account_change(before, after);
        let frame = match popped {
            Some(Ok(frame)) => frame,
            Some(Err(refused)) => {
                self.end_stream(stream, EndReason::Refused(refused));
                return None;
            }
            None => {
                self.rings.get_mut(lane).remove(stream);
                return None;
            }
        };
        let credit = self.config.stream_credit.max(1);
        let ring = self.rings.get_mut(lane);
        ring.turn_used = ring.turn_used.saturating_add(1);
        if drained {
            ring.order.pop_front();
            ring.turn_used = 0;
            if closing {
                self.streams.remove(&stream);
            }
        } else if ring.turn_used >= credit {
            ring.order.rotate_left(1);
            ring.turn_used = 0;
        }
        Some(frame)
    }

    fn check_control(&self, frame: &Frame) -> Result<(), LaneError> {
        let stream = frame.header().stream();
        if stream != 0 && self.streams.contains_key(&stream) {
            return Err(LaneError::NotControlSequence { stream });
        }
        Ok(())
    }

    fn check_stream(&self, stream: u16) -> Result<&StreamQueue, LaneError> {
        if stream == 0 {
            return Err(LaneError::ControlStream);
        }
        let queue = self.streams.get(&stream).ok_or(LaneError::UnknownStream { stream })?;
        match queue.state {
            StreamState::Open => Ok(queue),
            StreamState::Closing => Err(LaneError::StreamClosing { stream }),
            StreamState::Ended => Err(LaneError::StreamEnded { stream }),
        }
    }

    fn live_stream(
        streams: &mut HashMap<u16, StreamQueue>,
        stream: u16,
    ) -> Result<&mut StreamQueue, LaneError> {
        let queue = streams.get_mut(&stream).ok_or(LaneError::UnknownStream { stream })?;
        match queue.state {
            StreamState::Ended => Err(LaneError::StreamEnded { stream }),
            StreamState::Open | StreamState::Closing => Ok(queue),
        }
    }

    fn queue_control(&mut self, frame: Frame, key: Option<CoalesceKey>) {
        if self.control.is_empty() {
            self.control_waited = 0;
        }
        let before = self.control.bytes;
        self.control.push(frame, key, self.config.chunk_bytes);
        self.account_change(before, self.control.bytes);
    }

    fn queue_stream(&mut self, frame: Frame, key: Option<CoalesceKey>) -> Result<(), LaneError> {
        let stream = frame.header().stream();
        let chunk_bytes = self.config.chunk_bytes;
        let queue = Self::live_stream(&mut self.streams, stream)?;
        let (before, was_empty, lane) = (queue.fifo.bytes, queue.fifo.is_empty(), queue.lane);
        queue.fifo.push(frame, key, chunk_bytes);
        let after = queue.fifo.bytes;
        self.account_change(before, after);
        if was_empty {
            self.mark_ready(stream, lane);
        }
        Ok(())
    }

    /// Puts a stream that just got frames at the back of its lane's turns.
    fn mark_ready(&mut self, stream: u16, lane: StreamLane) {
        let ring = self.rings.get_mut(lane);
        if ring.order.is_empty() {
            match lane {
                StreamLane::Input => {}
                StreamLane::Bulk => self.bulk_waited = 0,
                StreamLane::Background => self.background_waited = 0,
            }
        }
        self.rings.get_mut(lane).order.push_back(stream);
    }

    fn merged(
        fifo: &Fifo,
        index: usize,
        frame: Frame,
        merge: impl FnOnce(&Frame, Frame) -> Frame,
    ) -> Result<Frame, LaneError> {
        let stream = frame.header().stream();
        let Some(queued) = fifo.items.get(index) else {
            return Ok(frame);
        };
        let merged = merge(&queued.frame, frame);
        if merged.header().stream() != queued.frame.header().stream() {
            return Err(LaneError::CoalesceChangedStream { stream });
        }
        Ok(merged)
    }

    /// Bytes the queue grows by when `merged` replaces the item at `index`.
    fn growth(fifo: &Fifo, index: usize, merged: &Frame) -> usize {
        let old = fifo.items.get(index).map_or(0, Queued::cost);
        frame_cost(merged).saturating_sub(old)
    }

    fn account_change(&mut self, before: usize, after: usize) {
        self.queued_bytes = self.queued_bytes.saturating_sub(before).saturating_add(after);
    }

    /// Ends the largest droppable streams until `need` more bytes fit. When
    /// none is left, a droppable pushing stream ends itself.
    fn make_room(&mut self, need: usize, pushing: Option<u16>) -> Result<(), LaneError> {
        let max = self.config.max_queued_bytes;
        let pushing_droppable = pushing.filter(|stream| {
            self.streams.get(stream).is_some_and(|queue| queue.lane.is_droppable())
        });
        if let Some(stream) = pushing_droppable
            && need > max
        {
            self.end_stream(stream, EndReason::Overflow);
            return Err(LaneError::StreamEnded { stream });
        }
        while self.queued_bytes.saturating_add(need) > max {
            let Some(victim) = self.largest_droppable().or(pushing_droppable) else {
                return Err(LaneError::Overflow { queued: self.queued_bytes, need, max });
            };
            self.end_stream(victim, EndReason::Overflow);
            if pushing == Some(victim) {
                return Err(LaneError::StreamEnded { stream: victim });
            }
        }
        Ok(())
    }

    fn largest_droppable(&self) -> Option<u16> {
        self.streams
            .iter()
            .filter(|(_, queue)| queue.lane.is_droppable() && !queue.fifo.is_empty())
            .max_by_key(|(id, queue)| (queue.fifo.bytes, std::cmp::Reverse(**id)))
            .map(|(id, _)| *id)
    }

    /// Drops a stream's frames and records it in `ended`. A closing stream
    /// is removed, since its owner already let go of it; an open one refuses
    /// pushes until reopened.
    fn end_stream(&mut self, stream: u16, reason: EndReason) {
        let Some(queue) = self.streams.get_mut(&stream) else {
            return;
        };
        let lane = queue.lane;
        let dropped = queue.fifo.clear();
        if queue.state == StreamState::Closing {
            self.streams.remove(&stream);
        } else {
            queue.state = StreamState::Ended;
        }
        self.rings.get_mut(lane).remove(stream);
        self.queued_bytes = self.queued_bytes.saturating_sub(dropped);
        self.ended.push_back(EndedStream { stream, dropped_bytes: dropped, reason });
    }
}
