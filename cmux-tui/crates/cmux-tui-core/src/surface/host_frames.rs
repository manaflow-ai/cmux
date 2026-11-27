//! Terminal-host stream demultiplexer for one hosted surface connection.
//!
//! The host sends output, snapshots and targeted control responses on one
//! stream. The surface's host reader applies each output frame (VT parse,
//! journal update, render request) before it reads the next frame, so a
//! response queued behind an output backlog used to reach its waiter only
//! after that backlog. A receipted input write or termination request then
//! timed out after `CONTROL_RESPONSE_TIMEOUT` although the host had answered
<<<<<<< ours
//! at once.
=======
//! at once (issue #39510).
>>>>>>> theirs
//!
//! A reader thread now owns the socket. `InputAck`, `TerminateAck` and
//! `Capability` carry no state the output path needs, so the thread resolves
//! them as they arrive. A smart host applies `SetDefaults` by publishing
//! `ResyncRequired` and answers a following `MintCapability` behind it, so a
//! renderer mint right after a default-colors update depends on this thread
//! too. On a smart-renderer connection it also resolves
//! `KittyGraphicsLimitsAck`: a smart host answers a Kitty limits update with
//! `ResyncRequired` and then the acknowledgement, and the surface's reader
<<<<<<< ours
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
=======
//! stops reading the stream at `ResyncRequired`, so only this thread can
//! still deliver it. Older hosts send the replacement replay before the
//! acknowledgement and keep it in output order.
//!
//! Every other frame (including `ClearHistoryAck`, whose replay must stay
//! ordered with output, and resize and cell-pixel responses) goes to the
//! surface's reader in stream order through a queue bounded by payload
//! bytes. When the queue is full the thread stops reading, which keeps the
//! host's backpressure. Once the surface's reader abandons the stream
//! (`abandon`), the thread discards ordered frames instead of queueing them,
//! so a backlog can never delay an acknowledgement it still owes.
>>>>>>> theirs
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
<<<<<<< ours
use std::sync::{Arc, Condvar, Mutex};

use crate::panic_free::RecoverPoison;
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
=======
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

use crate::terminal_host_protocol::{Frame, MAX_FRAME_PAYLOAD, MessageKind, read_frame};
use crate::terminal_host_runtime::{CONTROL_RESPONSE_TIMEOUT, ControlResponses};

/// Output bytes the reader thread may queue ahead of the surface's reader.
/// One frame is always admitted, however large.
const QUEUED_PAYLOAD_BUDGET: usize = 8 * 1024 * 1024;
>>>>>>> theirs

/// What the surface's reader receives.
pub(super) enum HostFrame {
    Frame(Frame),
    /// The stream ended, failed to decode, or carried a response that must
    /// end the connection (unknown request, malformed ack).
    End,
<<<<<<< ours
    /// Nothing is queued and the link's reader parked on the shared poller
    /// (`recv` only; never queued): the surface's reader may park too, with
    /// [`HostFrames::consumer_slot`].
    #[cfg_attr(not(unix), allow(dead_code))]
    Idle,
=======
>>>>>>> theirs
}

#[derive(Default)]
struct QueueState {
<<<<<<< ours
    frames: VecDeque<HostFrame>,
    /// The [`queued_cost`] of the queued frames.
    queued_bytes: usize,
=======
    frames: VecDeque<Frame>,
    queued_payload: usize,
>>>>>>> theirs
    ended: bool,
    /// The surface's reader no longer reads this queue (`abandon` or drop).
    abandoned: bool,
    /// The demultiplexer was dropped with replies still owed: the thread
    /// ends once no waiter it resolves is left, or at this deadline.
<<<<<<< ours
    draining: Option<std::time::Instant>,
    /// The link's reader is parked on the shared poller.
    link_parked: bool,
    /// Its place there, while parked.
    #[cfg(unix)]
    parked_link: Option<super::idle_links::ParkedLink>,
    /// The surface's reader, parked until the next frame or the end.
    consumer: Option<Box<dyn FnOnce() + Send>>,
    /// Tests: how many times the reader thread waited for room in the queue.
    #[cfg(test)]
    budget_waits: usize,
=======
    draining: Option<Instant>,
>>>>>>> theirs
}

struct Queue {
    state: Mutex<QueueState>,
    changed: Condvar,
}

/// Which responses the reader thread resolves itself for one connection.
#[derive(Clone, Copy)]
<<<<<<< ours
pub(super) struct EarlyResponses {
=======
struct EarlyResponses {
>>>>>>> theirs
    smart_renderer: bool,
}

impl EarlyResponses {
<<<<<<< ours
    pub(super) fn new(smart_renderer: bool) -> Self {
        Self { smart_renderer }
    }

    /// Whether the reader thread resolves responses of `kind`.
    pub(super) fn resolves(self, kind: MessageKind) -> bool {
=======
    /// Whether the reader thread resolves responses of `kind`.
    fn resolves(self, kind: MessageKind) -> bool {
>>>>>>> theirs
        match kind {
            MessageKind::InputAck | MessageKind::TerminateAck | MessageKind::Capability => true,
            MessageKind::KittyGraphicsLimitsAck => self.smart_renderer,
            _ => false,
        }
    }
<<<<<<< ours

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

/// Parks the surface's reader until the next frame or the end of the stream.
#[cfg(unix)]
pub(super) struct ConsumerSlot(Arc<Queue>);

#[cfg(unix)]
impl ConsumerSlot {
    /// Park `work`: `resume(work)` runs on the link's thread with the next
    /// frame or the end of the stream (it starts its own thread). `Err(work)`
    /// when a frame or the end is already here or the link reads again: the
    /// caller goes on with `recv`.
    pub(super) fn park<T: Send + 'static>(&self, work: T, resume: fn(T)) -> Result<(), T> {
        let mut state = self.0.state.lock().recover_poison();
        if !state.frames.is_empty() || state.ended || !state.link_parked || state.abandoned {
            return Err(work);
        }
        state.consumer = Some(Box::new(move || resume(work)));
        Ok(())
    }
=======
>>>>>>> theirs
}

/// The surface side of one connection's demultiplexer.
pub(super) struct HostFrames {
    queue: Arc<Queue>,
    control_responses: Arc<ControlResponses>,
    early: EarlyResponses,
    /// A handle on the reader thread's socket, shut down for reading when the
    /// connection is dropped so the thread's blocked read returns and the
<<<<<<< ours
    /// descriptor closes as the plain reader's did. The reader holds the
    /// same descriptor.
    shutdown: Arc<UnixStream>,
=======
    /// descriptor closes as the plain reader's did.
    shutdown: UnixStream,
>>>>>>> theirs
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
<<<<<<< ours
        Self::spawn_parking_after(
            name,
            stream,
            control_responses,
            protocol_version,
            smart_renderer,
            LINK_PARK_AFTER,
        )
    }

    /// [`Self::spawn`], parking the link after `park_after` of quiet (tests
    /// park sooner).
    pub(super) fn spawn_parking_after(
        name: String,
        stream: UnixStream,
        control_responses: Arc<ControlResponses>,
        protocol_version: u16,
        smart_renderer: bool,
        park_after: std::time::Duration,
    ) -> std::io::Result<Self> {
        let early = EarlyResponses::new(smart_renderer);
        // The reader and the shutdown handle share one descriptor: a clone
        // cost every terminal one more fd for as long as its link lived.
        let stream = Arc::new(stream);
        let queue =
            Arc::new(Queue { state: Mutex::new(QueueState::default()), changed: Condvar::new() });
        let link = LinkTask {
            name: name.clone(),
            reader: LinkReader::new(SharedStream(stream.clone())),
            control_responses: control_responses.clone(),
            protocol_version,
            early,
            queue: queue.clone(),
            park_after,
        };
        std::thread::Builder::new().name(name).spawn(move || link.run())?;
        Ok(Self { queue, control_responses, early, shutdown: stream })
=======
        let early = EarlyResponses { smart_renderer };
        let shutdown = stream.try_clone()?;
        let queue =
            Arc::new(Queue { state: Mutex::new(QueueState::default()), changed: Condvar::new() });
        let thread_queue = queue.clone();
        let thread_responses = control_responses.clone();
        std::thread::Builder::new().name(name).spawn(move || {
            read_stream(stream, &thread_responses, protocol_version, early, &thread_queue);
        })?;
        Ok(Self { queue, control_responses, early, shutdown })
>>>>>>> theirs
    }

    /// The next frame in stream order; blocks until one arrives.
    pub(super) fn recv(&self) -> HostFrame {
<<<<<<< ours
        let mut state = self.queue.state.lock().recover_poison();
        loop {
            if let Some(frame) = state.frames.pop_front() {
                if let HostFrame::Frame(frame) = &frame {
                    state.queued_bytes -= queued_cost(frame);
                }
                self.queue.changed.notify_all();
                return frame;
=======
        let mut state = self.queue.state.lock().unwrap();
        loop {
            if let Some(frame) = state.frames.pop_front() {
                state.queued_payload -= frame.payload.len();
                self.queue.changed.notify_all();
                return HostFrame::Frame(frame);
>>>>>>> theirs
            }
            if state.ended {
                return HostFrame::End;
            }
<<<<<<< ours
            if state.link_parked {
                return HostFrame::Idle;
            }
            state = self.queue.changed.wait(state).recover_poison();
        }
    }

    /// Where the surface's reader parks while the link is parked.
    #[cfg(unix)]
    pub(super) fn consumer_slot(&self) -> ConsumerSlot {
        ConsumerSlot(self.queue.clone())
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
=======
            state = self.queue.changed.wait(state).unwrap();
        }
>>>>>>> theirs
    }

    /// The surface's reader stops reading this stream (for example at
    /// `ResyncRequired`) but the connection may stay open while it
<<<<<<< ours
    /// reconnects. Ordered waiters fail now, except clear-history ones. The
    /// thread keeps resolving early acknowledgements (a Kitty limits
    /// acknowledgement follows ResyncRequired) and clear-history
    /// acknowledgements, discards other ordered frames, and fails every
    /// waiter when the stream ends.
    pub(super) fn abandon(&self) {
        let ended = {
            let mut state = self.queue.state.lock().recover_poison();
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
=======
    /// reconnects. Ordered waiters fail now. The thread keeps resolving
    /// early acknowledgements (a Kitty limits acknowledgement follows
    /// ResyncRequired), discards ordered frames, and fails every waiter when
    /// the stream ends.
    pub(super) fn abandon(&self) {
        let ended = {
            let mut state = self.queue.state.lock().unwrap();
            state.abandoned = true;
            state.frames.clear();
            state.queued_payload = 0;
>>>>>>> theirs
            self.queue.changed.notify_all();
            state.ended
        };
        if ended {
            // The thread is gone: nothing would resolve a kept waiter.
            self.control_responses.fail_all();
            return;
        }
        let early = self.early;
<<<<<<< ours
        self.control_responses.fail_all_except(|kind| early.resolves_after_abandon(kind));
=======
        self.control_responses.fail_all_except(|kind| early.resolves(kind));
>>>>>>> theirs
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
<<<<<<< ours
        let (owed, parked_link) = {
            let mut state = self.queue.state.lock().recover_poison();
            let owed = !state.ended
                && self
                    .control_responses
                    .has_waiter_where(|kind| early.resolves_after_abandon(kind));
            let deadline = std::time::Instant::now() + CONTROL_RESPONSE_TIMEOUT;
            if owed {
                state.draining = Some(deadline);
            }
            #[cfg(unix)]
            let parked_link = state.parked_link.filter(|_| owed).map(|link| (link, deadline));
            #[cfg(not(unix))]
            let parked_link: Option<((), std::time::Instant)> = None;
            (owed, parked_link)
        };
        if owed && self.shutdown.set_read_timeout(Some(CONTROL_RESPONSE_TIMEOUT)).is_ok() {
            // A parked link reads no more until its socket wakes: the
            // shared poller resumes it by the drain deadline instead.
            #[cfg(unix)]
            if let Some((link, deadline)) = parked_link {
                super::idle_links::resume_at(link, deadline);
            }
            #[cfg(not(unix))]
            let _ = parked_link;
=======
        let owed = {
            let mut state = self.queue.state.lock().unwrap();
            let owed = !state.ended
                && self.control_responses.has_waiter_where(|kind| early.resolves(kind));
            if owed {
                state.draining = Some(Instant::now() + CONTROL_RESPONSE_TIMEOUT);
            }
            owed
        };
        if owed && self.shutdown.set_read_timeout(Some(CONTROL_RESPONSE_TIMEOUT)).is_ok() {
>>>>>>> theirs
            return;
        }
        let _ = self.shutdown.shutdown(std::net::Shutdown::Read);
    }
}

<<<<<<< ours
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

=======
>>>>>>> theirs
fn resolves_early(frame: &Frame, protocol_version: u16, early: EarlyResponses) -> bool {
    early.resolves(frame.kind)
        && frame.request_id != 0
        && frame.version == protocol_version
        && frame.flags == 0
        && frame.sequence == 0
}

<<<<<<< ours
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

/// How long a link with nothing to read keeps its reader thread before it
/// parks on the daemon's shared poller ([`super::idle_links`]).
pub(super) const LINK_PARK_AFTER: std::time::Duration = std::time::Duration::from_secs(10);

/// The link's socket, shared with [`HostFrames::shutdown`].
struct SharedStream(Arc<UnixStream>);

impl Read for SharedStream {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        (&*self.0).read(out)
    }
}

/// Whether the reader goes on reading between two frames.
enum Between {
    Read,
    /// Nothing arrived for [`LINK_PARK_AFTER`]: hand the link to the shared
    /// poller.
    #[cfg_attr(not(unix), allow(dead_code))]
    Park,
}

/// How the read loop stopped.
enum ReadEnd {
    Ended,
    #[cfg_attr(not(unix), allow(dead_code))]
    Parked,
}

/// The reader thread's state, kept across a park: the link's buffer is empty
/// whenever it parks, so the resumed thread reads exactly where this one
/// stopped.
struct LinkTask {
    name: String,
    reader: LinkReader<SharedStream>,
    control_responses: Arc<ControlResponses>,
    protocol_version: u16,
    early: EarlyResponses,
    queue: Arc<Queue>,
    #[cfg_attr(not(unix), allow(dead_code))]
    park_after: std::time::Duration,
}

impl LinkTask {
    #[cfg_attr(not(unix), allow(unused_mut))]
    fn run(mut self) {
        #[cfg(unix)]
        let mut parking = true;
        loop {
            let park_after = self.park_after;
            #[cfg(unix)]
            let may_park = parking;
            let end = read_frames(
                &mut self.reader,
                &self.control_responses,
                self.protocol_version,
                self.early,
                &self.queue,
                |reader| {
                    #[cfg(unix)]
                    if may_park && !reader.wait_readable(park_after) {
                        return Between::Park;
                    }
                    #[cfg(not(unix))]
                    let _ = (reader, park_after);
                    Between::Read
                },
            );
            match end {
                ReadEnd::Ended => {
                    finish_stream(&self.control_responses, self.early, &self.queue);
                    return;
                }
                ReadEnd::Parked => {
                    #[cfg(unix)]
                    {
                        let queue = self.queue.clone();
                        queue.state.lock().recover_poison().link_parked = true;
                        queue.changed.notify_all();
                        let stream = self.reader.stream.0.clone();
                        match super::idle_links::park(stream, self, LinkTask::resume) {
                            Ok(link) => {
                                let mut state = queue.state.lock().recover_poison();
                                if state.link_parked {
                                    state.parked_link = Some(link);
                                }
                                return;
                            }
                            // No poller: keep this thread and read on.
                            Err(task) => {
                                task.queue.state.lock().recover_poison().link_parked = false;
                                self = task;
                                parking = false;
                            }
                        }
                    }
                }
            }
        }
    }

    /// The parked link's socket woke: read it on a new thread. When no thread
    /// can be started the link ends as a failed read would end it.
    #[cfg(unix)]
    fn resume(self) {
        {
            let mut state = self.queue.state.lock().recover_poison();
            state.link_parked = false;
            state.parked_link = None;
        }
        let name = self.name.clone();
        spawn_or(&name, self, LinkTask::run, |task| {
            finish_stream(&task.control_responses, task.early, &task.queue);
        });
    }
}

/// Start `run(work)` on a thread named `name`, retrying a failed spawn for
/// about a second (threads run out under load and come back); `fail(work)`
/// when none started.
#[cfg(unix)]
pub(super) fn spawn_or<T: Send + 'static>(name: &str, work: T, run: fn(T), fail: fn(T)) {
    let slot = Arc::new(Mutex::new(Some(work)));
    for attempt in 0..20 {
        let thread_slot = slot.clone();
        let started = std::thread::Builder::new().name(name.to_owned()).spawn(move || {
            let work = thread_slot.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
            if let Some(work) = work {
                run(work);
            }
        });
        if started.is_ok() {
            return;
        }
        if attempt < 19 {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }
    let work = slot.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
    if let Some(work) = work {
        fail(work);
    }
}

#[cfg(unix)]
impl LinkReader<SharedStream> {
    /// Whether the link has a byte buffered or the socket turns readable
    /// (bytes, its end or an error) within `timeout`. `false` only when the
    /// whole wait passed with nothing.
    fn wait_readable(&self, timeout: std::time::Duration) -> bool {
        use std::os::fd::AsRawFd;
        if self.start != self.end {
            return true;
        }
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            if left.is_zero() {
                return false;
            }
            let millis = i32::try_from(left.as_millis().max(1)).unwrap_or(i32::MAX);
            let mut fds =
                [libc::pollfd { fd: self.stream.0.as_raw_fd(), events: libc::POLLIN, revents: 0 }];
            // SAFETY: the descriptor stays open as long as `self.stream`.
            let ready = unsafe { libc::poll(fds.as_mut_ptr(), 1, millis) };
            if ready > 0 {
                return true;
            }
            if ready < 0
                && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
            {
                // Let the read report it.
                return true;
            }
        }
    }
}

/// Tests: read `stream` to its end on this thread.
#[cfg(test)]
fn read_stream(
    stream: impl Read,
=======
fn read_stream(
    mut stream: impl Read,
>>>>>>> theirs
    control_responses: &ControlResponses,
    protocol_version: u16,
    early: EarlyResponses,
    queue: &Queue,
) {
<<<<<<< ours
    let mut reader = LinkReader::new(stream);
    let ReadEnd::Ended =
        read_frames(&mut reader, control_responses, protocol_version, early, queue, |_| {
            Between::Read
        })
    else {
        return;
    };
    finish_stream(control_responses, early, queue);
}

/// Read frames until the stream ends, or until `between` (asked before each
/// frame the link has not started) says to park. A park happens only with no
/// waiter in a drain and with nothing buffered, so no frame is split.
fn read_frames<R: Read>(
    stream: &mut LinkReader<R>,
    control_responses: &ControlResponses,
    protocol_version: u16,
    early: EarlyResponses,
    queue: &Queue,
    mut between: impl FnMut(&LinkReader<R>) -> Between,
) -> ReadEnd {
    loop {
        let draining = queue.state.lock().recover_poison().draining;
        if draining.is_some_and(|deadline| {
            std::time::Instant::now() >= deadline
                || !control_responses.has_waiter_where(|kind| early.resolves_after_abandon(kind))
        }) {
            return ReadEnd::Ended;
        }
        // A draining link keeps its thread: its read timeout bounds the drain.
        if draining.is_none() && matches!(between(stream), Between::Park) {
            if queue.state.lock().recover_poison().draining.is_none() {
                return ReadEnd::Parked;
            }
            continue;
        }
        let Ok(Some(frame)) = read_frame(stream, MAX_FRAME_PAYLOAD) else {
            return ReadEnd::Ended;
        };
        // A host-originated clipboard read is outside the live sequence and
        // waits for the user, so it never enters the ordered queue.
        if frame.kind == MessageKind::ClipboardReadRequest {
            if control_responses.accept_clipboard_read_request(&frame, protocol_version) {
                continue;
            }
            return ReadEnd::Ended;
        }
        if frame.kind == MessageKind::ClipboardReadCancel {
            if control_responses.accept_clipboard_read_cancel(&frame, protocol_version) {
                continue;
            }
            return ReadEnd::Ended;
        }
=======
    loop {
        let draining = queue.state.lock().unwrap().draining;
        if draining.is_some_and(|deadline| {
            Instant::now() >= deadline
                || !control_responses.has_waiter_where(|kind| early.resolves(kind))
        }) {
            break;
        }
        let Ok(Some(frame)) = read_frame(&mut stream, MAX_FRAME_PAYLOAD) else { break };
>>>>>>> theirs
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
<<<<<<< ours
            return ReadEnd::Ended;
        }
        let mut state = queue.state.lock().recover_poison();
        while !state.abandoned
            && !state.frames.is_empty()
            && state.queued_bytes + queued_cost(&frame) > QUEUED_BYTES_BUDGET
        {
            #[cfg(test)]
            {
                state.budget_waits += 1;
                queue.changed.notify_all();
            }
            state = queue.changed.wait(state).recover_poison();
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
        let consumer = state.consumer.take();
        drop(state);
        if let Some(resume) = consumer {
            resume();
        }
    }
}

/// The end of the stream: fail the waiters this side owns and tell the
/// surface's reader.
fn finish_stream(control_responses: &ControlResponses, early: EarlyResponses, queue: &Queue) {
    control_responses.end_clipboard_reads();
    let mut state = queue.state.lock().recover_poison();
=======
            break;
        }
        let mut state = queue.state.lock().unwrap();
        while !state.abandoned
            && !state.frames.is_empty()
            && state.queued_payload + frame.payload.len() > QUEUED_PAYLOAD_BUDGET
        {
            state = queue.changed.wait(state).unwrap();
        }
        if state.abandoned {
            continue;
        }
        state.queued_payload += frame.payload.len();
        state.frames.push_back(frame);
        queue.changed.notify_all();
    }
    let mut state = queue.state.lock().unwrap();
>>>>>>> theirs
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
<<<<<<< ours
    let consumer = state.consumer.take();
    drop(state);
    if let Some(resume) = consumer {
        resume();
    }
}

#[cfg(test)]
#[path = "host_frames_tests.rs"]
mod tests;
=======
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal_host_protocol::encode_frame;
    use std::time::Duration;

    const SMART: EarlyResponses = EarlyResponses { smart_renderer: true };
    const LEGACY: EarlyResponses = EarlyResponses { smart_renderer: false };

    fn frame(kind: MessageKind, request_id: u64, version: u16) -> Frame {
        let mut frame = Frame::new(kind, Vec::new());
        frame.request_id = request_id;
        frame.version = version;
        frame
    }

    fn version() -> u16 {
        Frame::new(MessageKind::InputAck, Vec::new()).version
    }

    fn stream_of(frames: &[Frame]) -> std::io::Cursor<Vec<u8>> {
        let mut bytes = Vec::new();
        for frame in frames {
            bytes.extend(encode_frame(frame).unwrap());
        }
        std::io::Cursor::new(bytes)
    }

    fn queue() -> Queue {
        Queue { state: Mutex::new(QueueState::default()), changed: Condvar::new() }
    }

    fn output(payload: impl Into<Vec<u8>>, version: u16) -> Frame {
        let mut output = Frame::new(MessageKind::Output, payload.into());
        output.version = version;
        output
    }

    #[test]
    fn early_responses_depend_on_kind_and_renderer() {
        let version = version();
        assert!(resolves_early(&frame(MessageKind::InputAck, 7, version), version, SMART));
        assert!(resolves_early(&frame(MessageKind::TerminateAck, 7, version), version, LEGACY));
        assert!(resolves_early(&frame(MessageKind::Capability, 7, version), version, LEGACY));
        assert!(resolves_early(
            &frame(MessageKind::KittyGraphicsLimitsAck, 7, version),
            version,
            SMART
        ));
        assert!(!resolves_early(
            &frame(MessageKind::KittyGraphicsLimitsAck, 7, version),
            version,
            LEGACY
        ));
        assert!(!resolves_early(&frame(MessageKind::InputAck, 0, version), version, SMART));
        assert!(!resolves_early(&frame(MessageKind::ClearHistoryAck, 7, version), version, SMART));
        assert!(!resolves_early(&frame(MessageKind::ResizeAck, 7, version), version, SMART));
        assert!(!resolves_early(
            &frame(MessageKind::InputAck, 7, version.wrapping_add(1)),
            version,
            SMART
        ));
    }

    /// An InputAck behind queued output reaches its waiter while the output
    /// stays queued, in order, for the surface's reader.
    #[test]
    fn input_ack_behind_output_resolves_on_arrival() {
        let version = version();
        let responses = ControlResponses::new_for_test();
        let input = responses.wait_for_test(4, MessageKind::InputAck);
        let queue = queue();
        let stream = stream_of(&[
            output(b"first", version),
            output(b"second", version),
            frame(MessageKind::InputAck, 4, version),
        ]);
        read_stream(stream, &responses, version, LEGACY, &queue);
        assert_eq!(input.recv_timeout(Duration::from_secs(1)).unwrap().kind, MessageKind::InputAck);
        let state = queue.state.lock().unwrap();
        let payloads = state.frames.iter().map(|frame| frame.payload.clone()).collect::<Vec<_>>();
        assert_eq!(payloads, vec![b"first".to_vec(), b"second".to_vec()]);
        assert!(state.ended);
    }

    /// A smart host answers a Kitty limits update with ResyncRequired and
    /// then the acknowledgement. The surface's reader abandons the stream at
    /// ResyncRequired; the acknowledgement must still reach its requester.
    #[test]
    fn kitty_ack_after_resync_reaches_its_waiter() {
        let version = version();
        let responses = ControlResponses::new_for_test();
        let kitty = responses.wait_for_test(9, MessageKind::KittyGraphicsLimitsAck);
        let queue = queue();
        queue.state.lock().unwrap().abandoned = true;
        let mut resync = Frame::new(MessageKind::ResyncRequired, Vec::new());
        resync.version = version;
        let stream = stream_of(&[resync, frame(MessageKind::KittyGraphicsLimitsAck, 9, version)]);
        read_stream(stream, &responses, version, SMART, &queue);
        assert_eq!(
            kitty.recv_timeout(Duration::from_secs(1)).unwrap().kind,
            MessageKind::KittyGraphicsLimitsAck
        );
    }

    /// `set-default-colors` makes a smart host publish ResyncRequired, and a
    /// renderer mint sent right after it is answered behind that marker. The
    /// surface's reader abandons the stream at ResyncRequired and fails its
    /// ordered waiters; the mint's Capability must still reach its requester.
    #[test]
    fn capability_after_resync_reaches_its_waiter() {
        let version = version();
        for early in [SMART, LEGACY] {
            let responses = ControlResponses::new_for_test();
            let mint = responses.wait_for_test(11, MessageKind::Capability);
            // The surface's reader abandons the stream (`HostFrames::abandon`).
            responses.fail_all_except(|kind| early.resolves(kind));
            let queue = queue();
            queue.state.lock().unwrap().abandoned = true;
            let mut resync = Frame::new(MessageKind::ResyncRequired, Vec::new());
            resync.version = version;
            let mut capability = frame(MessageKind::Capability, 11, version);
            capability.payload = vec![7; 32];
            read_stream(stream_of(&[resync, capability]), &responses, version, early, &queue);
            let reply = mint
                .recv_timeout(Duration::from_secs(1))
                .expect("the Capability reply after ResyncRequired was dropped");
            assert_eq!(reply.kind, MessageKind::Capability);
            assert_eq!(reply.payload, vec![7; 32]);
        }
    }

    /// At the end of the stream the thread fails only the waiters it owns: a
    /// queued ClearHistoryAck is still resolved by the surface's reader.
    #[test]
    fn end_of_stream_leaves_queued_ordered_responses_to_the_surface_reader() {
        let version = version();
        let responses = ControlResponses::new_for_test();
        let clear = responses.wait_for_test(5, MessageKind::ClearHistoryAck);
        let input = responses.wait_for_test(6, MessageKind::InputAck);
        let queue = queue();
        let stream = stream_of(&[frame(MessageKind::ClearHistoryAck, 5, version)]);
        read_stream(stream, &responses, version, SMART, &queue);
        assert!(responses.has_waiter(5), "the ordered waiter was failed before its frame");
        assert!(!responses.has_waiter(6), "the thread must fail the early waiters it owns");
        assert!(input.recv_timeout(Duration::from_millis(10)).is_err());
        let state = queue.state.lock().unwrap();
        assert!(state.ended);
        let queued = state.frames.front().expect("the ClearHistoryAck frame was not queued");
        assert!(responses.resolve(queued));
        assert_eq!(clear.recv().unwrap().kind, MessageKind::ClearHistoryAck);
    }

    /// A cell-pixel request whose caller stopped waiting (a deferred waiter)
    /// still owns its acknowledgement when that acknowledgement is queued at
    /// the end of the stream: the surface's reader resolves it in order.
    #[test]
    fn end_of_stream_keeps_a_deferred_cell_pixel_waiter_whose_ack_is_queued() {
        let version = version();
        let responses = ControlResponses::new_for_test();
        let _deferred = responses.wait_for_test(7, MessageKind::CellPixelSizeAck);
        assert!(responses.defer_cell_pixel(7, (9, 18)));
        let queue = queue();
        let stream = stream_of(&[
            frame(MessageKind::CellPixelSizeAck, 7, version),
            frame(MessageKind::Exit, 0, version),
        ]);
        read_stream(stream, &responses, version, SMART, &queue);
        assert!(
            responses.has_waiter(7),
            "the deferred cell-pixel waiter was failed before its queued acknowledgement"
        );
        let state = queue.state.lock().unwrap();
        assert!(state.ended);
        let queued = state.frames.front().expect("the CellPixelSizeAck frame was not queued");
        assert!(responses.resolve(queued), "the queued acknowledgement found no waiter");
    }

    /// After `abandon`, ordered frames are discarded instead of queued, so a
    /// backlog larger than the queue budget cannot delay an acknowledgement.
    #[test]
    fn abandoned_streams_discard_ordered_frames_and_still_resolve_acks() {
        let version = version();
        let responses = ControlResponses::new_for_test();
        let kitty = responses.wait_for_test(3, MessageKind::KittyGraphicsLimitsAck);
        let queue = queue();
        queue.state.lock().unwrap().abandoned = true;
        let mut frames = vec![output(vec![b'x'; 1024 * 1024], version); 12];
        frames.push(frame(MessageKind::KittyGraphicsLimitsAck, 3, version));
        read_stream(stream_of(&frames), &responses, version, SMART, &queue);
        assert!(kitty.recv_timeout(Duration::from_secs(1)).is_ok());
        let state = queue.state.lock().unwrap();
        assert!(state.frames.is_empty() && state.queued_payload == 0);
    }

    /// A Kitty limits acknowledgement whose requester already gave up does
    /// not end the connection.
    #[test]
    fn late_kitty_ack_keeps_the_connection() {
        let version = version();
        let responses = ControlResponses::new_for_test();
        let queue = queue();
        let stream = stream_of(&[
            frame(MessageKind::KittyGraphicsLimitsAck, 4, version),
            output(b"after", version),
        ]);
        read_stream(stream, &responses, version, SMART, &queue);
        let state = queue.state.lock().unwrap();
        assert_eq!(state.frames.len(), 1, "the frame after the late ack was not read");
    }

    /// An InputAck nobody waits for ends the connection, as it did when the
    /// surface's reader resolved it inline.
    #[test]
    fn unknown_input_ack_ends_the_stream() {
        let version = version();
        let responses = ControlResponses::new_for_test();
        let queue = queue();
        let stream =
            stream_of(&[frame(MessageKind::InputAck, 8, version), output(b"after", version)]);
        read_stream(stream, &responses, version, LEGACY, &queue);
        let state = queue.state.lock().unwrap();
        assert!(state.ended && state.frames.is_empty(), "the connection must end there");
    }
}
>>>>>>> theirs
