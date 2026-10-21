//! Render frame producer: turns a surface's render requests into frames at a
//! fixed cadence. Each surface has a lane on the shared executor
//! (`serial_lanes.rs`) instead of a `surface-<id>-frames` thread of its own,
//! so an idle surface costs no thread (perf100 tui lane).

use super::*;
use crate::serial_lanes::{Lane, LaneNext};
use std::sync::OnceLock;

const RENDER_FRAME_CADENCE: Duration = Duration::from_millis(8);

/// The render requests of one surface: the newest requested generation and
/// whether the producer owes a frame. A request while a frame is owed only
/// raises the generation; the first one kicks the surface's lane.
#[derive(Default)]
pub(super) struct FrameRequests {
    requested: AtomicU64,
    armed: AtomicBool,
    lane: OnceLock<Lane>,
}

impl FrameRequests {
    pub(super) fn request(&self, generation: u64) {
        self.requested.fetch_max(generation, Ordering::AcqRel);
        if !self.armed.swap(true, Ordering::AcqRel)
            && let Some(lane) = self.lane.get()
        {
            lane.kick();
        }
    }
}

impl Drop for FrameRequests {
    fn drop(&mut self) {
        if let Some(lane) = self.lane.get() {
            lane.close();
        }
    }
}

pub(super) fn spawn_frame_producer(surface: &Arc<Surface>) -> anyhow::Result<()> {
    let weak = Arc::downgrade(surface);
    let pty = surface.as_pty().expect("frame producer got non-pty surface");
    let requests = Arc::downgrade(&pty.frame_requests);
    #[cfg(test)]
    let before_upgrade = pty.frame_producer_before_upgrade.clone();
    let mut last_frame = Instant::now() - RENDER_FRAME_CADENCE;
    let lane = Lane::new("surface-frames", move || {
        // The lane holds the requests weakly: they own the lane.
        let Some(owed) = requests.upgrade() else { return LaneNext::Close };
        if !owed.armed.load(Ordering::Acquire) {
            return LaneNext::Idle;
        }
        let deadline = last_frame + RENDER_FRAME_CADENCE;
        if Instant::now() < deadline {
            return LaneNext::At(deadline);
        }
        // A request after this swap kicks the lane again; one before it is
        // in `requested` below.
        if !owed.armed.swap(false, Ordering::AcqRel) {
            return LaneNext::Idle;
        }
        let requested = owed.requested.load(Ordering::Acquire);
        drop(owed);
        #[cfg(test)]
        if let Some(hook) = before_upgrade.lock().unwrap().clone() {
            hook();
        }
        let Some(surface) = weak.upgrade() else { return LaneNext::Close };
        let Some(pty) = surface.as_pty() else { return LaneNext::Close };
        let term = pty.term.lock().unwrap();
        let generation = requested.max(pty.render_generation.load(Ordering::Acquire));
        let colors_pending = pty.attach_colors_pending.load(Ordering::Acquire);
        if colors_pending {
            let defaults = pty.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
            let _ = pty.flush_attach_colors_locked(&term, defaults);
        }
        if pty.build_producer_frame(term, generation).unwrap_or(false) || colors_pending {
            last_frame = Instant::now();
        }
        LaneNext::Idle
    });
    let installed = pty.frame_requests.lane.set(lane.clone()).is_ok();
    anyhow::ensure!(installed, "surface {} already has a frame producer", surface.id);
    // A request made before the lane existed is still owed. Kick without
    // reading `armed`: a request racing the install either sees the lane or
    // is seen by this run, and a run with nothing owed returns at once.
    lane.kick();
    Ok(())
}
