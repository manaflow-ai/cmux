//! Attach streams on the daemon-wide sequenced pool (p05-ipc-079).
//!
//! A legacy attach holds a thread per view for its output and one for its
//! notifications, each blocked on its source. A client-minted attach stream
//! (attach-streams-v1) holds none: its view is an [`AttachPump`], a sequence
//! on the pool whose drain task takes what its sources hold and returns when
//! they are empty, when the outbound stream holds its backpressure cap, or
//! when its turn's budget is spent. Its sources wake it through their ready
//! hooks, the connection writer through the stream's space hook, and a close
//! of the connection, the stream or the attachment through its stop
//! interrupt. Chrome binds each Mojo receiver to a sequence and runs each
//! message as a task on it (mojo/public/cpp/bindings/lib/connector.cc,
//! `Connector::OnWatcherHandleReady`; docs/threading_and_tasks.md "Prefer
//! sequences to threads"): no receiver holds a thread.
//!
//! Lifetime: the pump keeps itself alive the way a thread does. Its stop
//! interrupt's waker holds it, and posted tasks hold it; sources hold it
//! weakly. When the drain is done the pump fires its stop interrupt, which
//! drops that waker.

use cmux_threads::sync::Mutex;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::TryRecvError;
use std::time::Duration;

use serde::Serialize;
use serde_json::json;

use super::{
    attach_notification_json, detach_committed_attach, handle_attach_send_error,
    report_attach_overflow,
};
use crate::Mux;
use crate::SurfaceId;
use crate::event_bus::MuxEventReceiver;
use crate::panic_free::RecoverPoison;
use crate::server::MessageWriter;
use crate::server::OutboundStream;
use crate::server::attach_streams::StreamEndReason;
use crate::server::sequenced_pool::{PostError, Sequence, SequencePriority, SequencedPool};
use crate::stream_interrupt::StreamInterrupt;
use crate::surface::AttachLifecycle;

/// Items one drain task sends before it yields its worker to the other
/// sequences of its priority.
const TURN_BUDGET: usize = 64;

/// What one turn of a drain did.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Turn {
    /// Nothing more to do until a source, the writer or a timer wakes it.
    Idle,
    /// Its budget is spent: it runs again behind the other sequences.
    Yield,
    /// The view ended: [`AttachDrain::finish`] runs next.
    Done,
}

/// A view's work, owned by its pump's sequence: only one task of the
/// sequence runs it at a time.
pub(crate) trait AttachDrain: Send + 'static {
    /// Handles what is ready, without waiting.
    fn turn(&mut self, timer: &PumpTimer<'_>) -> Turn;
    /// After [`Turn::Done`]: reports, detaches and ends the stream.
    fn finish(self: Box<Self>);
    /// The attach was never committed: undoes what the drain registered.
    fn abandon(self: Box<Self>) {}
}

struct PumpInner {
    sequence: Sequence,
    /// A drain task is posted and has not started yet; true from the
    /// pump's creation until [`AttachPump::start`], so nothing runs before
    /// the attach is committed.
    scheduled: AtomicBool,
    stop: Arc<StreamInterrupt>,
    /// Only the sequence's running task takes it, so it is never contended
    /// (Chrome's `SequenceBound`).
    drain: Mutex<Option<Box<dyn AttachDrain>>>,
}

/// One attach stream's drain on the pool. Dropped unstarted, it abandons
/// its drain.
pub(crate) struct AttachPump {
    inner: Arc<PumpInner>,
    started: bool,
}

impl AttachPump {
    pub(crate) fn new(pool: &SequencedPool, priority: SequencePriority) -> Self {
        let inner = Arc::new(PumpInner {
            sequence: pool.sequence(priority),
            scheduled: AtomicBool::new(true),
            stop: StreamInterrupt::new(),
            drain: Mutex::new(None),
        });
        let keep = inner.clone();
        inner.stop.on_fire(move || wake(&keep));
        Self { inner, started: false }
    }

    /// The hook a source runs when it has something for the drain. It holds
    /// the pump weakly: a source never keeps an ended view alive.
    pub(crate) fn hook(&self) -> impl Fn() + Send + Sync + 'static {
        let pump = Arc::downgrade(&self.inner);
        move || {
            if let Some(inner) = pump.upgrade() {
                wake(&inner);
            }
        }
    }

    /// Fired by any close the view ends on; it wakes the drain.
    pub(crate) fn stop(&self) -> &Arc<StreamInterrupt> {
        &self.inner.stop
    }

    pub(crate) fn install(&self, drain: Box<dyn AttachDrain>) {
        *self.inner.drain.lock().recover_poison() = Some(drain);
    }

    /// Runs the drain's first turn: what queued since the attach was built.
    pub(crate) fn start(mut self) -> Result<(), PostError> {
        self.started = true;
        self.inner.scheduled.store(false, Ordering::SeqCst);
        post(&self.inner)
    }
}

impl Drop for AttachPump {
    fn drop(&mut self) {
        if self.started {
            return;
        }
        let drain = self.inner.drain.lock().recover_poison().take();
        if let Some(drain) = drain {
            drain.abandon();
        }
        self.inner.stop.fire();
    }
}

/// Schedules the drain's next turn on the pump's sequence.
pub(crate) struct PumpTimer<'a>(&'a Arc<PumpInner>);

impl PumpTimer<'_> {
    /// A turn after `delay`; an earlier wake runs one sooner as well.
    pub(crate) fn wake_after(&self, delay: Duration) {
        let inner = self.0.clone();
        // A shut-down pool runs nothing again; the view ends with it.
        let _ = self.0.sequence.post_delayed(delay, move || run(&inner));
    }
}

fn wake(inner: &Arc<PumpInner>) {
    if inner.scheduled.swap(true, Ordering::SeqCst) {
        return;
    }
    if post(inner).is_err() {
        inner.scheduled.store(false, Ordering::SeqCst);
    }
}

fn post(inner: &Arc<PumpInner>) -> Result<(), PostError> {
    let task = inner.clone();
    inner.sequence.post(move || run(&task))
}

fn run(inner: &Arc<PumpInner>) {
    // Cleared before the sources are read: a wake from here on posts the
    // next turn, so none is lost.
    inner.scheduled.store(false, Ordering::SeqCst);
    let mut slot = inner.drain.lock().recover_poison();
    let Some(drain) = slot.as_mut() else { return };
    match drain.turn(&PumpTimer(inner)) {
        Turn::Idle => {}
        Turn::Yield => {
            drop(slot);
            wake(inner);
        }
        Turn::Done => {
            let drain = slot.take();
            drop(slot);
            if let Some(drain) = drain {
                drain.finish();
            }
            inner.stop.fire();
        }
    }
}

/// What the next item of a view's source did.
pub(crate) enum Step {
    /// An item was sent (or skipped): look again.
    Sent,
    /// The source holds nothing now.
    Empty,
    /// The view ends.
    End,
}

/// A view's own source: terminal bytes, snapshots, render frames or browser
/// frames.
pub(crate) trait ViewSource: Send + Sized + 'static {
    /// Sends the source's next item on `out`, which has room for it.
    fn next(&mut self, out: &mut ViewOut, timer: &PumpTimer<'_>) -> Step;
    /// Before the view's end is reported and its attachment detached.
    fn end(self, _out: &ViewOut) {}
    /// The attach was never committed.
    fn abandon(self, _out: &ViewOut) {}
}

/// What every attach stream's drain holds: where its items go, what ends
/// it, and the surface's notifications (the legacy
/// `mux-attach-notifications` thread's work).
pub(crate) struct ViewOut {
    pub(crate) mux: Arc<Mux>,
    pub(crate) client: u64,
    pub(crate) surface: SurfaceId,
    pub(crate) writer: MessageWriter,
    pub(crate) stream: OutboundStream,
    pub(crate) lifecycle: AttachLifecycle,
    notifications: Option<MuxEventReceiver>,
}

impl ViewOut {
    /// The output of the view `stream` of `surface`, woken by `pump`: its
    /// stop interrupt fires on a close of the writer, the stream or the
    /// attachment, and the writer wakes it when the stream has room again.
    /// `notifications` subscribes it to the surface's notifications.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn bind(
        pump: &AttachPump,
        mux: &Arc<Mux>,
        client: u64,
        surface: SurfaceId,
        writer: &MessageWriter,
        stream: &OutboundStream,
        lifecycle: &AttachLifecycle,
        notifications: bool,
    ) -> Self {
        writer.register_interrupt(pump.stop());
        stream.register_interrupt(pump.stop());
        lifecycle.register_interrupt(pump.stop());
        stream.on_space(pump.hook());
        let notifications = notifications.then(|| {
            let events = mux.subscribe_attached_surface(surface);
            events.on_ready(pump.hook());
            events
        });
        Self {
            mux: mux.clone(),
            client,
            surface,
            writer: writer.clone(),
            stream: stream.clone(),
            lifecycle: lifecycle.clone(),
            notifications,
        }
    }

    pub(crate) fn is_live(&self) -> bool {
        self.writer.is_open() && self.stream.is_open() && !self.lifecycle.is_canceled()
    }

    /// Queues `value` on the view's stream. False ends the view (an
    /// overflow marks it).
    pub(crate) fn send<T: Serialize + ?Sized>(&self, value: &T) -> bool {
        self.sent(self.writer.send_stream(value, &self.stream))
    }

    /// False after a failed send, which it records on the lifecycle.
    pub(crate) fn sent(&self, result: std::io::Result<()>) -> bool {
        match result {
            Ok(()) => true,
            Err(error) => {
                handle_attach_send_error(&self.lifecycle, &error);
                false
            }
        }
    }

    /// The source ended: the view says so before its stream ends.
    pub(crate) fn send_detached(&self) {
        if self.writer.is_open() {
            let _ = self
                .writer
                .send_stream(&json!({"event": "detached", "surface": self.surface}), &self.stream);
        }
    }

    /// One ready notification sent: `Some(true)`; a failed send:
    /// `Some(false)`; nothing ready: `None`.
    fn send_notification(&mut self) -> Option<bool> {
        loop {
            let events = self.notifications.as_ref()?;
            match events.try_recv() {
                Ok(event) => {
                    if let Some(value) = attach_notification_json(self.surface, event) {
                        return Some(self.send(&value));
                    }
                }
                Err(TryRecvError::Empty) => return None,
                Err(TryRecvError::Disconnected) => {
                    if events.overflowed() {
                        self.lifecycle.mark_overflow();
                    }
                    self.notifications = None;
                    return None;
                }
            }
        }
    }

    fn finish(&self) {
        report_attach_overflow(&self.writer, self.surface, &self.lifecycle, &self.stream);
        detach_committed_attach(&self.mux, self.client, self.surface, self.stream.id);
        self.writer.end_client_stream(&self.stream, StreamEndReason::Detached);
    }
}

/// A view's drain: its notifications and its source, at most one item past
/// the stream's backpressure cap.
pub(crate) struct ViewDrain<S> {
    pub(crate) out: ViewOut,
    pub(crate) source: S,
}

impl<S: ViewSource> AttachDrain for ViewDrain<S> {
    fn turn(&mut self, timer: &PumpTimer<'_>) -> Turn {
        for _ in 0..TURN_BUDGET {
            if !self.out.is_live() {
                return Turn::Done;
            }
            if !self.out.writer.sink.stream_has_room(&self.out.stream) {
                return Turn::Idle;
            }
            match self.out.send_notification() {
                Some(true) => continue,
                Some(false) => return Turn::Done,
                None => {}
            }
            match self.source.next(&mut self.out, timer) {
                Step::Sent => {}
                Step::Empty => return Turn::Idle,
                Step::End => return Turn::Done,
            }
        }
        Turn::Yield
    }

    fn finish(self: Box<Self>) {
        let Self { out, source } = *self;
        source.end(&out);
        out.finish();
    }

    fn abandon(self: Box<Self>) {
        let Self { out, source } = *self;
        source.abandon(&out);
    }
}

#[cfg(test)]
#[path = "attach_pump_tests.rs"]
mod tests;
