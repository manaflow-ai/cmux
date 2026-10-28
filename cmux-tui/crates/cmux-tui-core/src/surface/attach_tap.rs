//! Per-viewer byte attach queues: one bounded queue per attached viewer,
//! filled under the terminal lock by the reader and drained by the viewer's
//! attach worker.
//!
//! A legacy viewer that falls behind its byte budget is disconnected
//! (`AttachLifecycle::mark_overflow`). A snapshot viewer
//! (`terminal-snapshot-v1`) is resynchronized instead: the queue drops its
//! pending frames, records that the viewer needs a snapshot, and the worker
//! sends one READY snapshot taken under the terminal lock before live bytes.
//!
//! A replay viewer (a byte mirror) learns of a geometry change by pull: the
//! commit only marks its queue (`needs_replay`), and when the viewer has
//! taken every frame queued before the mark (output queued after it does not
//! hold the replay back), one replay of the terminal at that later cut,
//! taken under the terminal lock, is queued for it
//! (`PtyTerminalRuntime::deliver_pending_replays_locked`). A burst of resize
//! steps then costs at most one replay per time the viewer catches up, and
//! none on the commit itself.
//!
//! Output fans out without a copy per viewer: each viewer queues a handle to
//! the one shared chunk, cut from the PTY's [`OutputArena`], and a slow
//! viewer's adjacent chunks merge into an [`OutputRope`] that is joined on the
//! viewer's own thread.

use super::snapshot_attach::LocalReadySnapshot;
use super::*;
use bytes::Bytes;
use std::ops::DerefMut;

mod output_arena;
mod output_rope;
mod visibility;
#[cfg(test)]
pub(super) use output_arena::OUTPUT_ARENA_BLOCK_BYTES;
pub(super) use output_arena::OutputArena;
#[cfg(test)]
pub(super) use output_rope::OUTPUT_ROPE_COPY_MAX_BYTES;
pub(super) use output_rope::OutputRope;
pub(crate) use visibility::TapVisibility;

/// A PTY's attach viewers and the arena their output is cut from, both under
/// the `pty.taps` lock the reader already holds to fan out.
#[derive(Default)]
pub(super) struct AttachTaps {
    taps: Vec<AttachTap>,
    output: OutputArena,
}

impl AttachTaps {
    /// `bytes` as one chunk every viewer shares. The arena block is dropped
    /// once no viewer is left.
    pub(super) fn output_chunk(&mut self, bytes: &[u8]) -> Option<Bytes> {
        if self.taps.is_empty() {
            self.output.release();
            return None;
        }
        Some(self.output.chunk(bytes))
    }
}

impl Deref for AttachTaps {
    type Target = Vec<AttachTap>;

    fn deref(&self) -> &Self::Target {
        &self.taps
    }
}

impl DerefMut for AttachTaps {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.taps
    }
}

pub struct AttachFrameReceiver {
    state: Arc<AttachTapState>,
    lifecycle: AttachLifecycle,
}

impl AttachFrameReceiver {
    fn pop_item(queue: &mut AttachTapQueue) -> Option<QueuedFrame> {
        let item = queue.frames.pop_front()?;
        queue.popped += 1;
        queue.retained_bytes = queue.retained_bytes.saturating_sub(item.retained_bytes());
        Some(item)
    }

    /// The next frame of a plain receiver. Only a snapshot viewer that opted
    /// into local history is ever offered a local READY, and it reads its
    /// queue with `recv_viewer_event`; any other item is skipped. The caller
    /// releases the queue lock before it joins the frame.
    fn pop(queue: &mut AttachTapQueue) -> Option<TakenFrame> {
        loop {
            match Self::pop_item(queue)? {
                QueuedFrame::Output(rope) => return Some(TakenFrame::Output(rope)),
                QueuedFrame::Frame(frame) => return Some(TakenFrame::Frame(frame)),
                QueuedFrame::LocalReady(_) => {}
            }
        }
    }

    /// The replay a geometry change asked this replay viewer for, once it
    /// has taken every frame queued before the change (frames queued after
    /// it do not hold the replay back: a viewer that keeps up with steady
    /// output would otherwise never find its queue empty) and no build of it
    /// is out. The replay is built at a later cut and queued behind the
    /// frames still waiting, which it replaces. The caller releases the
    /// queue lock before it builds the replay.
    fn take_due_replay(&self, queue: &mut AttachTapQueue) -> Option<PendingReplay> {
        if !queue.needs_replay
            || queue.replay_building
            || !queue.sender_alive
            || queue.popped < queue.replay_after
        {
            return None;
        }
        // A live resize runs: the replay waits for its end. Read from the
        // terminal each time (no per-viewer copy that an end could miss):
        // its end wakes every viewer to look again (`release_live_replays`).
        // The terminal's live flag itself, shared: no strong reference to the
        // terminal under this queue lock (dropping the last one here would
        // drop its taps, whose drop locks this queue).
        if self.state.live_resize.load(Ordering::Acquire) != 0 {
            return None;
        }
        queue.replay_building = true;
        Some(PendingReplay { state: Arc::downgrade(&self.state) })
    }

    pub fn recv(&self) -> Result<AttachFrame, RecvError> {
        let mut queue = self.state.queue.lock().recover_poison();
        loop {
            // A due replay first: once the frames before the change are
            // taken, later frames must not keep it waiting.
            if let Some(replay) = self.take_due_replay(&mut queue) {
                drop(queue);
                replay.build();
                queue = self.state.queue.lock().recover_poison();
                continue;
            }
            if let Some(frame) = Self::pop(&mut queue) {
                drop(queue);
                return Ok(frame.into_frame());
            }
            if !queue.sender_alive {
                return Err(RecvError);
            }
            queue = self.state.ready.wait(queue).recover_poison();
        }
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Result<AttachFrame, RecvTimeoutError> {
        let started = Instant::now();
        let mut queue = self.state.queue.lock().recover_poison();
        loop {
            // A due replay first: once the frames before the change are
            // taken, later frames must not keep it waiting.
            if let Some(replay) = self.take_due_replay(&mut queue) {
                drop(queue);
                replay.build();
                queue = self.state.queue.lock().recover_poison();
                continue;
            }
            if let Some(frame) = Self::pop(&mut queue) {
                drop(queue);
                return Ok(frame.into_frame());
            }
            if !queue.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            let Some(remaining) = timeout.checked_sub(started.elapsed()) else {
                return Err(RecvTimeoutError::Timeout);
            };
            let (next, result) = self.state.ready.wait_timeout(queue, remaining).recover_poison();
            queue = next;
            if result.timed_out() && queue.frames.is_empty() {
                return Err(RecvTimeoutError::Timeout);
            }
        }
    }

    /// Wakes a blocked `recv_interruptible` when `interrupt` fires.
    pub(crate) fn wake_on(&self, interrupt: &crate::stream_interrupt::StreamInterrupt) {
        let state = Arc::downgrade(&self.state);
        interrupt.on_fire(move || {
            if let Some(state) = state.upgrade() {
                let _queue = state.queue.lock().unwrap_or_else(|error| error.into_inner());
                state.ready.notify_all();
            }
        });
    }

    /// Blocks for a frame until `deadline` (if any). Returns `Timeout` when
    /// the deadline passes or `interrupt` has fired with nothing queued.
    pub(crate) fn recv_interruptible(
        &self,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
        deadline: Option<Instant>,
    ) -> Result<AttachFrame, RecvTimeoutError> {
        let mut queue = self.state.queue.lock().recover_poison();
        loop {
            // A due replay first: once the frames before the change are
            // taken, later frames must not keep it waiting.
            if let Some(replay) = self.take_due_replay(&mut queue) {
                drop(queue);
                replay.build();
                queue = self.state.queue.lock().recover_poison();
                continue;
            }
            if let Some(frame) = Self::pop(&mut queue) {
                drop(queue);
                return Ok(frame.into_frame());
            }
            if !queue.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            if interrupt.is_fired() {
                return Err(RecvTimeoutError::Timeout);
            }
            queue = match deadline {
                None => self.state.ready.wait(queue).recover_poison(),
                Some(deadline) => {
                    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                        return Err(RecvTimeoutError::Timeout);
                    };
                    self.state.ready.wait_timeout(queue, remaining).recover_poison().0
                }
            };
        }
    }

    /// The next frame without waiting. A replay that is due is built here,
    /// on the caller's thread; a view's drain, which must not hold its worker
    /// for that, takes [`Self::try_byte_view_event`] instead.
    pub fn try_recv(&self) -> Result<AttachFrame, TryRecvError> {
        loop {
            match self.try_byte_view_event()? {
                ByteViewEvent::Frame(frame) => return Ok(frame),
                ByteViewEvent::ReplayDue(replay) => replay.build(),
            }
        }
    }

    /// The next event of a replay viewer's drain, without waiting: a queued
    /// frame, or the replay a geometry change asked for, which the drain
    /// builds off its own worker ([`PendingReplay::build`]).
    pub(crate) fn try_byte_view_event(&self) -> Result<ByteViewEvent, TryRecvError> {
        let mut queue = self.state.queue.lock().recover_poison();
        // A due replay first: once the frames before the change are taken,
        // later frames must not keep it waiting (steady output would).
        if let Some(replay) = self.take_due_replay(&mut queue) {
            Ok(ByteViewEvent::ReplayDue(replay))
        } else if let Some(frame) = Self::pop(&mut queue) {
            drop(queue);
            Ok(ByteViewEvent::Frame(frame.into_frame()))
        } else if queue.sender_alive {
            Err(TryRecvError::Empty)
        } else {
            Err(TryRecvError::Disconnected)
        }
    }
}

/// What a replay viewer's drain handles next.
#[derive(Debug)]
pub(crate) enum ByteViewEvent {
    Frame(AttachFrame),
    /// Every frame before a geometry change is taken: build its replay.
    ReplayDue(PendingReplay),
}

/// The replay a replay viewer waits for. [`Self::build`] takes the terminal
/// lock, so a drain posts it to a sequence of its own (bulk work, like a
/// snapshot viewer's READY encode) and takes the replay from its queue when
/// it lands there. While one is out, the viewer is offered no other: every
/// geometry change until the build takes the terminal lock is covered by
/// that build, and one after it asks for the next (one build in flight per
/// viewer, the newest superseding the steps before it).
#[derive(Debug)]
pub(crate) struct PendingReplay {
    state: Weak<AttachTapState>,
}

impl PendingReplay {
    /// Build the terminal's replay at this cut and queue it for every viewer
    /// that waits for one; a replay another viewer's build delivered already
    /// makes this a no-op. The caller holds no terminal or queue lock.
    pub(crate) fn build(self) {
        let Some(state) = self.state.upgrade() else { return };
        match state.replay_source.upgrade() {
            Some(terminal) => terminal.deliver_pending_replays(),
            // The terminal is going: its taps drop and end this receiver.
            None => state.queue.lock().recover_poison().needs_replay = false,
        }
    }
}

impl Drop for PendingReplay {
    /// The build is done (or was never run): the viewer may be offered the
    /// next one, and its drain looks again.
    fn drop(&mut self) {
        let Some(state) = self.state.upgrade() else { return };
        state.queue.lock().recover_poison().replay_building = false;
        state.wake_all();
    }
}

impl Drop for AttachFrameReceiver {
    fn drop(&mut self) {
        let mut queue = self.state.queue.lock().recover_poison();
        queue.receiver_alive = false;
        queue.frames.clear();
        queue.popped = queue.pushed;
        queue.retained_bytes = 0;
        drop(queue);
        self.lifecycle.cancel();
        self.state.ready.notify_all();
    }
}

impl AttachFrame {
    /// Output bytes as one frame, echoing `flow` when it is not 0.
    pub(crate) fn with_flow(output: Bytes, flow: u64) -> Self {
        if flow == 0 { Self::Output(output) } else { Self::FlowOutput { output, flow } }
    }

    /// Output that changed colors. The bytes keep no spare capacity, so the
    /// backlog's count of their length is the memory they hold.
    pub(crate) fn output_with_colors(
        output: Vec<u8>,
        colors: Box<TerminalColors>,
        flow: u64,
    ) -> Self {
        Self::OutputWithColors { output: output.into_boxed_slice().into(), colors, flow }
    }

    /// The key press this frame's output echoes (0: none).
    pub(crate) fn flow(&self) -> u64 {
        match self {
            Self::FlowOutput { flow, .. } | Self::OutputWithColors { flow, .. } => *flow,
            _ => 0,
        }
    }

    /// The PTY output this frame carries, if it is an output frame.
    pub(crate) fn output(&self) -> Option<&[u8]> {
        match self {
            Self::Output(output)
            | Self::FlowOutput { output, .. }
            | Self::OutputWithColors { output, .. } => Some(output),
            _ => None,
        }
    }

    /// The colors one output transition replaces, if it carries them.
    pub(crate) fn output_colors(&self) -> Option<&TerminalColors> {
        match self {
            Self::OutputWithColors { colors, .. } => Some(colors),
            _ => None,
        }
    }

    /// The fields of a grid replacement, with or without its colors.
    pub(crate) fn resize(&self) -> Option<AttachResize<'_>> {
        match self {
            Self::Resized {
                cols,
                rows,
                replay,
                kitty_image_aliases,
                kitty_state,
                pending_sequence,
            } => Some(AttachResize {
                cols: *cols,
                rows: *rows,
                replay,
                kitty_image_aliases,
                kitty_state: *kitty_state,
                colors: None,
                pending_sequence,
            }),
            Self::ResizedWithColors {
                cols,
                rows,
                replay,
                kitty_image_aliases,
                kitty_state,
                colors,
                pending_sequence,
            } => Some(AttachResize {
                cols: *cols,
                rows: *rows,
                replay,
                kitty_image_aliases,
                kitty_state: *kitty_state,
                colors: Some(colors),
                pending_sequence,
            }),
            _ => None,
        }
    }

    pub(super) fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            + match self {
                Self::Output(bytes) | Self::FlowOutput { output: bytes, .. } => bytes.len(),
                Self::Resized { replay, kitty_image_aliases, .. } => {
                    replay.len()
                        + kitty_image_aliases.capacity() * size_of::<ghostty_vt::KittyImageAlias>()
                }
                Self::OutputWithColors { output, .. } => output.len() + size_of::<TerminalColors>(),
                Self::ResizedWithColors { replay, kitty_image_aliases, .. } => {
                    replay.len()
                        + kitty_image_aliases.capacity() * size_of::<ghostty_vt::KittyImageAlias>()
                        + size_of::<TerminalColors>()
                }
                Self::ColorsChanged(_) => size_of::<TerminalColors>(),
            }
    }
}

/// A plain receiver's next frame, joined after the queue lock is released.
enum TakenFrame {
    Output(OutputRope),
    Frame(AttachFrame),
}

impl TakenFrame {
    fn into_frame(self) -> AttachFrame {
        match self {
            Self::Output(rope) => rope.into_frame(),
            Self::Frame(frame) => frame,
        }
    }
}

/// A grid replacement (`Resized` or `ResizedWithColors`) by reference.
#[derive(Clone, Copy, Debug)]
pub(crate) struct AttachResize<'a> {
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    pub(crate) replay: &'a [u8],
    pub(crate) kitty_image_aliases: &'a [ghostty_vt::KittyImageAlias],
    pub(crate) kitty_state: KittyReplayState,
    pub(crate) colors: Option<&'a TerminalColors>,
    /// The incomplete sequence the replay ends inside (see [`AttachStream`]).
    pub(crate) pending_sequence: &'a [u8],
}

/// One item of a viewer queue.
#[derive(Debug)]
pub(super) enum QueuedFrame {
    /// Plain output (`Output`, `FlowOutput`); the output after it merges in
    /// while the viewer has not taken it.
    Output(OutputRope),
    Frame(AttachFrame),
    /// A local-history READY at a resize cut, after every frame queued before
    /// the resize (`terminal-snapshot-local-history-v1`).
    LocalReady(Arc<LocalReadySnapshot>),
}

impl QueuedFrame {
    fn new(frame: AttachFrame) -> Self {
        match frame {
            AttachFrame::Output(output) => Self::Output(OutputRope::new(output, 0)),
            AttachFrame::FlowOutput { output, flow } => Self::Output(OutputRope::new(output, flow)),
            other => Self::Frame(other),
        }
    }

    fn retained_bytes(&self) -> usize {
        match self {
            Self::Output(rope) => rope.retained_bytes(),
            Self::Frame(frame) => frame.retained_bytes(),
            // The READY bytes are shared between viewers; each viewer's
            // backlog still counts them, so a stuck viewer stays bounded.
            Self::LocalReady(ready) => size_of::<Self>() + ready.frame.data.len(),
        }
    }
}

pub(super) enum AttachFrameMerge {
    Merged,
    Unmerged(AttachFrame),
    Overflow,
}

#[derive(Clone, Default)]
pub(crate) struct AttachLifecycle {
    state: Arc<AttachLifecycleState>,
}

struct AttachLifecycleState {
    canceled: AtomicBool,
    overflowed: AtomicBool,
    overflow_reported: AtomicBool,
    /// Fired by `cancel`, so attach loops block instead of polling it.
    canceled_interrupts: crate::stream_interrupt::InterruptSet,
    /// Whether this viewer writes a replay's pending sequence after its own
    /// sequences (`terminal-pending-sequence-v1`). A viewer that does not
    /// would write color sequences into it, so it reconnects instead.
    resumes_pending_sequence: AtomicBool,
}

impl Default for AttachLifecycleState {
    fn default() -> Self {
        Self {
            canceled: AtomicBool::new(false),
            overflowed: AtomicBool::new(false),
            overflow_reported: AtomicBool::new(false),
            canceled_interrupts: crate::stream_interrupt::InterruptSet::default(),
            resumes_pending_sequence: AtomicBool::new(true),
        }
    }
}

impl AttachLifecycle {
    pub(crate) fn set_resumes_pending_sequence(&self, resumes: bool) {
        self.state.resumes_pending_sequence.store(resumes, Ordering::Release);
    }

    pub(super) fn resumes_pending_sequence(&self) -> bool {
        self.state.resumes_pending_sequence.load(Ordering::Acquire)
    }

    pub(crate) fn cancel(&self) {
        self.state.canceled.store(true, Ordering::Release);
        self.state.canceled_interrupts.fire();
    }

    /// Fires `interrupt` when this attachment is canceled.
    pub(crate) fn register_interrupt(
        &self,
        interrupt: &Arc<crate::stream_interrupt::StreamInterrupt>,
    ) {
        self.state.canceled_interrupts.register(interrupt);
    }

    pub(crate) fn mark_overflow(&self) {
        self.state.overflowed.store(true, Ordering::Release);
        self.cancel();
    }

    pub(crate) fn is_canceled(&self) -> bool {
        self.state.canceled.load(Ordering::Acquire)
    }

    pub(crate) fn overflowed(&self) -> bool {
        self.state.overflowed.load(Ordering::Acquire)
    }

    pub(crate) fn claim_overflow_report(&self) -> bool {
        self.overflowed()
            && self
                .state
                .overflow_reported
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
    }
}

pub(super) struct AttachTap {
    pub(super) state: Arc<AttachTapState>,
    pub(super) lifecycle: AttachLifecycle,
}

pub(super) struct AttachTapState {
    pub(super) queue: Mutex<AttachTapQueue>,
    ready: Condvar,
    /// The viewer's drain task when it runs on a sequence instead of
    /// blocking on `ready` (attach streams, p05-ipc-079).
    ready_hook: crate::stream_interrupt::ReadyHook,
    /// A hidden snapshot viewer (`set-stream-priority hidden`, p05-ipc-142):
    /// output only marks it dirty and nothing wakes it. Written under the
    /// queue lock; read after it is released by the wakes.
    hidden: AtomicBool,
    /// The terminal a replay viewer's due replay is built from (empty for a
    /// snapshot viewer and a bare test tap).
    replay_source: Weak<PtyTerminalRuntime>,
    /// The terminal's live-resize flag (`PtyTerminalRuntime::live_resize`),
    /// shared; a viewer of no terminal has its own, always 0.
    live_resize: Arc<AtomicU64>,
}

impl AttachTapState {
    /// After a change the receiver acts on: a queued item, a snapshot to
    /// send, the sender gone. Called with the queue lock released.
    fn wake_one(&self) {
        // A hidden viewer acts on nothing until it shows (`TapVisibility`).
        if self.hidden.load(Ordering::Acquire) {
            return;
        }
        self.ready.notify_one();
        self.ready_hook.wake();
    }

    fn wake_all(&self) {
        self.ready.notify_all();
        self.ready_hook.wake();
    }
}

pub(super) struct AttachTapQueue {
    frames: VecDeque<QueuedFrame>,
    retained_bytes: usize,
    max_frames: usize,
    max_retained_bytes: usize,
    sender_alive: bool,
    pub(super) receiver_alive: bool,
    /// A snapshot viewer resyncs by snapshot instead of disconnecting.
    snapshot_mode: bool,
    /// The viewer's pending bytes were dropped (backlog cap, grid change or a
    /// snapshot request); its worker sends a READY snapshot next.
    needs_snapshot: bool,
    /// Backlog resyncs since attach (diagnostics and tests).
    resyncs: u64,
    /// The last snapshot could not be encoded (an unfinished escape sequence
    /// over the continuation budget); the next output asks again.
    snapshot_deferred: bool,
    /// The viewer reflows its own history: a resize reaches it as a
    /// local-history READY while it is not behind.
    local_history: bool,
    /// A replay viewer's grid changed: once the viewer has taken every frame
    /// queued until then, one replay at that later cut replaces its grid.
    /// Output keeps flowing meanwhile (the replay replaces what it built on
    /// the old grid, and every byte keeps its place in the stream), and
    /// further changes while it waits need nothing more.
    needs_replay: bool,
    /// A [`PendingReplay`] of this viewer is out.
    replay_building: bool,
    /// Items ever queued and ever taken. A queued item that later output
    /// merges into is one item.
    pub(super) pushed: u64,
    pub(super) popped: u64,
    /// `pushed` when `needs_replay` was set: the replay is due once `popped`
    /// reaches it.
    replay_after: u64,
}

impl AttachTapQueue {
    /// Drop every pending frame and ask the worker for a snapshot. The
    /// snapshot is taken later under the terminal lock, so it covers the
    /// dropped bytes and every byte offered until then.
    fn fall_behind(&mut self) {
        self.frames.clear();
        self.popped = self.pushed;
        self.retained_bytes = 0;
        if !self.needs_snapshot {
            self.needs_snapshot = true;
            self.resyncs += 1;
        }
    }

    /// Whether a resize now may reach this viewer as a local-history READY:
    /// it opted in and holds every frame since its last snapshot.
    fn takes_local_ready(&self) -> bool {
        self.snapshot_mode
            && self.local_history
            && self.receiver_alive
            && !self.needs_snapshot
            && !self.snapshot_deferred
    }
}

/// What a snapshot viewer's worker handles next.
#[derive(Debug)]
pub(crate) enum ViewerEvent {
    Frame(AttachFrame),
    /// Send a READY snapshot; queued bytes were dropped.
    Snapshot,
    /// Send this local-history READY (no history follows it).
    LocalReady(Arc<LocalReadySnapshot>),
}

/// Lets a command outside the attach worker (`snapshot-request`) ask one
/// snapshot viewer for a resync. Holds no strong reference to the queue.
#[derive(Clone)]
pub(crate) struct SnapshotRequestHandle {
    state: Weak<AttachTapState>,
}

impl SnapshotRequestHandle {
    /// Whether a snapshot is queued for the viewer (a deferred one is not:
    /// it waits for output, and a request may ask again).
    pub(crate) fn snapshot_pending(&self) -> bool {
        self.state.upgrade().is_some_and(|state| state.queue.lock().recover_poison().needs_snapshot)
    }

    /// Returns false when the viewer is gone.
    pub(crate) fn request(&self) -> bool {
        let Some(state) = self.state.upgrade() else { return false };
        let mut queue = state.queue.lock().recover_poison();
        if !queue.receiver_alive || !queue.sender_alive {
            return false;
        }
        queue.fall_behind();
        drop(queue);
        state.wake_all();
        true
    }
}

impl AttachFrameReceiver {
    /// Runs `hook` whenever this receiver has something to act on, for a
    /// viewer whose drain polls (`try_recv`, `try_viewer_event`) on a
    /// sequence instead of blocking. False when a hook is set already.
    pub(crate) fn on_ready(&self, hook: impl Fn() + Send + Sync + 'static) -> bool {
        self.state.ready_hook.set(hook)
    }

    /// The next event of a snapshot viewer without waiting: a pending
    /// snapshot comes before any frame, as in `recv_viewer_event`.
    pub(crate) fn try_viewer_event(&self) -> Result<ViewerEvent, TryRecvError> {
        let mut queue = self.state.queue.lock().recover_poison();
        if queue.needs_snapshot {
            return Ok(ViewerEvent::Snapshot);
        }
        match Self::pop_item(&mut queue) {
            Some(QueuedFrame::Output(rope)) => {
                // Joined outside the queue lock, as `recv_viewer_event` does.
                drop(queue);
                Ok(ViewerEvent::Frame(rope.into_frame()))
            }
            Some(QueuedFrame::Frame(frame)) => Ok(ViewerEvent::Frame(frame)),
            Some(QueuedFrame::LocalReady(ready)) => Ok(ViewerEvent::LocalReady(ready)),
            None if queue.sender_alive => Err(TryRecvError::Empty),
            None => Err(TryRecvError::Disconnected),
        }
    }

    pub(crate) fn snapshot_request_handle(&self) -> SnapshotRequestHandle {
        SnapshotRequestHandle { state: Arc::downgrade(&self.state) }
    }

    /// Next event of a snapshot viewer: a pending snapshot comes before any
    /// frame. Blocks until an event, `deadline`, or `interrupt`. Tests only:
    /// every viewer is a drain that polls `try_viewer_event`.
    #[cfg(test)]
    pub(crate) fn recv_viewer_event(
        &self,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
        deadline: Option<Instant>,
    ) -> Result<ViewerEvent, RecvTimeoutError> {
        let mut queue = self.state.queue.lock().recover_poison();
        loop {
            if queue.needs_snapshot {
                return Ok(ViewerEvent::Snapshot);
            }
            match Self::pop_item(&mut queue) {
                Some(QueuedFrame::Output(rope)) => {
                    drop(queue);
                    return Ok(ViewerEvent::Frame(rope.into_frame()));
                }
                Some(QueuedFrame::Frame(frame)) => return Ok(ViewerEvent::Frame(frame)),
                Some(QueuedFrame::LocalReady(ready)) => return Ok(ViewerEvent::LocalReady(ready)),
                None => {}
            }
            if !queue.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            if interrupt.is_fired() {
                return Err(RecvTimeoutError::Timeout);
            }
            queue = match deadline {
                None => self.state.ready.wait(queue).recover_poison(),
                Some(deadline) => {
                    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                        return Err(RecvTimeoutError::Timeout);
                    };
                    self.state.ready.wait_timeout(queue, remaining).recover_poison().0
                }
            };
        }
    }

    /// Clear the pending snapshot and every queued frame. The caller holds
    /// the terminal lock while it encodes the snapshot and calls this, so
    /// the reader cannot queue a byte between the two.
    pub(crate) fn finish_snapshot_locked(&self) {
        let mut queue = self.state.queue.lock().recover_poison();
        queue.frames.clear();
        queue.popped = queue.pushed;
        queue.retained_bytes = 0;
        queue.needs_snapshot = false;
        queue.snapshot_deferred = false;
    }

    /// The snapshot could not be encoded now: drop queued frames and retry
    /// at the next output instead of disconnecting the viewer.
    pub(crate) fn defer_snapshot(&self) {
        let mut queue = self.state.queue.lock().recover_poison();
        queue.frames.clear();
        queue.popped = queue.pushed;
        queue.retained_bytes = 0;
        queue.needs_snapshot = false;
        queue.snapshot_deferred = true;
    }

    /// Opt this viewer into local-history READYs at resizes.
    pub(crate) fn set_local_history(&self, enabled: bool) {
        self.state.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner).local_history =
            enabled;
    }

    /// Bytes currently queued for this viewer.
    #[cfg(test)]
    pub(crate) fn backlog_bytes(&self) -> usize {
        self.state.queue.lock().unwrap().retained_bytes
    }

    /// Backlog resyncs since attach.
    #[cfg(test)]
    pub(crate) fn resyncs(&self) -> u64 {
        self.state.queue.lock().unwrap().resyncs
    }
}

impl AttachTap {
    #[cfg(test)]
    pub(super) fn pair(
        lifecycle: AttachLifecycle,
        max_frames: usize,
        max_retained_bytes: usize,
    ) -> (Self, AttachFrameReceiver) {
        Self::pair_with_mode(lifecycle, max_frames, max_retained_bytes, false, Weak::new())
    }

    /// A replay viewer of `terminal`: a geometry change reaches it as a
    /// replay of `terminal` built when the viewer takes it.
    pub(super) fn replay_pair(
        lifecycle: AttachLifecycle,
        max_frames: usize,
        max_retained_bytes: usize,
        terminal: Weak<PtyTerminalRuntime>,
    ) -> (Self, AttachFrameReceiver) {
        Self::pair_with_mode(lifecycle, max_frames, max_retained_bytes, false, terminal)
    }

    /// A snapshot viewer's queue: bounded by `backlog_bytes`; overflow drops
    /// the backlog and asks for a snapshot instead of disconnecting.
    pub(super) fn snapshot_pair(
        lifecycle: AttachLifecycle,
        max_frames: usize,
        backlog_bytes: usize,
    ) -> (Self, AttachFrameReceiver) {
        Self::pair_with_mode(lifecycle, max_frames, backlog_bytes, true, Weak::new())
    }

    fn pair_with_mode(
        lifecycle: AttachLifecycle,
        max_frames: usize,
        max_retained_bytes: usize,
        snapshot_mode: bool,
        replay_source: Weak<PtyTerminalRuntime>,
    ) -> (Self, AttachFrameReceiver) {
        let live_resize = replay_source
            .upgrade()
            .map_or_else(Arc::default, |terminal| terminal.live_resize.clone());
        let state = Arc::new(AttachTapState {
            queue: Mutex::new(AttachTapQueue {
                frames: VecDeque::new(),
                retained_bytes: 0,
                max_frames,
                max_retained_bytes,
                sender_alive: true,
                receiver_alive: true,
                snapshot_mode,
                // The first event of a snapshot viewer is its READY snapshot.
                needs_snapshot: snapshot_mode,
                resyncs: 0,
                snapshot_deferred: false,
                local_history: false,
                needs_replay: false,
                replay_building: false,
                pushed: 0,
                popped: 0,
                replay_after: 0,
            }),
            ready: Condvar::new(),
            ready_hook: Default::default(),
            hidden: AtomicBool::new(false),
            replay_source,
            live_resize,
        });
        (
            Self { state: state.clone(), lifecycle: lifecycle.clone() },
            AttachFrameReceiver { state, lifecycle },
        )
    }

    /// A snapshot viewer resyncs by snapshot; a replay viewer needs a replay.
    pub(super) fn is_snapshot(&self) -> bool {
        self.state.queue.lock().recover_poison().snapshot_mode
    }

    /// Ask a snapshot viewer for a resync (a grid change without a replay).
    /// No-op for a replay viewer.
    pub(super) fn resync_snapshot(&self) {
        let mut queue = self.state.queue.lock().recover_poison();
        if queue.snapshot_mode && queue.receiver_alive {
            queue.fall_behind();
            drop(queue);
            self.state.wake_one();
        }
    }

    /// A geometry change: a replay viewer waits for one replay at a later cut
    /// (see `needs_replay`). No-op for a snapshot viewer. False when the
    /// viewer is gone.
    pub(super) fn request_replay(&self) -> bool {
        if self.lifecycle.is_canceled() {
            return false;
        }
        let mut queue = self.state.queue.lock().recover_poison();
        if !queue.receiver_alive {
            drop(queue); // cancel fires interrupt wakers that lock this queue.
            self.lifecycle.cancel();
            return false;
        }
        if queue.snapshot_mode {
            return true;
        }
        // During a live resize the replay waits for its end (the viewer asks
        // the terminal, `take_due_replay`); output keeps flowing meanwhile.
        if queue.needs_replay {
            return true;
        }
        queue.needs_replay = true;
        queue.replay_after = queue.pushed;
        drop(queue);
        self.state.wake_one();
        true
    }

    /// A live resize ended: a replay it held is due now (once the frames
    /// queued before the mark are taken); wake the viewer to look again.
    /// False when the viewer is gone.
    pub(super) fn release_live_replay(&self) -> bool {
        if self.lifecycle.is_canceled() {
            return false;
        }
        let queue = self.state.queue.lock().recover_poison();
        let (alive, waiting) = (queue.receiver_alive, queue.needs_replay);
        drop(queue);
        if waiting {
            self.state.wake_all();
        }
        alive
    }

    /// Whether this replay viewer waits for a replay.
    pub(super) fn needs_replay(&self) -> bool {
        self.state.queue.lock().recover_poison().needs_replay
    }

    /// Queue `frame`, the replay of the terminal at the caller's cut (the
    /// caller holds the terminal lock), for a viewer that waits for one.
    /// False when the viewer overflowed or is gone.
    pub(super) fn finish_replay(&self, frame: AttachFrame) -> bool {
        let mut queue = self.state.queue.lock().recover_poison();
        if !queue.needs_replay {
            return true;
        }
        queue.needs_replay = false;
        if !queue.receiver_alive {
            drop(queue);
            self.lifecycle.cancel();
            return false;
        }
        let item = QueuedFrame::new(frame);
        // The replay is the terminal at the caller's cut, and every queued
        // frame is output from before it: when the replay does not fit
        // behind them, they are dropped, as the replay replaces them, so a
        // replay within VT_REPLAY_MAX_BYTES always fits (an empty queue's
        // room) instead of overflowing a mirror that keeps up (H10 review).
        // Their key-press flow marks are trace only; this case would
        // otherwise disconnect the mirror.
        if item.retained_bytes() > queue.max_retained_bytes.saturating_sub(queue.retained_bytes)
            || queue.frames.len() >= queue.max_frames
        {
            queue.frames.clear();
            queue.popped = queue.pushed;
            queue.retained_bytes = 0;
        }
        self.push(queue, item)
    }

    /// Whether this viewer would take a local-history READY of a resize now.
    pub(super) fn wants_local_ready(&self) -> bool {
        !self.lifecycle.is_canceled()
            && !self.state.hidden.load(Ordering::Acquire)
            && self
                .state
                .queue
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .takes_local_ready()
    }

    /// A resize without a replay frame: a viewer that takes `local` gets it
    /// queued after its pending frames; any other snapshot viewer resyncs.
    pub(super) fn resync_snapshot_at_cut(&self, local: Option<&Arc<LocalReadySnapshot>>) {
        let queue = self.state.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(local) = local
            && queue.takes_local_ready()
            && !self.state.hidden.load(Ordering::Acquire)
        {
            self.push(queue, QueuedFrame::LocalReady(local.clone()));
            return;
        }
        drop(queue);
        self.resync_snapshot();
    }

    /// Queue `item` within the caps; past them, overflow.
    fn push(
        &self,
        mut queue: std::sync::MutexGuard<'_, AttachTapQueue>,
        item: QueuedFrame,
    ) -> bool {
        let item_bytes = item.retained_bytes();
        if item_bytes > queue.max_retained_bytes.saturating_sub(queue.retained_bytes)
            || queue.frames.len() >= queue.max_frames
        {
            return self.overflow(queue);
        }
        queue.retained_bytes = queue.retained_bytes.saturating_add(item_bytes);
        queue.frames.push_back(item);
        queue.pushed += 1;
        drop(queue);
        self.state.wake_one();
        true
    }

    /// Overflow: a legacy viewer disconnects, a snapshot viewer falls behind.
    fn overflow(&self, mut queue: std::sync::MutexGuard<'_, AttachTapQueue>) -> bool {
        if queue.snapshot_mode {
            queue.fall_behind();
            drop(queue);
            self.state.wake_one();
            return true;
        }
        drop(queue);
        self.lifecycle.mark_overflow();
        false
    }

    pub(super) fn try_send(&self, mut frame: AttachFrame) -> bool {
        if self.lifecycle.is_canceled() {
            return false;
        }
        let mut queue = self.state.queue.lock().recover_poison();
        if !queue.receiver_alive {
            drop(queue); // cancel fires interrupt wakers that lock this queue.
            self.lifecycle.cancel();
            return false;
        }
        if queue.snapshot_mode {
            if self.state.hidden.load(Ordering::Acquire) {
                // Parsed by the terminal already; the viewer gets a READY of
                // it when it shows, and nothing before.
                if !queue.needs_snapshot || !queue.frames.is_empty() {
                    queue.mark_dirty();
                }
                return true;
            }
            if queue.snapshot_deferred {
                // Retry the snapshot now that the parser has moved on.
                queue.snapshot_deferred = false;
                queue.fall_behind();
                drop(queue);
                self.state.wake_one();
                return true;
            }
            if queue.needs_snapshot {
                // The pending snapshot will include this transition.
                return true;
            }
            if matches!(frame, AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. })
            {
                // A grid change reaches a snapshot viewer as a snapshot with
                // the new generation, not as a replay.
                queue.fall_behind();
                drop(queue);
                self.state.wake_one();
                return true;
            }
        }
        if matches!(frame, AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. }) {
            // A grid replacement broadcast under the terminal lock is the
            // terminal at this cut: it is the replay the viewer waits for.
            queue.needs_replay = false;
        }
        let queue_retained_bytes = queue.retained_bytes;
        let queue_max_retained_bytes = queue.max_retained_bytes;
        if let Some(QueuedFrame::Output(pending)) = queue.frames.back_mut() {
            let previous_bytes = pending.retained_bytes();
            let max_frame_bytes = queue_max_retained_bytes
                .saturating_sub(queue_retained_bytes.saturating_sub(previous_bytes));
            match pending.merge(frame, max_frame_bytes) {
                AttachFrameMerge::Merged => {
                    let merged_bytes = pending.retained_bytes();
                    queue.retained_bytes = queue
                        .retained_bytes
                        .saturating_sub(previous_bytes)
                        .saturating_add(merged_bytes);
                    drop(queue);
                    self.state.wake_one();
                    return true;
                }
                AttachFrameMerge::Unmerged(unmerged) => frame = unmerged,
                AttachFrameMerge::Overflow => return self.overflow(queue),
            }
        }
        self.push(queue, QueuedFrame::new(frame))
    }
}

impl Drop for AttachTap {
    fn drop(&mut self) {
        self.state.queue.lock().recover_poison().sender_alive = false;
        self.state.wake_all();
    }
}
