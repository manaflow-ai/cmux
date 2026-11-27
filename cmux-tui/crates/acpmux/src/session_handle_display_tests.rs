use super::*;

#[test]
fn a_broker_alias_reads_with_spaces_and_a_shown_cell_matches_its_value() {
    assert_eq!(spoken_alias("Logan+dot+chats-going-blank"), "Logan dot chats-going-blank");
    assert_eq!(spoken_alias("Ruby dot startup-speedups"), "Ruby dot startup-speedups");
    assert!(shown_matches("app-version-rollback", "App-Version-Rollback"));
    assert!(shown_matches("chat-recovery-versi…", "chat-recovery-version-rollback"));
    assert!(!shown_matches("chat-recovery-version-rollback…", "chat-recovery-version-rollback"));
    assert!(!shown_matches("app-version", "app-version-rollback"));
    assert!(!shown_matches("…", "anything"));
}
