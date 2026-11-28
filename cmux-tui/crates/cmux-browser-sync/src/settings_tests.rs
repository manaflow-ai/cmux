use super::*;
use serde_json::json;

#[test]
fn profiles_sync_is_off_unless_set_true() {
    assert!(!BrowserSyncSettings::from_root(&json!({})).profiles);
    assert!(
        !BrowserSyncSettings::from_root(&json!({"browser": {"sync": {"profiles": "yes"}}}))
            .profiles
    );
    assert!(
        BrowserSyncSettings::from_root(&json!({"browser": {"sync": {"profiles": true}}})).profiles
    );
    assert!(BrowserSyncSettings::from_root(&json!({"browser.sync.profiles": true})).profiles);
    assert_eq!(BrowserSyncSettings::default().escrow, EscrowPolicy::None);
}
