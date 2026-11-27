//! The contract's policy defaults, one place. Times are ms.
//!
//! A ladder is the order of repairs for one stuck episode: attempt `n` runs
//! `ladder[min(n - 1, len - 1)]`, and after it the model waits
//! `backoff[min(n - 1, len - 1)]` for the part's signal before the next step.
//! At most [`MAX_REPAIRS`] attempts per part in [`REPAIR_WINDOW_MS`]; the
//! next one due past the cap makes the part `failed` instead, until the
//! window lets its oldest attempt go and the part tries again by itself.

use crate::RepairAction;

/// Pages beat every 2 s while visible and active (the page's own timer; informational here).
pub const PAGE_BEAT_MS: u64 = 2_000;
/// A visible page with no input, scroll, edit or host call for this long sends a `rest` beat and
/// stops beating (the page's own clock; informational here): an idle app wakes for no page. One beat:
/// a quiet page's silence proves nothing a beat would, and input sent to a resting page is still timed.
pub const PAGE_REST_AFTER_MS: u64 = 2_000;
/// A visible page silent this long is `slow`.
pub const PAGE_SLOW_SILENT_MS: u64 = 5_000;
/// Input sent but not handled this long is `slow`.
pub const PAGE_SLOW_INPUT_MS: u64 = 3_000;
/// Silent (or input pending) this long is `stuck`.
pub const PAGE_STUCK_MS: u64 = 10_000;
pub const PAGE_LADDER: &[RepairAction] = &[RepairAction::ReloadPage, RepairAction::RestartRenderer];

/// Several visible pages silent together are one stall of what they share (their Chromium renderer,
/// or the whole Mac), not one hung page each. A page stuck by silence while another visible,
/// non-resting page has been silent at least [`PAGE_SLOW_SILENT_MS`] is `slow`, not repaired: a
/// reload of each page loads more into the stalled renderer, and the ladder's next step killed the
/// renderer every agent chat shares, so every chat went blank at once (a Mac in swap, 2026-11-21:
/// the chats' renderer at 3.7 GB, three pages reloaded within 7 s and their renderer restarted
/// 30 s later; Leo: "the gui agent chats all blanked out just now"). A page silent while its
/// siblings beat is still a hung page and climbs [`PAGE_LADDER`].
///
/// The stall is waited out this long from its oldest silence; then the page silent longest, alone,
/// gets [`PAGE_SHARED_STALL_LADDER`], so a renderer that really hangs is still ended once.
///
/// The stall's renderer restarts are counted for all pages together (the renderer is theirs, not
/// one page's): attempt `n` waits [`shared_wait_after`] after attempt `n - 1`, at most
/// [`MAX_REPAIRS`] in [`REPAIR_WINDOW_MS`], then the stall is `failed`. Counted per page, each
/// restart reloaded the page it was sent for, the next silent page became the one silent longest,
/// and its "attempt 1" went out 30 s after the last: five renderer kills in two minutes, every chat
/// blank (cosmic-gray, 2026-11-22 06:43:45Z to 06:45:47Z).
pub const PAGE_SHARED_STALL_MS: u64 = 120_000;
pub const PAGE_SHARED_STALL_LADDER: &[RepairAction] = &[RepairAction::RestartRenderer];
/// How often a page waiting on a shared stall looks again (a sibling that beats again leaves it a
/// hung page of its own). Only while a stall lasts.
pub const PAGE_SHARED_RECHECK_MS: u64 = 5_000;

/// A renderer reported unresponsive this long is `stuck`.
pub const RENDERER_STUCK_MS: u64 = 5_000;
pub const RENDERER_LADDER: &[RepairAction] = &[RepairAction::RestartRenderer];

/// Liveness (one renderer of visible agent chats): quiet this long (no beat from any of its
/// pages, no ping answer) gets a ping. Its pages beat every 2 s while anything happens in them,
/// so only a renderer whose pages all rest is pinged: at most one round trip per renderer per
/// 15 s, and none for a renderer with no visible chat.
pub const LIVENESS_QUIET_MS: u64 = 15_000;
/// A ping unanswered this long gets a second one.
pub const LIVENESS_PING_EVERY_MS: u64 = 15_000;
/// Pings unanswered in a row before a renderer can be hung.
pub const LIVENESS_PINGS: usize = 2;
/// Hung: [`LIVENESS_PINGS`] pings unanswered and this long since the first of them, all of it
/// visible and awake. The part is registered only after its first page's first beat, so a
/// document still booting at a cold launch is never timed; a renderer is ended at the earliest
/// 45 s after it last answered.
pub const LIVENESS_HUNG_MS: u64 = 30_000;
/// A tick this much later than its deadline means the host itself did not run (App Nap, a
/// debugger stopped the app, a stall of its own): the pings out are void.
pub const LIVENESS_LATE_MS: u64 = 5_000;
pub const LIVENESS_LADDER: &[RepairAction] = &[RepairAction::EndRenderer];

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

/// A page whose document the host is loading (`navigationStarted`: a reload for a web source
/// change, crash recovery, a renderer restart that reloaded it, any navigation the host started) is
/// loading, not hung, until the document loads or this long passes: its silence and input are not
/// timed, and no repair goes to it. Then it is judged as any page, from its load's start. A
/// `web-dev.json` change reloaded every chat at once on a Mac at load 133 on 15 cores; their
/// documents loaded in 44 s and 72 s, and the model, reading the old documents' silence, reloaded
/// them 8 s in and then restarted their renderer (cosmic-gray, 2026-11-22 06:41:33Z; Leo: "some
/// sort of situation just now that compLETELY blanked out this agent chat + the update notes").
/// Longer than [`PAGE_BOOT_MS`]: with 30 s the update notes, still loading once the agent chat beat
/// again, read as a hung page alone and were reloaded at 44 s. A load that never ends is still
/// repaired, as late as a shared stall is. A page in a repair episode keeps the ladder's own wait
/// ([`wait_after`]).
pub const PAGE_LOAD_MS: u64 = PAGE_SHARED_STALL_MS;
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
        RepairAction::ReloadPage | RepairAction::RestartRenderer | RepairAction::EndRenderer => {
            wait.max(PAGE_BOOT_MS)
        }
        _ => wait,
    }
}

/// The least wait after a shared stall's `restartRenderer` attempt `attempt` (1-based) before the
/// next: [`PAGE_SHARED_STALL_MS`], doubling with each attempt.
pub fn shared_wait_after(attempt: u32) -> u64 {
    let doublings = attempt.max(1).saturating_sub(1).min(8);
    PAGE_SHARED_STALL_MS.saturating_mul(1 << doublings)
}
