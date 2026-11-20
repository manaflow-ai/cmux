use super::*;

#[test]
fn a_terminal_agents_session_names_its_terminal_and_others_a_chat() {
    assert_eq!(surface_of("terminal:t-12ab:4242"), json!({"terminal": "t-12ab"}));
    assert_eq!(surface_of("0199a-chat-session"), json!({"chat": "0199a-chat-session"}));
    assert_eq!(surface_of("terminal::1"), json!({"chat": "terminal::1"}));
}
