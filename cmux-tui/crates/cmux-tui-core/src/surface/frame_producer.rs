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

use std::cmp::Reverse;
use std::collections::{BinaryHeap, VecDeque};
use std::sync::{Condvar, OnceLock};

use super::*;
use crate::panic_free::RecoverPoison;

const RENDER_FRAME_CADENCE: Duration = Duration::from_millis(8);

/// One terminal's place on the producer. Requests touch only its atomics;
/// the first request after a frame puts it on the producer's ready queue
/// (H3: no global lock per output chunk, no scan of every terminal).
#[derive(Default)]
struct Slot {
    /// The highest generation asked for since the last frame; 0: none.
    requested: AtomicU64,
    /// On the ready queue or the deadline heap, or being built: a request
    /// then only raises `requested`.
    queued: AtomicBool,
    /// A request since the last frame asked the producer to announce the
    /// output after the frame (its caller could not: it may hold
    /// `Mux::state`).
    announce: AtomicBool,
    /// Nanoseconds since [`epoch`] of this terminal's last frame; 0: never.
    last_frame: AtomicU64,
    surface: Mutex<Weak<Surface>>,
}

/// A terminal's handle on the shared producer: requests a frame; the
/// terminal leaves the producer when this is dropped (the producer holds
/// only a weak reference to its slot).
pub(crate) struct FrameRequests {
    slot: Arc<Slot>,
}

impl FrameRequests {
    /// Register a terminal; its surface is bound by [`spawn_frame_producer`].
    pub(super) fn new() -> Self {
        // The producer thread starts with the first terminal.
        let _ = scheduler();
        Self { slot: Arc::default() }
    }

    /// Ask for a frame of at least `generation`; `announce`: the producer
    /// publishes the output event after the frame. Lock-free unless this is
    /// the first request since the terminal's last frame.
    pub(super) fn request(&self, generation: u64, announce: bool) {
        if announce {
            self.slot.announce.store(true, Ordering::Release);
        }
        self.slot.requested.fetch_max(generation.max(1), Ordering::AcqRel);
        if self.slot.queued.swap(true, Ordering::AcqRel) {
            return;
        }
        let scheduler = scheduler();
        scheduler.state.lock().recover_poison().ready.push_back(Arc::downgrade(&self.slot));
        scheduler.changed.notify_one();
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
        let spawned = crate::echo_thread::spawn("surface-frames", run);
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
            // queues the terminal again, so none is lost.
            slot.queued.store(false, Ordering::Release);
            let announce = slot.announce.swap(false, Ordering::AcqRel);
            let requested = slot.requested.swap(0, Ordering::AcqRel);
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

/// Build one terminal's frame; true when a frame (or a colors flush) went out.
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
    built.unwrap_or(false) || colors_pending
}

#[cfg(test)]
#[path = "frame_producer_tests.rs"]
mod tests;
