//! Render frame producer: the per-surface thread that turns render requests
//! into frames at a fixed cadence.

use super::*;

const RENDER_FRAME_CADENCE: Duration = Duration::from_millis(8);

pub(super) fn spawn_frame_producer(
    surface: &Arc<Surface>,
    requests: Receiver<u64>,
) -> anyhow::Result<()> {
    let weak = Arc::downgrade(surface);
    let id = surface.id;
    #[cfg(test)]
    let before_upgrade = surface
        .as_pty()
        .expect("frame producer got non-pty surface")
        .frame_producer_before_upgrade
        .clone();
    std::thread::Builder::new().name(format!("surface-{id}-frames")).spawn(move || {
        let mut last_frame = Instant::now() - RENDER_FRAME_CADENCE;
        while let Ok(mut requested) = requests.recv() {
            let deadline = last_frame + RENDER_FRAME_CADENCE;
            loop {
                let now = Instant::now();
                if now >= deadline {
                    break;
                }
                match requests.recv_timeout(deadline.saturating_duration_since(now)) {
                    Ok(next) => requested = requested.max(next),
                    Err(RecvTimeoutError::Timeout) => break,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            }
            #[cfg(test)]
            if let Some(hook) = before_upgrade.lock().unwrap().clone() {
                hook();
            }
            let Some(surface) = weak.upgrade() else { break };
            let Some(pty) = surface.as_pty() else { break };
            let mut term = pty.term.lock().unwrap();
            let generation = requested.max(pty.render_generation.load(Ordering::Acquire));
            let colors_pending = pty.attach_colors_pending.load(Ordering::Acquire);
            if colors_pending {
                let defaults =
                    pty.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
                let _ = pty.flush_attach_colors_locked(&term, defaults);
            }
            if pty.build_frame_locked(&mut term, generation, true).unwrap_or(false)
                || colors_pending
            {
                last_frame = Instant::now();
            }
        }
    })?;
    Ok(())
}
