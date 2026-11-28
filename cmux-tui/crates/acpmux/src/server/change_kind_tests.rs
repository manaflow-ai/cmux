#[test]
fn retry_restore_publishes_a_session_change() {
    assert_eq!(super::session_change_kind("auto_resume_restored"), Some("auto_resume_restored"));
    assert_eq!(super::session_change_kind("auto_resume_stopped"), Some("auto_resume_stopped"));
}

/// The hover card's live counts reach watchers as the summary changes.
#[test]
fn running_work_changes_publish_a_session_change() {
    assert_eq!(super::session_change_kind("subagents_running"), Some("subagents_running"));
    assert_eq!(super::session_change_kind("process_update"), Some("process_update"));
    assert_eq!(super::session_change_kind("loop_detected"), Some("loop_detected"));
    assert_eq!(super::session_change_kind("loop_cleared"), Some("loop_cleared"));
}

/// A parent's row reads `input` while a sub-session below it waits (`hub/asks_below.rs`).
#[test]
fn asks_below_publish_a_session_change() {
    assert_eq!(super::session_change_kind("subsessions_waiting"), Some("subsessions_waiting"));
}
