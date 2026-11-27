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
