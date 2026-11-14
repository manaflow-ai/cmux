//! Terminal-host stream demultiplexer for one hosted surface connection.
//!
//! The host sends output, snapshots and targeted control responses on one
//! stream. The surface's host reader applies each output frame (VT parse,
//! journal update, render request) before it reads the next frame, so a
//! response queued behind an output backlog used to reach its waiter only
//! after that backlog. A receipted input write or termination request then
//! timed out after `CONTROL_RESPONSE_TIMEOUT` although the host had answered
//! at once.
//!
//! A reader thread now owns the socket. `InputAck`, `TerminateAck` and
//! `Capability` carry no state the output path needs, so the thread resolves
//! them as they arrive. A smart host applies `SetDefaults` by publishing
//! `ResyncRequired` and answers a following `MintCapability` behind it, so a
//! renderer mint right after a default-colors update depends on this thread
//! too. On a smart-renderer connection it also resolves
//! `KittyGraphicsLimitsAck`: a smart host answers a Kitty limits update with
//! `ResyncRequired` and then the acknowledgement, and the surface's reader
//! stops reading the stream at a `ResyncRequired` that needs a reopen, so
//! only this thread can still deliver it. Older hosts send the replacement
//! replay before the acknowledgement and keep it in output order.
//!
//! Every other frame (including `ClearHistoryAck`, whose replay must stay
//! ordered with output, and resize and cell-pixel responses) goes to the
//! surface's reader in stream order through a queue bounded by bytes: each
//! frame counts its payload plus a fixed per-frame cost, so a flood of empty
//! frames is bounded too. When the queue is full the thread stops reading,
//! which keeps the host's backpressure. Once the surface's reader abandons
//! the stream (`abandon`), the thread discards ordered frames instead of
//! queueing them, so a backlog can never delay an acknowledgement it still
//! owes; it still resolves `ClearHistoryAck` (status only, see
//! `resolves_after_abandon`).
//!
//! A `ClipboardReadRequest` from a host that negotiated clipboard reads
//! becomes the connection's pending read and a `ClipboardReadCancel`
//! withdraws it (see `ControlResponses`); from any other host either ends
//! the connection. The end of the stream withdraws a pending read too.
//!
//! Failure ownership: at the end of the stream the thread fails only the
//! waiters it resolves itself; the surface's reader drains the queued frames
//! and then fails the ordered waiters. After `abandon` or a drop, the thread
//! fails every waiter at the end of the stream. A drop while replies it
//! resolves are still owed keeps the stream open until they arrive or time
//! out, so a mint sent just before a reconnect replaced the connection is
//! not lost to the drop's own shutdown.

use std::collections::VecDeque;
use std::io::Read;
use std::sync::{Arc, Condvar, Mutex};

use crate::terminal_host_protocol::{Frame, MAX_FRAME_PAYLOAD, MessageKind, read_frame};
use crate::terminal_host_runtime::HostStream as UnixStream;
use crate::terminal_host_runtime::{CONTROL_RESPONSE_TIMEOUT, ControlResponses};

/// Bytes the reader thread may queue ahead of the surface's reader, counted
/// by [`queued_cost`]. One frame is always admitted, however large.
const QUEUED_BYTES_BUDGET: usize = 8 * 1024 * 1024;

/// Bytes the reader thread reads from the socket in one call while the link
/// has a backlog. A host link under backlog holds many frames; reading them
/// one header and one payload at a time cost at least two `read` calls per
/// frame. Bounded and small next to [`QUEUED_BYTES_BUDGET`]: when the queue
/// is full the thread still stops reading, so the host keeps its
/// backpressure (it may have written at most this many bytes more). Held
/// only while a backlog lasts: see [`LinkReader`].
const LINK_READ_BUFFER: usize = 64 * 1024;

/// Bytes of a read on a link that shows no backlog, into the reader's
/// inline bytes (no heap). They take a typical interactive frame with its
/// header in one read.
const LINK_FIRST_READ: usize = 4 * 1024;

/// What a queued frame costs besides its payload: the wire header it arrived
/// with and its queue slot. Empty frames (Bell, metadata) cost this alone;
/// counting only payload bytes let a flood of them grow the queue without
/// bound.
const QUEUED_FRAME_OVERHEAD: usize =
    crate::terminal_host_protocol::HEADER_LEN + size_of::<HostFrame>();

/// What `frame` costs against [`QUEUED_BYTES_BUDGET`] while it is queued.
fn queued_cost(frame: &Frame) -> usize {
    QUEUED_FRAME_OVERHEAD + frame.payload.len()
}

/// What the surface's reader receives.
pub(super) enum HostFrame {
    Frame(Frame),
    /// The stream ended, failed to decode, or carried a response that must
    /// end the connection (unknown request, malformed ack).
    End,
}

#[derive(Default)]
struct QueueState {
    frames: VecDeque<HostFrame>,
    /// The [`queued_cost`] of the queued frames.
    queued_bytes: usize,
    ended: bool,
    /// The surface's reader no longer reads this queue (`abandon` or drop).
    abandoned: bool,
    /// The demultiplexer was dropped with replies still owed: the thread
    /// ends once no waiter it resolves is left, or at this deadline.
    draining: Option<std::time::Instant>,
    /// Tests: how many times the reader thread waited for room in the queue.
    #[cfg(test)]
    budget_waits: usize,
}

struct Queue {
    state: Mutex<QueueState>,
    changed: Condvar,
}

/// Which responses the reader thread resolves itself for one connection.
#[derive(Clone, Copy)]
pub(super) struct EarlyResponses {
    smart_renderer: bool,
}

impl EarlyResponses {
    pub(super) fn new(smart_renderer: bool) -> Self {
        Self { smart_renderer }
    }

    /// Whether the reader thread resolves responses of `kind`.
    pub(super) fn resolves(self, kind: MessageKind) -> bool {
        match kind {
            MessageKind::InputAck | MessageKind::TerminateAck | MessageKind::Capability => true,
            MessageKind::KittyGraphicsLimitsAck => self.smart_renderer,
            _ => false,
        }
    }

    /// Whether the reader thread resolves responses of `kind` once the
    /// surface's reader abandoned the stream. A clear-history acknowledgement
    /// is ordered with output while the stream is read; after the abandon
    /// its replay is moot, because the next connection carries the cleared
    /// screen (its snapshot; or, after it, the ResyncRequired a smart host
    /// publishes with the clear, or the Output a legacy host broadcasts), so
    /// only its status still matters to the requester. The mirror may show
    /// the cleared screen a moment after the requester's success.
    fn resolves_after_abandon(self, kind: MessageKind) -> bool {
        self.resolves(kind) || kind == MessageKind::ClearHistoryAck
    }
}

/// The surface side of one connection's demultiplexer.
pub(super) struct HostFrames {
    queue: Arc<Queue>,
    control_responses: Arc<ControlResponses>,
    early: EarlyResponses,
    /// A handle on the reader thread's socket, shut down for reading when the
    /// connection is dropped so the thread's blocked read returns and the
    /// descriptor closes as the plain reader's did.
    shutdown: UnixStream,
}

impl HostFrames {
    /// Start the reader thread for `stream`. `protocol_version` is the
    /// connection's negotiated version; early-resolved acks must carry it.
    pub(super) fn spawn(
        name: String,
        stream: UnixStream,
        control_responses: Arc<ControlResponses>,
        protocol_version: u16,
        smart_renderer: bool,
    ) -> std::io::Result<Self> {
        let early = EarlyResponses::new(smart_renderer);
        let shutdown = stream.try_clone()?;
        let queue =
            Arc::new(Queue { state: Mutex::new(QueueState::default()), changed: Condvar::new() });
        let thread_queue = queue.clone();
        let thread_responses = control_responses.clone();
        std::thread::Builder::new().name(name).spawn(move || {
            read_stream(stream, &thread_responses, protocol_version, early, &thread_queue);
        })?;
        Ok(Self { queue, control_responses, early, shutdown })
    }

    /// The next frame in stream order; blocks until one arrives.
    pub(super) fn recv(&self) -> HostFrame {
        let mut state = self.queue.state.lock().unwrap();
        loop {
            if let Some(frame) = state.frames.pop_front() {
                if let HostFrame::Frame(frame) = &frame {
                    state.queued_bytes -= queued_cost(frame);
                }
                self.queue.changed.notify_all();
                return frame;
            }
            if state.ended {
                return HostFrame::End;
            }
            state = self.queue.changed.wait(state).unwrap();
        }
    }

    /// The next frame when one is already queued and `admit` accepts it;
    /// never blocks. The surface's reader takes the Output frames queued
    /// behind the one it applies with this.
    pub(super) fn try_recv_if(&self, admit: impl FnOnce(&Frame) -> bool) -> Option<Frame> {
        let mut state = self.queue.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let HostFrame::Frame(front) = state.frames.front()? else { return None };
        if !admit(front) {
            return None;
        }
        let HostFrame::Frame(frame) = state.frames.pop_front()? else { return None };
        state.queued_bytes = state.queued_bytes.saturating_sub(queued_cost(&frame));
        self.queue.changed.notify_all();
        Some(frame)
    }

    /// Tests: how many frames are queued for the surface's reader.
    #[cfg(test)]
    pub(super) fn queued_frames_for_test(&self) -> usize {
        self.queue.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner).frames.len()
    }

    /// The surface's reader stops reading this stream (for example at
    /// `ResyncRequired`) but the connection may stay open while it
    /// reconnects. Ordered waiters fail now, except clear-history ones. The
    /// thread keeps resolving early acknowledgements (a Kitty limits
    /// acknowledgement follows ResyncRequired) and clear-history
    /// acknowledgements, discards other ordered frames, and fails every
    /// waiter when the stream ends.
    pub(super) fn abandon(&self) {
        let ended = {
            let mut state = self.queue.state.lock().unwrap();
            state.abandoned = true;
            state.queued_bytes = 0;
            // A clear-history acknowledgement already queued behind the frame
            // that ended the read still answers its requester. It is resolved
            // under the queue lock, before the thread can see `abandoned` at
            // the end of the stream and fail every waiter.
            for frame in std::mem::take(&mut state.frames) {
                if let HostFrame::Frame(frame) = frame
                    && frame.kind == MessageKind::ClearHistoryAck
                {
                    self.control_responses.resolve_after(&frame, || {});
                }
            }
            self.queue.changed.notify_all();
            state.ended
        };
        if ended {
            // The thread is gone: nothing would resolve a kept waiter.
            self.control_responses.fail_all();
            return;
        }
        let early = self.early;
        self.control_responses.fail_all_except(|kind| early.resolves_after_abandon(kind));
    }
}

impl Drop for HostFrames {
    /// A reply the host owes on this connection (a renderer mint sent just
    /// before a resync reconnect replaced it) still reaches its waiter: the
    /// thread keeps reading until no waiter it resolves is left or the drain
    /// deadline passes. A waiter that times out shuts the connection down
    /// itself (Kitty limits excepted), which also ends a read already in
    /// progress; the read timeout bounds reads that start later.
    fn drop(&mut self) {
        self.abandon();
        let early = self.early;
        let owed = {
            let mut state = self.queue.state.lock().unwrap();
            let owed = !state.ended
                && self
                    .control_responses
                    .has_waiter_where(|kind| early.resolves_after_abandon(kind));
            if owed {
                state.draining = Some(std::time::Instant::now() + CONTROL_RESPONSE_TIMEOUT);
            }
            owed
        };
        if owed && self.shutdown.set_read_timeout(Some(CONTROL_RESPONSE_TIMEOUT)).is_ok() {
            return;
        }
        let _ = self.shutdown.shutdown(std::net::Shutdown::Read);
    }
}

/// Responses to a request this connection sent, matched by request id; the
/// surface's reader consumes them before live staging.
pub(super) fn is_targeted_host_response(kind: MessageKind) -> bool {
    matches!(
        kind,
        MessageKind::Capability
            | MessageKind::ResizeAck
            | MessageKind::CellPixelSizeAck
            | MessageKind::KittyGraphicsLimitsAck
            | MessageKind::ClearHistoryAck
            | MessageKind::TerminateAck
            | MessageKind::DetachAck
            | MessageKind::InputAck
    )
}

fn resolves_early(frame: &Frame, protocol_version: u16, early: EarlyResponses) -> bool {
    early.resolves(frame.kind)
        && frame.request_id != 0
        && frame.version == protocol_version
        && frame.flags == 0
        && frame.sequence == 0
}

/// The daemon's read side of one host link. A link with no backlog reads
/// through [`LINK_FIRST_READ`] inline bytes. A read that fills them shows a
/// backlog (the host wrote more than that), and the next reads go through a
/// [`LINK_READ_BUFFER`] heap buffer, until one returns fewer bytes than that
/// buffer holds (the link had no more ready): once those bytes are taken the
/// buffer goes. A backlog still costs about one `read` per 64 KiB, and an
/// idle terminal holds no 64 KiB buffer (a real session has about 800
/// terminals: a buffer each kept 13 MB resident while idle, up to 51 MB
/// after one burst each). With nothing buffered, a request at least as
/// large as the active buffer (a large payload) is read straight into the
/// caller's bytes.
struct LinkReader<R> {
    stream: R,
    first: [u8; LINK_FIRST_READ],
    backlog: Option<Vec<u8>>,
    /// The buffered bytes are `backlog[start..end]`, else `first[start..end]`.
    in_backlog: bool,
    start: usize,
    end: usize,
    /// The read that filled `backlog` returned less than it holds: the
    /// buffer goes once its bytes are taken.
    drained: bool,
}

impl<R: Read> LinkReader<R> {
    fn new(stream: R) -> Self {
        Self {
            stream,
            first: [0; LINK_FIRST_READ],
            backlog: None,
            in_backlog: false,
            start: 0,
            end: 0,
            drained: false,
        }
    }

    /// Heap bytes the reader holds for its reads (a test reads it).
    #[cfg(test)]
    fn held_bytes(&self) -> usize {
        self.backlog.as_ref().map_or(0, Vec::len)
    }

    /// Refill the empty buffer with one read; the bytes read.
    fn fill(&mut self) -> std::io::Result<usize> {
        let read = match self.backlog.as_mut() {
            Some(backlog) => {
                let read = self.stream.read(backlog)?;
                self.drained = read < backlog.len();
                self.in_backlog = true;
                read
            }
            None => {
                let read = self.stream.read(&mut self.first)?;
                self.in_backlog = false;
                if read == LINK_FIRST_READ {
                    // A backlog: the next reads take up to 64 KiB each.
                    self.backlog = Some(vec![0; LINK_READ_BUFFER]);
                }
                read
            }
        };
        self.start = 0;
        self.end = read;
        Ok(read)
    }
}

impl<R: Read> Read for LinkReader<R> {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        if self.start == self.end {
            let capacity = self.backlog.as_ref().map_or(LINK_FIRST_READ, Vec::len);
            if out.len() >= capacity {
                return self.stream.read(out);
            }
            if self.fill()? == 0 {
                return Ok(0);
            }
        }
        let buffered =
            if self.in_backlog { self.backlog.as_deref() } else { Some(&self.first[..]) };
        let count = {
            let Some(buffered) = buffered.and_then(|bytes| bytes.get(self.start..self.end)) else {
                return Ok(0);
            };
            let count = buffered.len().min(out.len());
            let (Some(into), Some(from)) = (out.get_mut(..count), buffered.get(..count)) else {
                return Ok(0);
            };
            into.copy_from_slice(from);
            count
        };
        self.start += count;
        if self.start == self.end && self.drained {
            // The link had no more than these bytes: an idle link holds no
            // large buffer.
            self.backlog = None;
            self.drained = false;
        }
        Ok(count)
    }
}

fn read_stream(
    stream: impl Read,
    control_responses: &ControlResponses,
    protocol_version: u16,
    early: EarlyResponses,
    queue: &Queue,
) {
    let mut stream = LinkReader::new(stream);
    loop {
        let draining = queue.state.lock().unwrap().draining;
        if draining.is_some_and(|deadline| {
            std::time::Instant::now() >= deadline
                || !control_responses.has_waiter_where(|kind| early.resolves_after_abandon(kind))
        }) {
            break;
        }
        let Ok(Some(frame)) = read_frame(&mut stream, MAX_FRAME_PAYLOAD) else { break };
        // A host-originated clipboard read is outside the live sequence and
        // waits for the user, so it never enters the ordered queue.
        if frame.kind == MessageKind::ClipboardReadRequest {
            if control_responses.accept_clipboard_read_request(&frame, protocol_version) {
                continue;
            }
            break;
        }
        if frame.kind == MessageKind::ClipboardReadCancel {
            if control_responses.accept_clipboard_read_cancel(&frame, protocol_version) {
                continue;
            }
            break;
        }
        if resolves_early(&frame, protocol_version, early) {
            // A Kitty limits acknowledgement that arrives after its
            // requester's deadline is advisory: the requester already
            // degraded graphics and must not tear down a healthy connection.
            if frame.kind == MessageKind::KittyGraphicsLimitsAck
                && !control_responses.has_waiter(frame.request_id)
            {
                continue;
            }
            if control_responses.resolve_after(&frame, || {}) {
                continue;
            }
            // Any other acknowledgement nobody waits for, or one whose id
            // belongs to a waiter of another kind, ends the connection, as it
            // did when the surface's reader resolved it inline.
            break;
        }
        let mut state = queue.state.lock().unwrap();
        while !state.abandoned
            && !state.frames.is_empty()
            && state.queued_bytes + queued_cost(&frame) > QUEUED_BYTES_BUDGET
        {
            #[cfg(test)]
            {
                state.budget_waits += 1;
                queue.changed.notify_all();
            }
            state = queue.changed.wait(state).unwrap();
        }
        if state.abandoned {
            if frame.kind == MessageKind::ClearHistoryAck {
                drop(state);
                control_responses.resolve_after(&frame, || {});
            }
            continue;
        }
        state.queued_bytes += queued_cost(&frame);
        state.frames.push_back(HostFrame::Frame(frame));
        queue.changed.notify_all();
    }
    control_responses.end_clipboard_reads();
    let mut state = queue.state.lock().unwrap();
    if state.abandoned {
        drop(state);
        control_responses.fail_all();
        return;
    }
    // The surface's reader still drains the queued frames, resolves their
    // ordered responses, and fails the rest after `End`.
    control_responses.fail_all_except(|kind| !early.resolves(kind));
    state.ended = true;
    queue.changed.notify_all();
}

#[cfg(test)]
mod tests;
