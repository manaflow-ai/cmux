//! Render frame producer: one daemon thread that turns every terminal's
//! render requests into frames, at most one per terminal per cadence.
//!
//! Every terminal used to run its own `surface-N-frames` thread, woken on
//! each output chunk: one OS thread per terminal (172 at the heavy session),
//! asleep but costing a stack, a kernel thread and a wake per chunk. One
//! shared thread now keeps the pending request of each terminal and its last
//! frame time, and builds the due frames in turn (PL-daemon, the daemon's
//! threads per terminal). The thread sleeps on a condition variable while no
//! request is pending (no timer at idle).
//!
//! Output's scroll position changes publish here too, once per frame
//! ([`FrameRequests::defer_scroll`]), not once per output chunk (perf100).

use std::cmp::Reverse;
use std::collections::{BinaryHeap, VecDeque};
use std::sync::{Condvar, OnceLock};

use super::*;
use crate::panic_free::RecoverPoison;

const RENDER_FRAME_CADENCE: Duration = Duration::from_millis(8);

/// The bit of `Slot::requested` that asks for the output event.
const ANNOUNCE: u64 = 1 << 63;

/// One terminal's place on the producer. Requests touch only its atomics;
/// the first request after a frame puts it on the producer's ready queue
/// (H3: no global lock per output chunk, no scan of every terminal).
#[derive(Default)]
struct Slot {
    /// The highest generation asked for since the last frame (0: none), and
    /// [`ANNOUNCE`]: a request since then asked the producer to announce the
    /// output after the frame (its caller could not: it may hold
    /// `Mux::state`). One word, so the producer takes both at once.
    requested: AtomicU64,
    /// On the ready queue or the deadline heap, or being built: a request
    /// then only raises `requested`.
    queued: AtomicBool,
    /// Nanoseconds since [`epoch`] of this terminal's last frame; 0: never.
    last_frame: AtomicU64,
    surface: Mutex<Weak<Surface>>,
}

/// A terminal's handle on the shared producer: requests a frame; the
/// terminal leaves the producer when this is dropped (the producer holds
/// only a weak reference to its slot).
///
/// It also holds the terminal's scroll position change that output caused
/// and no `scroll-changed` event has published yet. Output moves the scroll
/// offset on almost every chunk (93k events/s while one terminal floods,
/// perf100 tui lane), so output only records the newest position here and
/// the producer publishes it once per frame. Every other scroll change (a
/// viewport scroll, a resize, a clear, a replay) publishes at once and drops
/// a recorded one, under the same lock, so an older position can never be
/// published after a newer one.
pub(crate) struct FrameRequests {
    slot: Arc<Slot>,
    scroll: Mutex<Option<(u64, bool)>>,
}

impl FrameRequests {
    /// Register a terminal; its surface is bound by [`spawn_frame_producer`].
    pub(super) fn new() -> Self {
        // The producer thread starts with the first terminal.
        let _ = scheduler();
        Self { slot: Arc::default(), scroll: Mutex::new(None) }
    }

    /// Ask for a frame of at least `generation`; `announce`: the producer
    /// publishes the output event after the frame. Lock-free unless this is
    /// the first request since the terminal's last frame.
    pub(super) fn request(&self, generation: u64, announce: bool) {
        let generation = generation.clamp(1, ANNOUNCE - 1);
        let flag = if announce { ANNOUNCE } else { 0 };
        // SeqCst with the producer's clear of `queued` and take of
        // `requested`: either the producer takes this generation, or this
        // request sees `queued` cleared and queues the slot again.
        let _ = self.slot.requested.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |old| {
            Some(((old & !ANNOUNCE).max(generation)) | (old & ANNOUNCE) | flag)
        });
        if self.slot.queued.swap(true, Ordering::SeqCst) {
            return;
        }
        let scheduler = scheduler();
        scheduler.state.lock().recover_poison().ready.push_back(Arc::downgrade(&self.slot));
        scheduler.changed.notify_one();
    }
}

impl FrameRequests {
    /// Output moved the scroll position: publish it with the next frame.
    pub(super) fn defer_scroll(&self, offset: u64, at_bottom: bool) {
        *self.scroll.lock().recover_poison() = Some((offset, at_bottom));
    }

    /// Publish a recorded output scroll change, if any; whether one was.
    pub(super) fn flush_scroll(&self, mux: &Mux, surface: SurfaceId) -> bool {
        let mut pending = self.scroll.lock().recover_poison();
        let Some((offset, at_bottom)) = pending.take() else { return false };
        mux.emit_terminal_scroll(surface, offset, at_bottom);
        true
    }

    /// A scroll change that is not output's: publish it now, replacing a
    /// recorded one.
    pub(super) fn publish_scroll_now(
        &self,
        mux: &Mux,
        surface: SurfaceId,
        offset: u64,
        at_bottom: bool,
    ) {
        let mut pending = self.scroll.lock().recover_poison();
        *pending = None;
        mux.emit_terminal_scroll(surface, offset, at_bottom);
    }
}

#[derive(Default)]
struct State {
    /// Terminals asked for a frame since the producer last looked.
    ready: VecDeque<Weak<Slot>>,
}

struct Scheduler {
    state: Mutex<State>,
    changed: Condvar,
}

/// The producer's time base for `Slot::last_frame`.
fn epoch() -> Instant {
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    *EPOCH.get_or_init(Instant::now)
}

fn nanos_since_epoch(at: Instant) -> u64 {
    u64::try_from(at.saturating_duration_since(epoch()).as_nanos()).unwrap_or(u64::MAX).max(1)
}

fn scheduler() -> &'static Scheduler {
    static SCHEDULER: OnceLock<Scheduler> = OnceLock::new();
    SCHEDULER.get_or_init(|| {
        let _ = epoch();
        let spawned = std::thread::Builder::new().name("surface-frames".into()).spawn(run);
        if let Err(error) = spawned {
            eprintln!("cmux-tui: the frame producer did not start: {error}");
        }
        Scheduler { state: Mutex::default(), changed: Condvar::new() }
    })
}

/// Bind `surface` to its [`FrameRequests`] slot.
pub(super) fn spawn_frame_producer(surface: &Arc<Surface>) -> anyhow::Result<()> {
    let pty =
        surface.as_pty().ok_or_else(|| anyhow::anyhow!("frame producer got non-pty surface"))?;
    *pty.frame_requests.slot.surface.lock().recover_poison() = Arc::downgrade(surface);
    Ok(())
}

/// A slot waiting for its cadence, ordered by its deadline.
struct Deadline(Instant, u64, Weak<Slot>);

impl PartialEq for Deadline {
    fn eq(&self, other: &Self) -> bool {
        (self.0, self.1) == (other.0, other.1)
    }
}
impl Eq for Deadline {}
impl PartialOrd for Deadline {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Deadline {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        (self.0, self.1).cmp(&(other.0, other.1))
    }
}

/// The producer: takes newly asked terminals off the ready queue, builds
/// the ones whose cadence passed and keeps the others on a deadline heap.
/// Work per wake is O(terminals asked), never O(terminals); idle, it waits
/// with no timer.
fn run() {
    let scheduler = scheduler();
    let mut waiting: BinaryHeap<Reverse<Deadline>> = BinaryHeap::new();
    let mut taken: Vec<Weak<Slot>> = Vec::new();
    let mut order: u64 = 0;
    loop {
        {
            let mut state = scheduler.state.lock().recover_poison();
            while state.ready.is_empty() {
                let now = Instant::now();
                let Some(Reverse(Deadline(at, ..))) = waiting.peek() else {
                    state = scheduler.changed.wait(state).recover_poison();
                    continue;
                };
                if *at <= now {
                    break;
                }
                // wakeup-allow: deadline the cadence of a pending frame request (one-shot)
                state = scheduler.changed.wait_timeout(state, *at - now).recover_poison().0;
            }
            taken.extend(state.ready.drain(..));
        }
        let now = Instant::now();
        for slot in taken.drain(..) {
            let Some(strong) = slot.upgrade() else { continue };
            let last = strong.last_frame.load(Ordering::Acquire);
            let due = if last == 0 {
                now
            } else {
                epoch() + Duration::from_nanos(last) + RENDER_FRAME_CADENCE
            };
            order += 1;
            waiting.push(Reverse(Deadline(due, order, slot)));
        }
        while let Some(Reverse(Deadline(at, ..))) = waiting.peek() {
            if *at > Instant::now() {
                break;
            }
            let Some(Reverse(Deadline(_, _, slot))) = waiting.pop() else { break };
            let Some(slot) = slot.upgrade() else { continue };
            // Cleared before the generation is taken: a request after this
            // queues the terminal again, so none is lost. The generation and
            // the announce bit come in one swap: no request between them.
            slot.queued.store(false, Ordering::SeqCst);
            #[cfg(test)]
            run_after_clear_hook(&slot);
            let taken = slot.requested.swap(0, Ordering::SeqCst);
            let (requested, announce) = (taken & !ANNOUNCE, taken & ANNOUNCE != 0);
            if requested == 0 {
                continue;
            }
            let surface = slot.surface.lock().recover_poison().clone();
            if produce(&surface, requested, announce) {
                slot.last_frame.store(nanos_since_epoch(Instant::now()), Ordering::Release);
            }
        }
    }
}

/// Tests: runs right after the producer cleared a slot's `queued`, before
/// it takes the generation (the window a request can land in).
#[cfg(test)]
type AfterClearHook = Arc<dyn Fn(usize) + Send + Sync>;

#[cfg(test)]
static AFTER_CLEAR_HOOK: Mutex<Option<AfterClearHook>> = Mutex::new(None);

#[cfg(test)]
fn run_after_clear_hook(slot: &Arc<Slot>) {
    let hook = AFTER_CLEAR_HOOK.lock().recover_poison().clone();
    if let Some(hook) = hook {
        hook(Arc::as_ptr(slot) as usize);
    }
}

#[cfg(test)]
impl FrameRequests {
    /// The slot's identity, as [`AFTER_CLEAR_HOOK`] sees it.
    pub(super) fn slot_id_for_test(&self) -> usize {
        Arc::as_ptr(&self.slot) as usize
    }
}

/// Build one terminal's frame and publish output's scroll position; true
/// when a frame, a colors flush or a scroll position went out.
fn produce(surface: &Weak<Surface>, requested: u64, announce: bool) -> bool {
    let Some(surface) = surface.upgrade() else { return false };
    let Some(pty) = surface.as_pty() else { return false };
    #[cfg(test)]
    if let Some(hook) = pty.frame_producer_before_upgrade.lock().recover_poison().clone() {
        hook();
    }
    // A poisoned terminal lock skips this frame; the next output requests one.
    let Ok(term) = pty.term.lock() else { return false };
    let generation = requested.max(pty.render_generation.load(Ordering::Acquire));
    let colors_pending = pty.attach_colors_pending.load(Ordering::Acquire);
    if colors_pending {
        let defaults = pty.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let _ = pty.flush_attach_colors_locked(&term, defaults);
    }
    // A reader announced its output when it asked (H3); other requests are
    // announced here, after the frame, with the terminal lock released.
    let built = if announce {
        pty.build_producer_frame(term, generation)
    } else {
        let mut term = term;
        pty.build_frame_locked(&mut term, generation, true)
    };
    let built = built.unwrap_or(false);
    // A published scroll position paces the terminal like a frame does: with
    // no render viewer no frame is built, and output would otherwise publish
    // a position per chunk.
    let scrolled = pty
        .mux
        .upgrade()
        .is_some_and(|mux| pty.frame_requests.flush_scroll(&mux, pty.event_surface_id));
    built || colors_pending || scrolled
}

#[cfg(test)]
#[path = "frame_producer_tests.rs"]
mod tests;
