//! The contract's policy defaults, one place. Times are ms.
//!
//! A ladder is the order of repairs for one stuck episode: attempt `n` runs
//! `ladder[min(n - 1, len - 1)]`, and after it the model waits
//! `backoff[min(n - 1, len - 1)]` for the part's signal before the next step.
//! At most [`MAX_REPAIRS`] attempts per part in [`REPAIR_WINDOW_MS`]; the
//! next one due past the cap makes the part `failed` instead.

use crate::RepairAction;

/// Pages beat every 2 s while visible (the page's own timer; informational here).
pub const PAGE_BEAT_MS: u64 = 2_000;
/// A visible page silent this long is `slow`.
pub const PAGE_SLOW_SILENT_MS: u64 = 5_000;
/// Input sent but not handled this long is `slow`.
pub const PAGE_SLOW_INPUT_MS: u64 = 3_000;
/// Silent (or input pending) this long is `stuck`.
pub const PAGE_STUCK_MS: u64 = 10_000;
pub const PAGE_LADDER: &[RepairAction] = &[RepairAction::ReloadPage, RepairAction::RestartRenderer];

/// A renderer reported unresponsive this long is `stuck`.
pub const RENDERER_STUCK_MS: u64 = 5_000;
pub const RENDERER_LADDER: &[RepairAction] = &[RepairAction::RestartRenderer];

/// acpmux silent this long (no answered liveness ask) is `stuck`.
pub const ACPMUX_SILENT_MS: u64 = 10_000;
pub const ACPMUX_LADDER: &[RepairAction] =
    &[RepairAction::Reconnect, RepairAction::RestartConnection];

/// This many `loadFailed` within [`PAGE_HOST_FAIL_WINDOW_MS`] is `stuck`.
pub const PAGE_HOST_FAILS: usize = 2;
pub const PAGE_HOST_FAIL_WINDOW_MS: u64 = 30_000;
pub const PAGE_HOST_LADDER: &[RepairAction] = &[RepairAction::RestartPageHost];

/// This many `started` without a `ready` within [`DAEMON_LOOP_WINDOW_MS`] is
/// a restart loop.
pub const DAEMON_LOOP_STARTS: usize = 3;
pub const DAEMON_LOOP_WINDOW_MS: u64 = 600_000;
/// A restore without progress this long is `stuck` (never killed).
pub const DAEMON_STALL_MS: u64 = 120_000;
/// Registry + WAL + output cleanup over this is `slow` (decimal GB, as the
/// macOS Finder counts).
pub const DAEMON_OVERSIZE_BYTES: u64 = 8_000_000_000;

/// A roster restore running this long is `slow`, and `stuck` past the second.
pub const ROSTER_SLOW_MS: u64 = 30_000;
pub const ROSTER_STUCK_MS: u64 = 300_000;

/// Waits after attempt 1, 2, 3 (the last repeats).
pub const BACKOFF_MS: &[u64] = &[2_000, 10_000, 60_000];

/// The least wait after a page repair that loads its document again (`reloadPage`,
/// `restartRenderer`) before the next step: the new document must boot, restore its chat and beat
/// first. A busy agent chat on a loaded Mac took more than 2 s to load after its reload, so the
/// ladder killed its renderer mid-load, twice, and the pane stayed blank (cosmic-gray, 2026-11-11
/// 00:21:28Z reload, 00:21:30Z and 00:21:40Z renderer restarts; Leo: "i tried uploading this video
/// to my nightly app and it just made the screen blank"). The document's `loaded` still ends the
/// episode at once, and a failed result still makes the next step due at once.
pub const PAGE_BOOT_MS: u64 = 30_000;
pub const MAX_REPAIRS: u32 = 3;
pub const REPAIR_WINDOW_MS: u64 = 600_000;

/// Receipts the snapshot keeps (newest first).
pub const RECEIPTS: usize = 64;
/// Pending items the snapshot lists (the rest are counted in `pendingMore`).
pub const PENDING_SHOWN: usize = 8;

/// The step of a ladder for attempt `attempt` (1-based); the last repeats.
pub fn step(ladder: &[RepairAction], attempt: u32) -> RepairAction {
    let index = (attempt.max(1) as usize - 1).min(ladder.len().saturating_sub(1));
    ladder.get(index).copied().unwrap_or(RepairAction::None)
}

/// The wait after attempt `attempt` (1-based); the last repeats.
pub fn backoff(attempt: u32) -> u64 {
    let index = (attempt.max(1) as usize - 1).min(BACKOFF_MS.len().saturating_sub(1));
    BACKOFF_MS.get(index).copied().unwrap_or(0)
}

/// The wait after attempt `attempt` ran `action`: a repair that loads a page's document again
/// waits at least [`PAGE_BOOT_MS`] for that document; every other one waits its [`backoff`].
pub fn wait_after(action: RepairAction, attempt: u32) -> u64 {
    let wait = backoff(attempt);
    match action {
        RepairAction::ReloadPage | RepairAction::RestartRenderer => wait.max(PAGE_BOOT_MS),
        _ => wait,
    }
}
