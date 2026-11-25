use super::*;

#[test]
fn a_viewer_and_a_guest_never_get_more_than_they_should() {
    // A viewer never writes; a guest never cancels; a teammate never sees typing or view.
    assert!(!VIEWER_VERBS.contains(&"agent-session-prompt"));
    assert!(!GUEST_VERBS.contains(&"agent-session-cancel"));
    assert!(!TEAMMATE_VERBS.contains(&"agent-session-typing"));
    for verbs in [&TEAMMATE_VERBS[..], &GUEST_VERBS[..], &VIEWER_VERBS[..]] {
        assert!(verbs.iter().all(|v| v.starts_with("agent-session-")));
        assert!(!verbs.iter().any(|v| v.contains("permission") || v.contains("start")));
    }
}
