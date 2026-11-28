use super::chat_folder_switch_on;

/// The no-folder prewarm is on unless its switch says off.
#[test]
fn the_chat_folder_prewarm_is_on_by_default_and_off_only_by_its_switch() {
    assert!(chat_folder_switch_on(None), "unset is on");
    for on in ["1", "true", "on", "", "yes"] {
        assert!(chat_folder_switch_on(Some(on)), "{on:?} leaves it on");
    }
    for off in ["0", "false", "off", " OFF ", "False"] {
        assert!(!chat_folder_switch_on(Some(off)), "{off:?} turns it off");
    }
}
