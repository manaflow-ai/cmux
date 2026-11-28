//! Wire constants the rest of core reads: capability strings, creation and
//! launch-snapshot limits, the launch-snapshot file name (moved out of
//! server.rs and server/launch_snapshot.rs, values unchanged). Lives below
//! `server` (RFD 0174 slice 5): the rest of core uses them without reaching
//! into `server`; `server` re-exports them, so its callers are unchanged.

/// A phone or tablet view that lists this in `set-client-info` shows a
/// terminal grid larger than its own correctly (letterbox or pan). Without it
/// the daemon never applies a PTY grid larger than that view's reported size
/// while the view is attached with one (`mux/terminal_sizing/handheld_ceiling.rs`):
/// such a phone renders the PTY's output into its own grid, so a wider PTY
/// overprints and cuts its rows. The daemon advertises it in `identify`.
pub const HOST_GRID_VIEW_CAPABILITY: &str = "host-grid-view-v1";
pub const MAX_CREATION_SELECTOR_FALLBACKS: usize = 7;
/// Frontend-rendered browser tabs (WebKit or CEF): `new-frontend-browser-tab`,
/// `update-frontend-browser-tab`, and the `browser_renderer`,
/// `browser_engine`, `favicon_url`, and `browser_profile_id` tab fields.
pub const FRONTEND_BROWSER_TABS_CAPABILITY: &str = "frontend-browser-tabs-v1";
/// The file name inside the session's state directory.
pub const LAUNCH_SNAPSHOT_FILE: &str = "launch-snapshot.json";
/// A snapshot larger than this drops its projections, then is not written.
/// The app reads the file before it connects (`LaunchSnapshot.maximumBytes`).
pub(crate) const MAX_LAUNCH_SNAPSHOT_BYTES: usize = 8 * 1024 * 1024;
