//! Host-side state of the terminal-host runtime that does not touch the OS
//! (cx-ko2e table A): host timeouts and limits, PTY geometry, the
//! kitty-graphics ceiling check, viewer-size arbitration and the exit
//! publication claim. `HostShared` follows once its OS fields sit behind
//! seams.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use cmux_pty::PtySize;

use super::super::*;

pub(crate) const HOST_TERMINATE_GRACE: Duration = Duration::from_millis(250);
// Match the remote PTY bridge's bounded outstanding-write precedent.
// This protects the local control-response waiter table from an unbounded
// burst of durable API input without serializing every receipt.
pub(crate) const MAX_PENDING_INPUT_ACKS: usize = 256;
// Keep the total outstanding receipted payload bounded too. Using the
// existing frame-payload ceiling preserves admission for one maximum-sized
// legal Input while preventing 256 such frames from accumulating.
pub(crate) const MAX_PENDING_INPUT_ACK_BYTES: usize = MAX_FRAME_PAYLOAD;
pub(crate) const HOST_KILL_WAIT: Duration = Duration::from_secs(2);
pub(crate) const HOST_PTY_DRAIN_GRACE: Duration = Duration::from_millis(250);
pub(crate) const HOST_FORCED_DRAIN_WINDOW: Duration = Duration::from_millis(100);
pub(crate) const HOST_LAUNCH_ROLLBACK_WAIT: Duration = Duration::from_secs(4);
pub(crate) const HOST_LAUNCH_OWNER_TIMEOUT: Duration = Duration::from_secs(5);
pub(crate) const HOST_CLIENT_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
pub(crate) const HOST_HANDSHAKE_TRANSIENT_RETRIES: usize = 1;
pub(crate) const HOST_EXIT_PERSIST_RETRY_MIN: Duration = Duration::from_millis(100);
pub(crate) const HOST_EXIT_PERSIST_RETRY_MAX: Duration = Duration::from_secs(5);
pub(crate) const HOST_EXIT_PERSIST_REPORT_INTERVAL: Duration = Duration::from_secs(60);

pub(crate) fn pty_size(cols: u16, rows: u16, cell_pixels: (u16, u16)) -> anyhow::Result<PtySize> {
    let pixel_width = cols.checked_mul(cell_pixels.0).ok_or_else(|| {
        anyhow::anyhow!(
            "terminal pixel width exceeds {}: {cols} columns at {} pixels per cell",
            u16::MAX,
            cell_pixels.0
        )
    })?;
    let pixel_height = rows.checked_mul(cell_pixels.1).ok_or_else(|| {
        anyhow::anyhow!(
            "terminal pixel height exceeds {}: {rows} rows at {} pixels per cell",
            u16::MAX,
            cell_pixels.1
        )
    })?;
    Ok(PtySize { rows, cols, pixel_width, pixel_height })
}

pub(crate) fn kitty_graphics_limits_within(
    candidate: KittyGraphicsLimits,
    ceiling: KittyGraphicsLimits,
) -> bool {
    candidate.image_bytes <= ceiling.image_bytes
        && candidate.inflight_bytes <= ceiling.inflight_bytes
        && candidate.images <= ceiling.images
        && candidate.placements <= ceiling.placements
}

pub(crate) fn input_request_is_supported(selected_version: u16, request_id: u64) -> bool {
    request_id == 0 || selected_version >= PROTOCOL_VERSION
}

pub(crate) fn persist_and_claim_host_exit_after_drain(
    child_exited: &Mutex<Option<TerminalExit>>,
    pty_drained: &AtomicBool,
    exit_published: &AtomicBool,
    persist: impl FnOnce(&TerminalExit) -> anyhow::Result<()>,
) -> anyhow::Result<Option<TerminalExit>> {
    if !pty_drained.load(Ordering::Acquire) {
        return Ok(None);
    }
    let Some(exit) = child_exited.lock().unwrap().clone() else {
        return Ok(None);
    };
    if exit_published.load(Ordering::Acquire) {
        return Ok(None);
    }
    persist(&exit)?;
    Ok(exit_published
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_ok()
        .then_some(exit))
}

/// Viewer geometry reservations and the clients that negotiated
/// `FLAG_VIEWER_SIZE_PRIORITY` for the lifetime of their connection.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ViewerSizes {
    pub(crate) sizes: HashMap<u64, (u16, u16)>,
    pub(crate) preferred: HashSet<u64>,
}

impl ViewerSizes {
    /// Per-dimension minimum over preferred sizes, or over every size when
    /// no preferred client currently reports one.
    pub(crate) fn desired(&self) -> Option<(u16, u16)> {
        let minimum =
            |left: (u16, u16), right: (u16, u16)| (left.0.min(right.0), left.1.min(right.1));
        self.sizes
            .iter()
            .filter_map(|(client, size)| self.preferred.contains(client).then_some(*size))
            .reduce(minimum)
            .or_else(|| self.sizes.values().copied().reduce(minimum))
    }

    /// ReleaseViewer drops the size but keeps priority for the connection.
    pub(crate) fn release(&mut self, client: u64) {
        self.sizes.remove(&client);
    }

    pub(crate) fn remove_client(&mut self, client: u64) {
        self.sizes.remove(&client);
        self.preferred.remove(&client);
    }
}

/// Keep viewer mutation, minimum reduction, and the resulting PTY resize
/// in one critical section. If the guard were released after reduction,
/// an older large resize could run after a newer small resize and leave
/// the host at a size that no longer matches its viewer set.
pub(crate) fn mutate_viewer_sizes(
    viewer_sizes: &Mutex<ViewerSizes>,
    mutation: impl FnOnce(&mut ViewerSizes),
    apply: impl FnOnce(Option<(u16, u16)>) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    let mut viewer_sizes = viewer_sizes.lock().unwrap();
    let previous = viewer_sizes.clone();
    mutation(&mut viewer_sizes);
    if let Err(error) = apply(viewer_sizes.desired()) {
        *viewer_sizes = previous;
        return Err(error);
    }
    Ok(())
}
