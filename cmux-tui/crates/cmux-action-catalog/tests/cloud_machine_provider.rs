//! The app-backed create must accept the provider sent by start-chat.
use cmux_action_catalog::find;

#[test]
fn new_machine_accepts_an_optional_provider_without_prompting_for_it() {
    let action = find("newCloudMachine").unwrap();
    let provider = action.arguments.iter().find(|arg| arg.name == "provider").unwrap();
    assert!(!provider.required);
    assert!(!provider.asked_in_palette);
}
