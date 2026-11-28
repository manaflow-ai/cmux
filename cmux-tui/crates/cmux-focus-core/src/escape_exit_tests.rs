use super::*;

fn escape(timestamp: f64, tab: &str) -> Key {
    Key { is_plain_escape: true, is_repeat: false, timestamp, focus_mode_tab: Some(tab.to_owned()) }
}

fn exit(tab: &str) -> Outcome {
    Outcome::Exit { tab: tab.to_owned() }
}

#[test]
fn esc_esc_leaves_focus_mode() {
    let mut gesture = EscapeExit::default();
    assert_eq!(gesture.handle(&escape(10.0, "tab_page")), Outcome::ForwardToPage);
    assert_eq!(gesture.armed_tab.as_deref(), Some("tab_page"));
    assert_eq!(gesture.handle(&escape(10.5, "tab_page")), exit("tab_page"));
    assert_eq!(gesture.armed_tab, None);
}

#[test]
fn late_second_escape_rearms_instead_of_exiting() {
    let mut gesture = EscapeExit::default();
    assert_eq!(gesture.handle(&escape(10.0, "t")), Outcome::ForwardToPage);
    assert_eq!(gesture.handle(&escape(12.0, "t")), Outcome::ForwardToPage);
    assert_eq!(gesture.handle(&escape(13.0, "t")), exit("t"));
}

#[test]
fn exactly_the_interval_still_exits() {
    let mut gesture = EscapeExit::default();
    gesture.handle(&escape(10.0, "t"));
    assert_eq!(gesture.handle(&escape(10.0 + SEQUENCE_INTERVAL, "t")), exit("t"));
}

#[test]
fn other_key_disarms() {
    let mut gesture = EscapeExit::default();
    gesture.handle(&escape(10.0, "t"));
    let other = Key { is_plain_escape: false, ..escape(10.2, "t") };
    assert_eq!(gesture.handle(&other), Outcome::Pass);
    assert_eq!(gesture, EscapeExit::default());
    assert_eq!(gesture.handle(&escape(10.4, "t")), Outcome::ForwardToPage);
}

#[test]
fn held_escape_never_counts_as_second_press() {
    let mut gesture = EscapeExit::default();
    gesture.handle(&escape(10.0, "t"));
    let held = Key { is_repeat: true, ..escape(10.1, "t") };
    assert_eq!(gesture.handle(&held), Outcome::Consume);
    // The same key-down seen twice (two hooks) is one press.
    assert_eq!(gesture.handle(&escape(10.0, "t")), Outcome::Consume);
    assert_eq!(gesture.armed_tab.as_deref(), Some("t"));
}

#[test]
fn escape_outside_focus_mode_is_untouched() {
    let mut gesture = EscapeExit::default();
    let outside = Key { focus_mode_tab: None, ..escape(10.0, "t") };
    assert_eq!(gesture.handle(&outside), Outcome::Pass);
    assert_eq!(gesture.handle(&outside), Outcome::Pass);
}

#[test]
fn armed_exit_belongs_to_one_tab() {
    let mut gesture = EscapeExit::default();
    assert_eq!(gesture.handle(&escape(10.0, "tab_a")), Outcome::ForwardToPage);
    assert_eq!(gesture.handle(&escape(10.3, "tab_b")), Outcome::ForwardToPage);
    assert_eq!(gesture.armed_tab.as_deref(), Some("tab_b"));
}
