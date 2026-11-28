use super::*;
use security_framework::os::macos::keychain::CreateOptions;

#[test]
fn an_item_refusal_in_a_writable_keychain_is_other_build() {
    let directory = tempfile::tempdir().unwrap();
    let keychain = CreateOptions::new()
        .password("fixture-password")
        .create(directory.path().join("access.keychain"))
        .unwrap();
    let items = SubscriptionItems::in_keychain(keychain);
    items.write("fixture", "value").unwrap();
    let account = account("fixture");
    assert_eq!(without_ui(|| items.failure(INTERACTION_NOT_ALLOWED, &account)), Ok(OTHER_BUILD));
    assert_eq!(without_ui(|| items.failure(AUTH_FAILED, &account)), Ok(OTHER_BUILD));
    assert_eq!(without_ui(|| items.failure(INTERACTION_NOT_ALLOWED, "elsewhere")), Ok(LOCKED));
}
