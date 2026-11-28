use super::applies;

#[test]
fn only_an_opencode_fork_into_the_chats_folder_is_made_by_its_own_agent() {
    assert!(applies(true, true, true));
    assert!(!applies(false, true, true), "other agents fork through the chat's process");
    assert!(!applies(true, false, true), "an agent without session/fork");
    assert!(!applies(true, true, false), "a fork into another folder");
}
