use super::*;

#[test]
fn side_sessions_keep_the_newest_and_only_a_tagged_page_is_a_side_chat() {
    let known = SideSessions::default();
    for index in 0..=MAX_KNOWN {
        known.remember(&format!("acp_{index}"));
    }
    known.remember("");
    assert!(!known.contains("acp_0"));
    assert!(known.contains("acp_1"));
    assert!(known.contains(&format!("acp_{MAX_KNOWN}")));
    assert!(!known.contains(""));
    assert!(tagged(&json!({"session": {"tags": {"side": "acp_chat"}}})));
    assert!(!tagged(&json!({"session": {"tags": {"bead:cx-1": "1"}}})));
    assert!(!tagged(&json!({"session": {"sessionId": "acp_chat"}})));
}
