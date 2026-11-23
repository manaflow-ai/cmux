use super::*;

#[test]
fn a_native_owner_may_fork_its_attached_chat() {
    assert!(admits(r#"{"cmd":"agent-session-fork","surface":1,"through_seq":3}"#));
    assert!(CAPABILITIES.contains(&AGENT_SESSION_FORK_CAPABILITY));
}

/// A Cloud chat's New side chat and `/side` (agent_session_side.rs): the owner's carrier
/// reaches it, and the carrier's identify names it.
#[test]
fn a_native_owner_may_open_a_side_chat_of_its_attached_chat() {
    assert!(admits(r#"{"cmd":"agent-session-side","surface":1,"live":true}"#));
    assert!(CAPABILITIES.contains(&agent_session_attach::AGENT_SESSION_SIDE_CAPABILITY));
}
