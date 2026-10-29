//! A connection's stream sequences and the stream barrier
//! (plans/cmux-next/chrome-parity/p05-ipc.md section 3.4).
//!
//! Each stream a connection opens (attach-streams) is its own
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
//! [`StreamLanes`] has no lock of its own: it lives in the connection's
//! scheduler state (`ConnectionSurfaceState`), so a stream post and a
//! control arrival are ordered by that one lock.

use std::collections::HashMap;

use cmux_ipc::MethodTables;

use super::sequenced_pool::{Fenced, PostError, Sequence, SequencePriority, SequencedPool};
use crate::SurfaceId;

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

/// The open streams of one connection, by stream id.
#[derive(Default)]
pub(crate) struct StreamLanes {
    streams: HashMap<u16, StreamLane>,
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

    pub(crate) fn is_empty(&self) -> bool {
        self.streams.is_empty()
    }

    /// The stream barrier for a control command on `surface`: `then` runs
    /// once every stream of `surface`, open or closing, ran the items it
    /// holds now. [`Fenced::Drained`] hands `then` back when none holds an
    /// item, and the command goes on at once.
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
        let sequences: Vec<&Sequence> = self
            .streams
            .values()
            .filter(|lane| lane.surface == surface)
            .map(|lane| &lane.sequence)
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
