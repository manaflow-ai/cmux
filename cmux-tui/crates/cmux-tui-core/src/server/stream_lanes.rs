//! A connection's stream sequences and the stream barrier
//! (plans/cmux-next/chrome-parity/p05-ipc.md section 3.4, task p05-ipc-073).
//!
//! Each stream a connection opens (attach-streams, p05-ipc-074) is its own
//! [`Sequence`] on the daemon-wide pool, at the stream's priority: its items
//! run in order, and a stream whose PTY write waits for POLLOUT holds only
//! its own sequence, never another stream's or the connection's control
//! sequence. Mojo keeps the same rule per message pipe: messages on one
//! endpoint keep their order, two endpoints are independent
//! (mojo/core/README.md).
//!
//! The stream barrier keeps the one order a person can see across them: a
//! control command whose target surface has an open stream on this
//! connection runs only after that stream ran every item queued before the
//! command arrived. So "exit\n" sent on the stream and then close-surface
//! sent on control closes the surface after the shell read its exit. A
//! method whose schema entry carries `crosses_stream_ok` (with its reason)
//! is exempt.
//!
//! A closed stream takes no new item, but its sequence still runs what it
//! held: its lane stays, marked closing, until that ran. The barrier still
//! fences on it, and its id opens again only after it drained, so a stream
//! id names one FIFO at a time. A closing lane leaves at the next open,
//! close or barrier that finds its sequence idle.
//!
//! The person-input lane (p01-process-235) is one more sequence of the
//! connection, at input priority: the person's keys, pastes, scrolls and
//! view focus that the verified app sends on its control stream run there,
//! ahead of whatever automation queued on control and on input workers that
//! no control or bulk work takes. Blink gives input its own task queue at
//! the highest priority for the same reason
//! (third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc,
//! `input_task_queue_`). Person input overtakes only control requests of
//! other surfaces: while control holds a request of its surface, or a
//! stream of its surface holds items, it stays on control, and a control
//! command of a surface the lane holds input for is fenced on the lane like
//! on a stream. Behind the default-off daemon feature
//! [`PERSON_INPUT_LANE_FEATURE`].
//!
//! [`StreamLanes`] has no lock of its own: it lives in the connection's
//! scheduler state (`ConnectionSurfaceState`), so a stream post and a
//! control arrival are ordered by that one lock.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_ipc::MethodTables;

use super::CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY;
use super::Command;
use super::sequenced_pool::{Fenced, PostError, Sequence, SequencePriority, SequencedPool};
use crate::SurfaceId;

/// The registry name of the daemon feature that turns the person-input lane
/// on (schemas/features/features.d/daemonPersonInputLane.json).
pub(crate) const PERSON_INPUT_LANE_FEATURE: &str = "daemonPersonInputLane";

/// Whether the verified app's person input runs on its connection's
/// person-input lane; one per mux, read with one relaxed load per request.
#[derive(Debug, Default)]
pub(crate) struct PersonInputLaneGate(AtomicBool);

impl PersonInputLaneGate {
    /// From `CMUX_ENABLE_FEATURES` and `CMUX_DISABLE_FEATURES` (disable
    /// wins), for a mux no owner installs features on (tests); the owner sets
    /// its channel-resolved value at start (`install_daemon_features`).
    pub(crate) fn from_env() -> Self {
        Self(AtomicBool::new(cmux_features::listed_in_env(PERSON_INPUT_LANE_FEATURE)))
    }

    pub(crate) fn enabled(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }

    /// The owner's resolved value, set once at start (`install_daemon_features`).
    pub(crate) fn set(&self, enabled: bool) {
        self.0.store(enabled, Ordering::Relaxed);
    }

    #[cfg(test)]
    pub(crate) fn set_for_test(&self, enabled: bool) {
        self.set(enabled);
    }
}

/// The surface of `cmd` when it is the person's own input to a view: a key,
/// a paste, a scroll, a pointer or wheel event, or the view's focus. A
/// `send` by terminal id (a terminal still being created) is not: its
/// order with the create that makes the terminal is the control order.
pub(super) fn person_input_surface(cmd: &Command) -> Option<SurfaceId> {
    match cmd {
        Command::Send(_)
        | Command::SendKey(_)
        | Command::PasteImage(_)
        | Command::ScrollSurface(_)
        | Command::NoteSizeActivity { .. }
        | Command::BrowserKey { .. }
        | Command::BrowserKeyPress { .. }
        | Command::BrowserInsertText { .. }
        | Command::BrowserMouse { .. }
        | Command::BrowserMouseGuarded { .. }
        | Command::BrowserWheel { .. }
        | Command::BrowserWheelGuarded { .. }
        | Command::BrowserActivate { .. } => cmd.ordering_surface(),
        _ => None,
    }
}

/// Why a stream did not open.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StreamOpenError {
    /// Stream 0 is the connection's control stream.
    ControlStream,
    /// The id names an open stream, or a closed one that still runs the
    /// items it held (`stream_in_use`).
    InUse,
}

/// Why a stream item was not queued. It did not run and never will.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StreamPostError {
    /// No open stream has the id.
    UnknownStream,
    /// The stream's sequence holds its cap of queued items: known not
    /// delivered.
    Full,
    /// The pool shut down.
    ShutDown,
    /// No worker of the stream's priority runs and none could start.
    NoWorker,
}

impl From<PostError> for StreamPostError {
    fn from(error: PostError) -> Self {
        match error {
            PostError::Full => Self::Full,
            PostError::ShutDown => Self::ShutDown,
            PostError::NoWorker => Self::NoWorker,
        }
    }
}

impl std::fmt::Display for StreamPostError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::UnknownStream => "no open stream has this id",
            Self::Full => "stream queue is full; item was not delivered",
            Self::ShutDown => "sequenced pool shut down",
            Self::NoWorker => "could not start a sequenced pool worker",
        })
    }
}

impl std::error::Error for StreamPostError {}

struct StreamLane {
    surface: SurfaceId,
    sequence: Sequence,
    /// Closed: no new item; it leaves once its sequence is idle.
    closing: bool,
}

/// The person-input lane: its sequence and what it holds.
struct PersonLane {
    sequence: Sequence,
    /// Queued or running items, by target surface.
    surfaces: HashMap<SurfaceId, usize>,
    items: usize,
    bytes: usize,
}

/// The open streams of one connection, by stream id, and its person-input
/// lane.
#[derive(Default)]
pub(crate) struct StreamLanes {
    streams: HashMap<u16, StreamLane>,
    person: Option<PersonLane>,
}

impl StreamLanes {
    /// Opens stream `stream` for `surface` as a new sequence at `priority`.
    pub(crate) fn open(
        &mut self,
        pool: &SequencedPool,
        stream: u16,
        surface: SurfaceId,
        priority: SequencePriority,
    ) -> Result<(), StreamOpenError> {
        if stream == 0 {
            return Err(StreamOpenError::ControlStream);
        }
        self.prune_drained();
        if self.streams.contains_key(&stream) {
            return Err(StreamOpenError::InUse);
        }
        self.streams.insert(
            stream,
            StreamLane { surface, sequence: pool.sequence(priority), closing: false },
        );
        Ok(())
    }

    /// Closes stream `stream`: no new item is queued on it, and the items it
    /// holds still run in order (a control command fenced on it, or arriving
    /// before they ran, is released after them). False when no open stream
    /// has the id.
    pub(crate) fn close(&mut self, stream: u16) -> bool {
        let closed = match self.streams.get_mut(&stream) {
            Some(lane) if !lane.closing => {
                lane.closing = true;
                true
            }
            _ => false,
        };
        self.prune_drained();
        closed
    }

    /// Drops the closing lanes whose sequence ran everything it held.
    fn prune_drained(&mut self) {
        self.streams.retain(|_, lane| !lane.closing || !lane.sequence.is_idle());
    }

    fn open_lane(&self, stream: u16) -> Option<&StreamLane> {
        self.streams.get(&stream).filter(|lane| !lane.closing)
    }

    /// Queues `item` on stream `stream` behind its earlier items.
    pub(crate) fn post<F>(&self, stream: u16, item: F) -> Result<(), StreamPostError>
    where
        F: FnOnce() + Send + 'static,
    {
        let lane = self.open_lane(stream).ok_or(StreamPostError::UnknownStream)?;
        lane.sequence.post(item).map_err(StreamPostError::from)
    }

    /// The surface stream `stream` belongs to.
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "INPUT frames (p05-ipc-078) route by the stream's surface")
    )]
    pub(crate) fn surface(&self, stream: u16) -> Option<SurfaceId> {
        self.open_lane(stream).map(|lane| lane.surface)
    }

    /// Queued plus running items of stream `stream`.
    #[cfg(test)]
    pub(crate) fn depth(&self, stream: u16) -> Option<usize> {
        self.open_lane(stream).map(|lane| lane.sequence.depth())
    }

    /// No stream is open and the person-input lane holds nothing.
    pub(crate) fn is_empty(&self) -> bool {
        self.streams.is_empty() && self.person_items() == 0
    }

    /// Whether person input for `surface` may take the person-input lane:
    /// no stream of `surface` holds an item it would pass.
    pub(crate) fn person_may_pass_streams(&self, surface: SurfaceId) -> bool {
        !self.streams.values().any(|lane| lane.surface == surface && !lane.sequence.is_idle())
    }

    /// Queues person input `item` for `surface`, `bytes` long, on the
    /// person-input lane behind the earlier person input (the lane opens at
    /// its first item). A full lane refuses it: known not delivered.
    /// Returns the lane's items with this one. The item reports its end
    /// through [`Self::person_ran`].
    pub(crate) fn post_person<F>(
        &mut self,
        pool: &SequencedPool,
        surface: SurfaceId,
        bytes: usize,
        item: F,
    ) -> Result<usize, StreamPostError>
    where
        F: FnOnce() + Send + 'static,
    {
        let lane = self.person.get_or_insert_with(|| PersonLane {
            sequence: pool.sequence(SequencePriority::Input),
            surfaces: HashMap::new(),
            items: 0,
            bytes: 0,
        });
        if bytes > CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY.saturating_sub(lane.bytes) {
            return Err(StreamPostError::Full);
        }
        lane.sequence.post(item)?;
        lane.items += 1;
        lane.bytes += bytes;
        *lane.surfaces.entry(surface).or_default() += 1;
        Ok(lane.items)
    }

    /// A person-input item for `surface`, `bytes` long, ran (or unwound).
    pub(crate) fn person_ran(&mut self, surface: SurfaceId, bytes: usize) {
        let Some(lane) = self.person.as_mut() else { return };
        lane.items = lane.items.saturating_sub(1);
        lane.bytes = lane.bytes.saturating_sub(bytes);
        if let Some(count) = lane.surfaces.get_mut(&surface) {
            *count -= 1;
            if *count == 0 {
                lane.surfaces.remove(&surface);
            }
        }
    }

    /// Person-input items queued or running.
    pub(crate) fn person_items(&self) -> usize {
        self.person.as_ref().map_or(0, |lane| lane.items)
    }

    /// The stream barrier for a control command on `surface`: `then` runs
    /// once every stream of `surface`, open or closing, and the person-input
    /// lane when it holds input for `surface`, ran the items it holds now.
    /// [`Fenced::Drained`] hands `then` back when none holds an item, and
    /// the command goes on at once.
    pub(crate) fn barrier<F>(
        &mut self,
        pool: &SequencedPool,
        surface: SurfaceId,
        then: F,
    ) -> Fenced<F>
    where
        F: FnOnce() + Send + 'static,
    {
        self.prune_drained();
        let person = self
            .person
            .as_ref()
            .filter(|lane| lane.surfaces.contains_key(&surface))
            .map(|lane| &lane.sequence);
        let sequences: Vec<&Sequence> = self
            .streams
            .values()
            .filter(|lane| lane.surface == surface)
            .map(|lane| &lane.sequence)
            .chain(person)
            .collect();
        if sequences.is_empty() {
            return Fenced::Drained(then);
        }
        pool.fence(&sequences, then)
    }
}

/// Whether the control command named `wire_name` may pass items queued on a
/// stream of its target: its schema entry carries `crosses_stream_ok` with a
/// reason. A command the method table does not have waits, as every command
/// without the attribute does.
pub(crate) fn crosses_stream_ok(wire_name: &str) -> bool {
    let tables = MethodTables::schema();
    tables
        .v12_id(wire_name)
        .and_then(|id| tables.v12(id))
        .is_some_and(|method| method.crosses_stream_ok.is_some())
}

#[cfg(test)]
#[path = "stream_lanes_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "stream_lanes_person_tests.rs"]
mod person_tests;
