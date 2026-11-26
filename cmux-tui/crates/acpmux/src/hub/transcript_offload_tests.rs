use super::*;

#[test]
fn off_by_default_and_removal_is_a_second_opt_in() {
    assert_eq!(settings(&json!({})), None);
    assert_eq!(settings(&json!({"agents": {"chats": {"transcriptOffload": false}}})), None);
    // Removal alone turns nothing on.
    assert_eq!(
        settings(&json!({"agents": {"chats": {"transcriptOffloadDeleteLocal": true}}})),
        None
    );
    assert_eq!(
        settings(&json!({"agents": {"chats": {"transcriptOffload": true}}})),
        Some(Settings { days: DEFAULT_DAYS, delete_local: false })
    );
    assert_eq!(
        settings(&json!({"agents": {"chats": {
            "transcriptOffload": true,
            "transcriptOffloadDeleteLocal": true,
            "cloudOffloadAfterDays": 30
        }}})),
        Some(Settings { days: 30, delete_local: true })
    );
}
