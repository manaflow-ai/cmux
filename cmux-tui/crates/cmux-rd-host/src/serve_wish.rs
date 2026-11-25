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
mod tests {
    use super::*;

    #[test]
    fn no_wish_keeps_todays_session() {
        assert_eq!(max_kbps(None, 50_000), 50_000);
        assert_eq!(start_kbps(30_000, 50_000), 30_000);
        assert!(show_cursor(None));
    }

    #[test]
    fn a_bitrate_wish_caps_within_the_hosts_bounds() {
        assert_eq!(max_kbps(Some(5_000), 50_000), 5_000);
        assert_eq!(max_kbps(Some(90_000), 50_000), 50_000);
        assert_eq!(max_kbps(Some(10), 50_000), MIN_MAX_KBPS);
        // A host capped below the floor keeps its own cap.
        assert_eq!(max_kbps(Some(10), 300), 300);
        assert_eq!(start_kbps(30_000, max_kbps(Some(2_000), 50_000)), 2_000);
    }

    #[test]
    fn a_cursor_wish_is_followed() {
        assert!(!show_cursor(Some(false)));
        assert!(show_cursor(Some(true)));
    }
}
