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

#[derive(Clone, Copy, PartialEq, Eq)]
enum PendingRenderKind {
    Frame,
    Scroll,
}

struct RenderTapQueue {
    pending_frame: Option<PendingRenderFrame>,
    pending_scroll: Option<(u64, bool)>,
    latest_kind: Option<PendingRenderKind>,
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
    fn push(&mut self, event: RenderAttachFrame) {
        match event {
            RenderAttachFrame::Frame(frame) => {
                match &mut self.pending_frame {
                    Some(pending) => pending.coalesce(frame),
                    None => self.pending_frame = Some(PendingRenderFrame::new(frame)),
                }
                self.latest_kind = Some(PendingRenderKind::Frame);
            }
            RenderAttachFrame::ScrollChanged { offset, at_bottom } => {
                self.pending_scroll = Some((offset, at_bottom));
                self.latest_kind = Some(PendingRenderKind::Scroll);
            }
        }
    }

    fn pop(&mut self) -> Option<RenderAttachFrame> {
        let next =
            match (self.pending_frame.is_some(), self.pending_scroll.is_some(), self.latest_kind) {
                (true, true, Some(PendingRenderKind::Frame)) => {
                    let (offset, at_bottom) = self.pending_scroll.take().unwrap();
                    RenderAttachFrame::ScrollChanged { offset, at_bottom }
                }
                (true, true, Some(PendingRenderKind::Scroll)) => {
                    RenderAttachFrame::Frame(self.pending_frame.take().unwrap().into_frame())
                }
                (true, true, None) => unreachable!("pending render events have an ordering"),
                (true, false, _) => {
                    RenderAttachFrame::Frame(self.pending_frame.take().unwrap().into_frame())
                }
                (false, true, _) => {
                    let (offset, at_bottom) = self.pending_scroll.take().unwrap();
                    RenderAttachFrame::ScrollChanged { offset, at_bottom }
                }
                (false, false, _) => return None,
            };
        if self.pending_frame.is_none() && self.pending_scroll.is_none() {
            self.latest_kind = None;
        }
        Some(next)
    }
}

struct RenderTapState {
    queue: Mutex<RenderTapQueue>,
    ready: Condvar,
}

pub(super) struct RenderTap {
    state: Arc<RenderTapState>,
}

impl RenderTap {
    pub(super) fn pair(render: &Arc<Mutex<RenderHub>>) -> (Self, RenderAttachFrameReceiver) {
        let state = Arc::new(RenderTapState {
            queue: Mutex::new(RenderTapQueue {
                pending_frame: None,
                pending_scroll: None,
                latest_kind: None,
                sender_alive: true,
                receiver_alive: true,
            }),
            ready: Condvar::new(),
        });
        (
            Self { state: state.clone() },
            RenderAttachFrameReceiver { state, render: Arc::downgrade(render) },
        )
    }

    pub(super) fn send(&self, event: RenderAttachFrame) -> bool {
        let mut queue = self.state.queue.lock().unwrap();
        if !queue.receiver_alive {
            return false;
        }
        queue.push(event);
        drop(queue);
        self.state.ready.notify_one();
        true
    }
}

impl Drop for RenderTap {
    fn drop(&mut self) {
        self.state.queue.lock().unwrap().sender_alive = false;
        self.state.ready.notify_all();
    }
}

/// Bounded receiver for one render attachment.
pub struct RenderAttachFrameReceiver {
    state: Arc<RenderTapState>,
    render: Weak<Mutex<RenderHub>>,
}

impl RenderAttachFrameReceiver {
    pub fn recv(&self) -> Result<RenderAttachFrame, RecvError> {
        let mut queue = self.state.queue.lock().unwrap();
        loop {
            if let Some(event) = queue.pop() {
                return Ok(event);
            }
            if !queue.sender_alive {
                return Err(RecvError);
            }
            queue = self.state.ready.wait(queue).unwrap();
        }
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Result<RenderAttachFrame, RecvTimeoutError> {
        let started = Instant::now();
        let mut queue = self.state.queue.lock().unwrap();
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
            let (next, result) = self.state.ready.wait_timeout(queue, remaining).unwrap();
            queue = next;
            if result.timed_out() && queue.pending_frame.is_none() && queue.pending_scroll.is_none()
            {
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
        let mut queue = self.state.queue.lock().unwrap();
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
            queue = self.state.ready.wait(queue).unwrap();
        }
    }

    pub fn try_recv(&self) -> Result<RenderAttachFrame, TryRecvError> {
        let mut queue = self.state.queue.lock().unwrap();
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
            let mut queue = self.state.queue.lock().unwrap();
            queue.receiver_alive = false;
            queue.pending_frame = None;
            queue.pending_scroll = None;
        }
        if let Some(render) = self.render.upgrade() {
            render.lock().unwrap().taps.retain(|tap| !Arc::ptr_eq(&tap.state, &self.state));
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
