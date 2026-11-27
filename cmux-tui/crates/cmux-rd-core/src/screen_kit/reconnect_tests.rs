//! Ported from CmuxScreenKitTests/ScreenKitTests.swift and ScreenConnectNoticeTests.swift.
use super::*;

#[test]
fn reconnecting_gives_up_by_count_or_time() {
    assert!(!gives_up(0, 3, 0.0));
    assert!(gives_up(3, 3, 0.0));
    assert!(!gives_up(1, 100, 45.0));
    assert!(gives_up(1, 100, 45.1));
    assert!(gives_up(0, 0, 0.0), "no reconnects at all");
}

#[test]
fn an_attempt_gets_what_is_left_of_the_deadline() {
    assert_eq!(attempt_timeout(0.0), 30.0);
    assert_eq!(attempt_timeout(40.0), 5.0);
    assert_eq!(attempt_timeout(44.5), 1.0);
    assert_eq!(attempt_timeout(100.0), 1.0);
}

#[test]
fn backoff_doubles_to_eight_seconds() {
    let delays: Vec<f64> = (1..=7).map(backoff_delay).collect();
    assert_eq!(delays, [0.0, 1.0, 2.0, 4.0, 8.0, 8.0, 8.0]);
    assert_eq!(backoff_delay(1000), 8.0);
}

#[test]
fn the_card_waits_for_its_notice() {
    use SessionPhase::*;
    assert!(!connecting_notice_shown(Connecting, false, true, false));
    assert!(connecting_notice_shown(Connecting, false, false, true));
    assert!(connecting_notice_shown(Connecting, true, true, false));
    assert!(!connecting_notice_shown(Connecting, true, false, true));
    assert!(!connecting_notice_shown(Failed, false, true, true), "a failure is never held");
    assert!(keeps_live_layout(Connected, false));
    assert!(keeps_live_layout(Connecting, true));
    assert!(!keeps_live_layout(Connecting, false));
    assert!(!keeps_live_layout(Failed, false));
}

#[test]
fn encodings_have_names() {
    let names: Vec<String> = [0, 1, 2, 5, 6, 16, 7, -223].into_iter().map(encoding_name).collect();
    assert_eq!(names, ["Raw", "CopyRect", "RRE", "Hextile", "Zlib", "ZRLE", "#7", "#-223"]);
}
