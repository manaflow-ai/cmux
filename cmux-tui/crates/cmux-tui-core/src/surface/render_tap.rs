//! Render attach plumbing: render frames, per-attachment render taps with
//! bounded queues, the render hub, and the initial graphics snapshot.

use super::*;

/// One immutable terminal frame plus retained-history metadata captured with it.
#[derive(Debug, Clone)]
pub struct SurfaceRenderFrame {
    pub frame: RenderFrame,
    pub content_generation: u64,
    pub scrollback_rows: u32,
    pub history_epoch: u64,
    pub pointer_semantics: TerminalPointerSemanticSnapshot,
    pub palette_colors: [Rgb; 256],
    pub palette_overridden: [bool; 256],
}

/// Live events delivered to one protocol-v7 render attachment.
#[derive(Debug, Clone)]
pub enum RenderAttachFrame {
    Frame(Arc<SurfaceRenderFrame>),
    ScrollChanged { offset: u64, at_bottom: bool },
}

/// A tap's undrained events, coalesced in stream order: at most one
/// `scroll-changed` before the pending frame, the frame, and at most one
/// `scroll-changed` after it. A newer position replaces an older one in the
/// same slot and frames coalesce, so the queue stays bounded however far the
/// receiver lags, and a frame never overtakes the position of the scroll that
/// moved its rows (spec/render.md "Stream Ordering").
struct RenderTapQueue {
    leading_scroll: Option<(u64, bool)>,
    pending_frame: Option<PendingRenderFrame>,
    trailing_scroll: Option<(u64, bool)>,
    sender_alive: bool,
    receiver_alive: bool,
}

struct PendingRenderFrame {
    latest: Arc<SurfaceRenderFrame>,
    dirty: Dirty,
    dirty_rows: Vec<u16>,
}

impl PendingRenderFrame {
    fn new(latest: Arc<SurfaceRenderFrame>) -> Self {
        Self { dirty: latest.frame.dirty, dirty_rows: latest.frame.dirty_rows.clone(), latest }
    }

    /// Replace the immutable snapshot while retaining every row damaged since
    /// the tap last drained. Only damage metadata is copied on this hot path.
    fn coalesce(&mut self, latest: Arc<SurfaceRenderFrame>) {
        if self.dirty == Dirty::Full
            || latest.frame.dirty == Dirty::Full
            || self.latest.frame.size != latest.frame.size
        {
            self.dirty = Dirty::Full;
            self.dirty_rows = (0..latest.frame.size.1).collect();
        } else {
            self.dirty_rows.extend(latest.frame.dirty_rows.iter().copied());
            self.dirty_rows.sort_unstable();
            self.dirty_rows.dedup();
            self.dirty =
                if self.dirty_rows.is_empty() { latest.frame.dirty } else { Dirty::Partial };
        }
        self.latest = latest;
    }

    /// Materialize one coalesced frame when the receiver drains. A tap that
    /// keeps up returns the original shared frame without cloning row state.
    fn into_frame(self) -> Arc<SurfaceRenderFrame> {
        if self.dirty == self.latest.frame.dirty && self.dirty_rows == self.latest.frame.dirty_rows
        {
            return self.latest;
        }
        let mut combined = (*self.latest).clone();
        combined.frame.dirty = self.dirty;
        combined.frame.dirty_rows = self.dirty_rows;
        Arc::new(combined)
    }
}

impl RenderTapQueue {
    fn new() -> Self {
        Self {
            leading_scroll: None,
            pending_frame: None,
            trailing_scroll: None,
            sender_alive: true,
            receiver_alive: true,
        }
    }

    fn is_empty(&self) -> bool {
        self.leading_scroll.is_none()
            && self.pending_frame.is_none()
            && self.trailing_scroll.is_none()
    }

    fn clear(&mut self) {
        self.leading_scroll = None;
        self.pending_frame = None;
        self.trailing_scroll = None;
    }

    fn push(&mut self, event: RenderAttachFrame) {
        match event {
            RenderAttachFrame::Frame(frame) => {
                // The newer frame replaces the pending one, so a position
                // queued after the pending frame now belongs before it. That
                // position is newer than any leading one and replaces it.
                if let Some(scroll) = self.trailing_scroll.take() {
                    self.leading_scroll = Some(scroll);
                }
                match &mut self.pending_frame {
                    Some(pending) => pending.coalesce(frame),
                    None => self.pending_frame = Some(PendingRenderFrame::new(frame)),
                }
            }
            RenderAttachFrame::ScrollChanged { offset, at_bottom } => {
                let slot = if self.pending_frame.is_some() {
                    &mut self.trailing_scroll
                } else {
                    &mut self.leading_scroll
                };
                *slot = Some((offset, at_bottom));
            }
        }
    }

    /// Drains in push order: the position before the pending frame, the
    /// frame, then the position after it, so the receiver ends on the kind
    /// pushed last.
    fn pop(&mut self) -> Option<RenderAttachFrame> {
        if let Some((offset, at_bottom)) = self.leading_scroll.take() {
            return Some(RenderAttachFrame::ScrollChanged { offset, at_bottom });
        }
        if let Some(frame) = self.pending_frame.take() {
            // With no frame pending, the trailing position leads again.
            self.leading_scroll = self.trailing_scroll.take();
            return Some(RenderAttachFrame::Frame(frame.into_frame()));
        }
        let (offset, at_bottom) = self.trailing_scroll.take()?;
        Some(RenderAttachFrame::ScrollChanged { offset, at_bottom })
    }
}

struct RenderTapState {
    queue: Mutex<RenderTapQueue>,
    ready: Condvar,
    /// The viewer's drain task when it runs on a sequence instead of
    /// blocking on `ready` (attach streams).
    ready_hook: crate::stream_interrupt::ReadyHook,
}

pub(super) struct RenderTap {
    state: Arc<RenderTapState>,
}

impl RenderTap {
    pub(super) fn pair(render: &Arc<RankedMutex<RenderHub>>) -> (Self, RenderAttachFrameReceiver) {
        let state = Arc::new(RenderTapState {
            queue: Mutex::new(RenderTapQueue::new()),
            ready: Condvar::new(),
            ready_hook: Default::default(),
        });
        (
            Self { state: state.clone() },
            RenderAttachFrameReceiver { state, render: Arc::downgrade(render) },
        )
    }

    pub(super) fn send(&self, event: RenderAttachFrame) -> bool {
        let mut queue = self.state.queue.lock().recover_poison();
        if !queue.receiver_alive {
            return false;
        }
        queue.push(event);
        drop(queue);
        self.state.ready.notify_one();
        self.state.ready_hook.wake();
        true
    }
}

impl Drop for RenderTap {
    fn drop(&mut self) {
        self.state.queue.lock().recover_poison().sender_alive = false;
        self.state.ready.notify_all();
        self.state.ready_hook.wake();
    }
}

/// Bounded receiver for one render attachment.
pub struct RenderAttachFrameReceiver {
    state: Arc<RenderTapState>,
    render: Weak<RankedMutex<RenderHub>>,
}

impl RenderAttachFrameReceiver {
    /// Runs `hook` after each queued event and when the sender is gone, for
    /// a viewer whose drain polls `try_recv` on a sequence instead of
    /// blocking. False when a hook is set already.
    pub(crate) fn on_ready(&self, hook: impl Fn() + Send + Sync + 'static) -> bool {
        self.state.ready_hook.set(hook)
    }

    pub fn recv(&self) -> Result<RenderAttachFrame, RecvError> {
        let mut queue = self.state.queue.lock().recover_poison();
        loop {
            if let Some(event) = queue.pop() {
                return Ok(event);
            }
            if !queue.sender_alive {
                return Err(RecvError);
            }
            queue = self.state.ready.wait(queue).recover_poison();
        }
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Result<RenderAttachFrame, RecvTimeoutError> {
        let started = Instant::now();
        let mut queue = self.state.queue.lock().recover_poison();
        loop {
            if let Some(event) = queue.pop() {
                return Ok(event);
            }
            if !queue.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            let Some(remaining) = timeout.checked_sub(started.elapsed()) else {
                return Err(RecvTimeoutError::Timeout);
            };
            let (next, result) = self.state.ready.wait_timeout(queue, remaining).recover_poison();
            queue = next;
            if result.timed_out() && queue.is_empty() {
                return Err(RecvTimeoutError::Timeout);
            }
        }
    }

    /// Wakes a blocked `recv_until_interrupted` when `interrupt` fires.
    pub(crate) fn wake_on(&self, interrupt: &crate::stream_interrupt::StreamInterrupt) {
        let state = Arc::downgrade(&self.state);
        interrupt.on_fire(move || {
            if let Some(state) = state.upgrade() {
                let _queue = state.queue.lock().unwrap_or_else(|error| error.into_inner());
                state.ready.notify_all();
            }
        });
    }

    /// Blocks for an event. Returns `Timeout` once `interrupt` has fired
    /// and nothing is queued.
    pub(crate) fn recv_until_interrupted(
        &self,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
    ) -> Result<RenderAttachFrame, RecvTimeoutError> {
        let mut queue = self.state.queue.lock().recover_poison();
        loop {
            if let Some(event) = queue.pop() {
                return Ok(event);
            }
            if !queue.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            if interrupt.is_fired() {
                return Err(RecvTimeoutError::Timeout);
            }
            queue = self.state.ready.wait(queue).recover_poison();
        }
    }

    pub fn try_recv(&self) -> Result<RenderAttachFrame, TryRecvError> {
        let mut queue = self.state.queue.lock().recover_poison();
        if let Some(event) = queue.pop() {
            Ok(event)
        } else if queue.sender_alive {
            Err(TryRecvError::Empty)
        } else {
            Err(TryRecvError::Disconnected)
        }
    }
}

impl Drop for RenderAttachFrameReceiver {
    fn drop(&mut self) {
        // Frame fan-out holds the hub before this queue. Release the queue
        // before taking the hub so receiver teardown cannot invert that order.
        {
            let mut queue = self.state.queue.lock().recover_poison();
            queue.receiver_alive = false;
            queue.clear();
        }
        if let Some(render) = self.render.upgrade() {
            render.lock().recover_poison().taps.retain(|tap| !Arc::ptr_eq(&tap.state, &self.state));
        }
    }
}

/// Initial render snapshot and the ordered live stream registered with it.
pub struct RenderAttachStream {
    pub initial: Arc<SurfaceRenderFrame>,
    pub stream: RenderAttachFrameReceiver,
    pub(super) _permit: Option<crate::mux::RenderAttachmentPermit>,
}

pub(super) struct RenderHub {
    pub(super) state: Box<RenderState>,
    pub(super) built_generation: u64,
    pub(super) latest: Option<Arc<SurfaceRenderFrame>>,
    pub(super) initial_graphics: Option<InitialGraphicsSnapshot>,
    pub(super) final_initial: Option<Arc<SurfaceRenderFrame>>,
    pub(super) taps: Vec<RenderTap>,
}

impl RenderHub {
    pub(super) fn build_attach_initial(
        &mut self,
        term: &Terminal,
    ) -> ghostty_vt::Result<Arc<SurfaceRenderFrame>> {
        let shared = self.latest.clone().ok_or(ghostty_vt::Error::NoValue)?;
        let initial_graphics = match self.initial_graphics.as_ref() {
            Some(cached) if Arc::ptr_eq(&cached.source, &shared.frame.kitty_graphics) => {
                cached.snapshot.clone()
            }
            _ => {
                let snapshot = self.state.snapshot_kitty_graphics(term, true)?;
                self.initial_graphics = Some(InitialGraphicsSnapshot {
                    source: shared.frame.kitty_graphics.clone(),
                    snapshot: snapshot.clone(),
                });
                snapshot
            }
        };
        let mut initial = (*shared).clone();
        initial.frame.kitty_graphics = initial_graphics;
        Ok(Arc::new(initial))
    }

    pub(super) fn final_attach_initial(
        &mut self,
        term: &Terminal,
    ) -> ghostty_vt::Result<Arc<SurfaceRenderFrame>> {
        if let Some(initial) = self.final_initial.as_ref() {
            return Ok(initial.clone());
        }
        let initial = self.build_attach_initial(term)?;
        self.final_initial = Some(initial.clone());
        Ok(initial)
    }
}

pub(super) struct InitialGraphicsSnapshot {
    pub(super) source: Arc<ghostty_vt::KittyGraphicsSnapshot>,
    snapshot: Arc<ghostty_vt::KittyGraphicsSnapshot>,
}

#[cfg(test)]
pub(super) type FrameProducerTestHook = Arc<Mutex<Option<Arc<dyn Fn() + Send + Sync>>>>;
