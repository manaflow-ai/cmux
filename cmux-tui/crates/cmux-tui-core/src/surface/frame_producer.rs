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

use std::collections::HashMap;
use std::sync::{Condvar, OnceLock};

use super::*;
use crate::panic_free::RecoverPoison;

const RENDER_FRAME_CADENCE: Duration = Duration::from_millis(8);

/// A terminal's handle on the shared producer: requests a frame, and
/// removes the terminal when dropped.
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
    key: u64,
    scroll: Mutex<Option<(u64, bool)>>,
}

impl FrameRequests {
    /// Register a terminal; its surface is bound by [`spawn_frame_producer`].
    pub(super) fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let key = NEXT.fetch_add(1, Ordering::Relaxed);
        scheduler().state.lock().recover_poison().entries.insert(key, Entry::default());
        Self { key, scroll: Mutex::new(None) }
    }

    /// Ask for a frame of at least `generation`.
    pub(super) fn request(&self, generation: u64) {
        let scheduler = scheduler();
        let mut state = scheduler.state.lock().recover_poison();
        if let Some(entry) = state.entries.get_mut(&self.key) {
            entry.requested = Some(entry.requested.map_or(generation, |old| old.max(generation)));
            drop(state);
            scheduler.changed.notify_one();
        }
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

impl Drop for FrameRequests {
    fn drop(&mut self) {
        scheduler().state.lock().recover_poison().entries.remove(&self.key);
    }
}

#[derive(Default)]
struct Entry {
    surface: Weak<Surface>,
    requested: Option<u64>,
    /// When this terminal's last frame was built.
    last_frame: Option<Instant>,
}

#[derive(Default)]
struct State {
    entries: HashMap<u64, Entry>,
}

struct Scheduler {
    state: Mutex<State>,
    changed: Condvar,
}

fn scheduler() -> &'static Scheduler {
    static SCHEDULER: OnceLock<Scheduler> = OnceLock::new();
    SCHEDULER.get_or_init(|| {
        let spawned = std::thread::Builder::new().name("surface-frames".into()).spawn(run);
        if let Err(error) = spawned {
            eprintln!("cmux-tui: the frame producer did not start: {error}");
        }
        Scheduler { state: Mutex::default(), changed: Condvar::new() }
    })
}

/// Bind `surface` to its [`FrameRequests`] entry.
pub(super) fn spawn_frame_producer(surface: &Arc<Surface>) -> anyhow::Result<()> {
    let pty =
        surface.as_pty().ok_or_else(|| anyhow::anyhow!("frame producer got non-pty surface"))?;
    let key = pty.frame_requests.key;
    if let Some(entry) = scheduler().state.lock().recover_poison().entries.get_mut(&key) {
        entry.surface = Arc::downgrade(surface);
    }
    Ok(())
}

fn run() {
    let scheduler = scheduler();
    let mut state = scheduler.state.lock().recover_poison();
    loop {
        let now = Instant::now();
        let mut due = Vec::new();
        let mut next: Option<Instant> = None;
        for (key, entry) in &mut state.entries {
            let Some(requested) = entry.requested else { continue };
            let at = entry.last_frame.map_or(now, |last| last + RENDER_FRAME_CADENCE);
            if at <= now {
                entry.requested = None;
                due.push((*key, entry.surface.clone(), requested));
            } else {
                next = Some(next.map_or(at, |next| next.min(at)));
            }
        }
        if due.is_empty() {
            state = match next {
                // The cadence of a pending request: a bounded, intended wait.
                Some(at) => scheduler.changed.wait_timeout(state, at - now).recover_poison().0,
                None => scheduler.changed.wait(state).recover_poison(),
            };
            continue;
        }
        drop(state);
        let built: Vec<u64> = due
            .into_iter()
            .filter_map(|(key, surface, requested)| produce(&surface, requested).then_some(key))
            .collect();
        state = scheduler.state.lock().recover_poison();
        let now = Instant::now();
        for key in built {
            if let Some(entry) = state.entries.get_mut(&key) {
                entry.last_frame = Some(now);
            }
        }
    }
}

/// Build one terminal's frame and publish output's scroll position; true
/// when a frame, a colors flush or a scroll position went out.
fn produce(surface: &Weak<Surface>, requested: u64) -> bool {
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
    let built = pty.build_producer_frame(term, generation).unwrap_or(false);
    // A published scroll position paces the terminal like a frame does: with
    // no render viewer no frame is built, and output would otherwise publish
    // a position per chunk.
    let scrolled = pty
        .mux
        .upgrade()
        .is_some_and(|mux| pty.frame_requests.flush_scroll(&mux, pty.event_surface_id));
    built || colors_pending || scrolled
}
