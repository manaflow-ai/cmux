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
//! none on the commit itself. The viewer's receiver builds it on its own
//! thread (the `mux-attach-out` worker of the attachment), never on the
//! thread that resized.

use super::snapshot_attach::LocalReadySnapshot;
use super::*;
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
    /// queue with `recv_viewer_event`; any other item is skipped.
    fn pop(queue: &mut AttachTapQueue) -> Option<AttachFrame> {
        loop {
            match Self::pop_item(queue)? {
                QueuedFrame::Frame(frame) => return Some(frame),
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
        queue.replay_building = true;
        Some(PendingReplay { state: Arc::downgrade(&self.state) })
    }

    pub fn recv(&self) -> Result<AttachFrame, RecvError> {
        let mut queue = self.state.queue.lock().unwrap();
        loop {
            // A due replay first: once the frames before the change are
            // taken, later frames must not keep it waiting.
            if let Some(replay) = self.take_due_replay(&mut queue) {
                drop(queue);
                replay.build();
                queue = self.state.queue.lock().unwrap();
                continue;
            }
            if let Some(frame) = Self::pop(&mut queue) {
                return Ok(frame);
            }
            if !queue.sender_alive {
                return Err(RecvError);
            }
            queue = self.state.ready.wait(queue).unwrap();
        }
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Result<AttachFrame, RecvTimeoutError> {
        let started = Instant::now();
        let mut queue = self.state.queue.lock().unwrap();
        loop {
            if let Some(replay) = self.take_due_replay(&mut queue) {
                drop(queue);
                replay.build();
                queue = self.state.queue.lock().unwrap();
                continue;
            }
            if let Some(frame) = Self::pop(&mut queue) {
                return Ok(frame);
            }
            if !queue.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            let Some(remaining) = timeout.checked_sub(started.elapsed()) else {
                return Err(RecvTimeoutError::Timeout);
            };
            let (next, result) = self.state.ready.wait_timeout(queue, remaining).unwrap();
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
        let mut queue = self.state.queue.lock().unwrap();
        loop {
            if let Some(replay) = self.take_due_replay(&mut queue) {
                drop(queue);
                replay.build();
                queue = self.state.queue.lock().unwrap();
                continue;
            }
            if let Some(frame) = Self::pop(&mut queue) {
                return Ok(frame);
            }
            if !queue.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            if interrupt.is_fired() {
                return Err(RecvTimeoutError::Timeout);
            }
            queue = match deadline {
                None => self.state.ready.wait(queue).unwrap(),
                Some(deadline) => {
                    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                        return Err(RecvTimeoutError::Timeout);
                    };
                    self.state.ready.wait_timeout(queue, remaining).unwrap().0
                }
            };
        }
    }

    /// The next frame without waiting. A replay that is due is built here,
    /// on the caller's thread.
    pub fn try_recv(&self) -> Result<AttachFrame, TryRecvError> {
        let mut queue = self.state.queue.lock().unwrap();
        loop {
            if let Some(replay) = self.take_due_replay(&mut queue) {
                drop(queue);
                replay.build();
                queue = self.state.queue.lock().unwrap();
                continue;
            }
            return if let Some(frame) = Self::pop(&mut queue) {
                Ok(frame)
            } else if queue.sender_alive {
                Err(TryRecvError::Empty)
            } else {
                Err(TryRecvError::Disconnected)
            };
        }
    }
}

/// The replay a replay viewer waits for. [`Self::build`] takes the terminal
/// lock. While one is out, the viewer is offered no other: every geometry
/// change until the build takes the terminal lock is covered by that build,
/// and one after it asks for the next (one build in flight per viewer, the
/// newest superseding the steps before it).
pub(super) struct PendingReplay {
    state: Weak<AttachTapState>,
}

impl PendingReplay {
    /// Build the terminal's replay at this cut and queue it for every viewer
    /// that waits for one; a replay another viewer's build delivered already
    /// makes this a no-op. The caller holds no terminal or queue lock.
    pub(super) fn build(self) {
        let Some(state) = self.state.upgrade() else { return };
        match state.replay_source.upgrade() {
            Some(terminal) => terminal.deliver_pending_replays(),
            // The terminal is going: its taps drop and end this receiver.
            None => state.queue.lock().unwrap().needs_replay = false,
        }
    }
}

impl Drop for PendingReplay {
    /// The build is done (or was never run): the viewer may be offered the
    /// next one, and its receiver looks again.
    fn drop(&mut self) {
        let Some(state) = self.state.upgrade() else { return };
        state.queue.lock().unwrap().replay_building = false;
        state.ready.notify_all();
    }
}

impl Drop for AttachFrameReceiver {
    fn drop(&mut self) {
        let mut queue = self.state.queue.lock().unwrap();
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
    pub(super) fn merge_adjacent_output(
        &mut self,
        next: AttachFrame,
        max_retained_bytes: usize,
    ) -> AttachFrameMerge {
        let mut next = match next {
            AttachFrame::Output(next) => next,
            other => return AttachFrameMerge::Unmerged(other),
        };
        let AttachFrame::Output(pending) = self else {
            return AttachFrameMerge::Unmerged(AttachFrame::Output(next));
        };
        let Some(max_capacity) = max_retained_bytes.checked_sub(size_of::<Self>()) else {
            return AttachFrameMerge::Overflow;
        };
        let Some(required) = pending.len().checked_add(next.len()) else {
            return AttachFrameMerge::Overflow;
        };
        if required > max_capacity {
            return AttachFrameMerge::Overflow;
        }
        if required > pending.capacity() {
            let desired = pending.capacity().saturating_mul(2).max(required).min(max_capacity);
            let mut merged = Vec::new();
            if merged.try_reserve_exact(desired).is_err() || merged.capacity() > max_capacity {
                return AttachFrameMerge::Overflow;
            }
            merged.extend_from_slice(pending);
            merged.append(&mut next);
            *pending = merged;
        } else {
            pending.append(&mut next);
        }
        AttachFrameMerge::Merged
    }

    pub(super) fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            + match self {
                Self::Output(bytes) => bytes.capacity(),
                Self::Resized { replay, kitty_image_aliases, .. } => {
                    replay.len()
                        + kitty_image_aliases.capacity() * size_of::<ghostty_vt::KittyImageAlias>()
                }
                Self::OutputWithColors { output, .. } => {
                    output.capacity() + size_of::<TerminalColors>()
                }
                Self::ResizedWithColors { replay, kitty_image_aliases, .. } => {
                    replay.len()
                        + kitty_image_aliases.capacity() * size_of::<ghostty_vt::KittyImageAlias>()
                        + size_of::<TerminalColors>()
                }
                Self::ColorsChanged(_) => size_of::<TerminalColors>(),
            }
    }
}

/// One item of a viewer queue.
#[derive(Debug)]
pub(super) enum QueuedFrame {
    Frame(AttachFrame),
    /// A local-history READY at a resize cut, after every frame queued before
    /// the resize (`terminal-snapshot-local-history-v1`).
    LocalReady(Arc<LocalReadySnapshot>),
}

impl QueuedFrame {
    fn retained_bytes(&self) -> usize {
        match self {
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
    /// The terminal a replay viewer's due replay is built from (empty for a
    /// snapshot viewer and a bare test tap).
    replay_source: Weak<PtyTerminalRuntime>,
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
    /// merges into is one item; a clear counts every queued item as taken.
    pushed: u64,
    popped: u64,
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
        self.state.upgrade().is_some_and(|state| state.queue.lock().unwrap().needs_snapshot)
    }

    /// Returns false when the viewer is gone.
    pub(crate) fn request(&self) -> bool {
        let Some(state) = self.state.upgrade() else { return false };
        let mut queue = state.queue.lock().unwrap();
        if !queue.receiver_alive || !queue.sender_alive {
            return false;
        }
        queue.fall_behind();
        drop(queue);
        state.ready.notify_all();
        true
    }
}

impl AttachFrameReceiver {
    pub(crate) fn snapshot_request_handle(&self) -> SnapshotRequestHandle {
        SnapshotRequestHandle { state: Arc::downgrade(&self.state) }
    }

    /// Next event of a snapshot viewer: a pending snapshot comes before any
    /// frame. Blocks until an event, `deadline`, or `interrupt`.
    pub(crate) fn recv_viewer_event(
        &self,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
        deadline: Option<Instant>,
    ) -> Result<ViewerEvent, RecvTimeoutError> {
        let mut queue = self.state.queue.lock().unwrap();
        loop {
            if queue.needs_snapshot {
                return Ok(ViewerEvent::Snapshot);
            }
            match Self::pop_item(&mut queue) {
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
                None => self.state.ready.wait(queue).unwrap(),
                Some(deadline) => {
                    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                        return Err(RecvTimeoutError::Timeout);
                    };
                    self.state.ready.wait_timeout(queue, remaining).unwrap().0
                }
            };
        }
    }

    /// Clear the pending snapshot and every queued frame. The caller holds
    /// the terminal lock while it encodes the snapshot and calls this, so
    /// the reader cannot queue a byte between the two.
    pub(crate) fn finish_snapshot_locked(&self) {
        let mut queue = self.state.queue.lock().unwrap();
        queue.frames.clear();
        queue.popped = queue.pushed;
        queue.retained_bytes = 0;
        queue.needs_snapshot = false;
        queue.snapshot_deferred = false;
    }

    /// The snapshot could not be encoded now: drop queued frames and retry
    /// at the next output instead of disconnecting the viewer.
    pub(crate) fn defer_snapshot(&self) {
        let mut queue = self.state.queue.lock().unwrap();
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
            replay_source,
        });
        (
            Self { state: state.clone(), lifecycle: lifecycle.clone() },
            AttachFrameReceiver { state, lifecycle },
        )
    }

    /// A snapshot viewer resyncs by snapshot; a replay viewer needs a replay.
    pub(super) fn is_snapshot(&self) -> bool {
        self.state.queue.lock().unwrap().snapshot_mode
    }

    /// Ask a snapshot viewer for a resync (a grid change without a replay).
    /// No-op for a replay viewer.
    pub(super) fn resync_snapshot(&self) {
        let mut queue = self.state.queue.lock().unwrap();
        if queue.snapshot_mode && queue.receiver_alive {
            queue.fall_behind();
            drop(queue);
            self.state.ready.notify_one();
        }
    }

    /// Whether this viewer would take a local-history READY of a resize now.
    pub(super) fn wants_local_ready(&self) -> bool {
        !self.lifecycle.is_canceled()
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
        {
            self.push(queue, QueuedFrame::LocalReady(local.clone()));
            return;
        }
        drop(queue);
        self.resync_snapshot();
    }

    /// A geometry change: a replay viewer waits for one replay at a later cut
    /// (see `needs_replay`). No-op for a snapshot viewer. False when the
    /// viewer is gone.
    pub(super) fn request_replay(&self) -> bool {
        if self.lifecycle.is_canceled() {
            return false;
        }
        let mut queue = self.state.queue.lock().unwrap();
        if !queue.receiver_alive {
            drop(queue); // cancel fires interrupt wakers that lock this queue.
            self.lifecycle.cancel();
            return false;
        }
        if queue.snapshot_mode || queue.needs_replay {
            return true;
        }
        queue.needs_replay = true;
        queue.replay_after = queue.pushed;
        drop(queue);
        self.state.ready.notify_one();
        true
    }

    /// Whether this replay viewer waits for a replay.
    pub(super) fn needs_replay(&self) -> bool {
        self.state.queue.lock().unwrap().needs_replay
    }

    /// Queue `frame`, the replay of the terminal at the caller's cut (the
    /// caller holds the terminal lock), for a viewer that waits for one.
    /// False when the viewer overflowed or is gone.
    pub(super) fn finish_replay(&self, frame: AttachFrame) -> bool {
        let mut queue = self.state.queue.lock().unwrap();
        if !queue.needs_replay {
            return true;
        }
        queue.needs_replay = false;
        if !queue.receiver_alive {
            drop(queue);
            self.lifecycle.cancel();
            return false;
        }
        let item = QueuedFrame::Frame(frame);
        // The replay is the terminal at the caller's cut, and every queued
        // frame is output from before it: when the replay does not fit
        // behind them they are dropped, as the replay replaces them, so a
        // replay within VT_REPLAY_MAX_BYTES always fits (an empty queue's
        // room) instead of overflowing a mirror that keeps up.
        if item.retained_bytes() > queue.max_retained_bytes.saturating_sub(queue.retained_bytes)
            || queue.frames.len() >= queue.max_frames
        {
            queue.frames.clear();
            queue.popped = queue.pushed;
            queue.retained_bytes = 0;
        }
        self.push(queue, item)
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
        self.state.ready.notify_one();
        true
    }

    /// Overflow: a legacy viewer disconnects, a snapshot viewer falls behind.
    fn overflow(&self, mut queue: std::sync::MutexGuard<'_, AttachTapQueue>) -> bool {
        if queue.snapshot_mode {
            queue.fall_behind();
            drop(queue);
            self.state.ready.notify_one();
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
        let mut queue = self.state.queue.lock().unwrap();
        if !queue.receiver_alive {
            drop(queue); // cancel fires interrupt wakers that lock this queue.
            self.lifecycle.cancel();
            return false;
        }
        if queue.snapshot_mode {
            if queue.snapshot_deferred {
                // Retry the snapshot now that the parser has moved on.
                queue.snapshot_deferred = false;
                queue.fall_behind();
                drop(queue);
                self.state.ready.notify_one();
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
                self.state.ready.notify_one();
                return true;
            }
        }
        let queue_retained_bytes = queue.retained_bytes;
        let queue_max_retained_bytes = queue.max_retained_bytes;
        if let Some(QueuedFrame::Frame(pending)) = queue.frames.back_mut() {
            let previous_bytes = pending.retained_bytes();
            let max_frame_bytes = queue_max_retained_bytes
                .saturating_sub(queue_retained_bytes.saturating_sub(previous_bytes));
            match pending.merge_adjacent_output(frame, max_frame_bytes) {
                AttachFrameMerge::Merged => {
                    let merged_bytes = pending.retained_bytes();
                    queue.retained_bytes = queue
                        .retained_bytes
                        .saturating_sub(previous_bytes)
                        .saturating_add(merged_bytes);
                    drop(queue);
                    self.state.ready.notify_one();
                    return true;
                }
                AttachFrameMerge::Unmerged(unmerged) => frame = unmerged,
                AttachFrameMerge::Overflow => return self.overflow(queue),
            }
        }
        self.push(queue, QueuedFrame::Frame(frame))
    }
}

impl Drop for AttachTap {
    fn drop(&mut self) {
        self.state.queue.lock().unwrap().sender_alive = false;
        self.state.ready.notify_all();
    }
}
