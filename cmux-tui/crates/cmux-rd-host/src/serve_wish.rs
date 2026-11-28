//! The viewer's Customize wishes a `cmux-rd serve` session applies (the offer's
//! `a=cmux-rd-max-kbps` and `a=cmux-rd-cursor`, carried by the setup line's `max_kbps` and
//! `cursor`). With no wish the session streams exactly as it did before they existed.

/// The lowest bitrate cap a viewer may ask for, in kbit/s: below it a screen stops being
/// readable at any size, so a smaller wish is taken as this.
pub(crate) const MIN_MAX_KBPS: u32 = 500;

/// The session's bitrate cap: the viewer's wish, never above the host's own (`--max-kbps`)
/// and never below [`MIN_MAX_KBPS`]; no wish keeps the host's.
pub(crate) fn max_kbps(wish: Option<u32>, host_cap: u32) -> u32 {
    wish.map_or(host_cap, |w| w.max(MIN_MAX_KBPS).min(host_cap))
}

/// The start bitrate, held under the session's cap (an explicit `--start-kbps` above a
/// viewer's cap would otherwise start past it).
pub(crate) fn start_kbps(start: u32, max_kbps: u32) -> u32 {
    start.min(max_kbps)
}

/// Whether the stream shows the cursor: the viewer's wish, else yes (as before).
pub(crate) fn show_cursor(wish: Option<bool>) -> bool {
    wish.unwrap_or(true)
}

#[cfg(test)]
#[path = "serve_wish_tests.rs"]
mod tests;
