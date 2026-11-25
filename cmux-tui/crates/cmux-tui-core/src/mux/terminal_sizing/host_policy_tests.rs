use super::*;
use serde_json::json;

#[test]
fn host_policy_tokens_expand_to_the_terminals_participants() {
    let participants = vec![
        ("anon:c1/mac".to_string(), true, None),
        ("anon:c2/iphone/p1".to_string(), false, Some("p1".to_string())),
        ("anon:c3/iphone/p2".to_string(), false, Some("p2".to_string())),
    ];
    let policy = HostSizePolicy::from_settings(
        Some(&json!("priority")),
        Some(&json!(["device:p2", "bad token", "mac", "device:p2", 7])),
    );
    assert_eq!(policy.order, vec!["device:p2".to_string(), "mac".to_string()]);
    let expanded = policy.expand(&participants);
    assert_eq!(expanded.mode, TerminalSizingMode::Priority);
    assert_eq!(expanded.priority, vec!["anon:c3/iphone/p2", "anon:c1/mac"]);
    let mac = HostSizePolicy { mode: HostSizeMode::Mac, order: Vec::new() }.expand(&participants);
    assert_eq!(mac.priority, vec!["anon:c1/mac"]);
    assert_eq!(
        HostSizePolicy::from_settings(Some(&json!("nope")), None).mode,
        HostSizeMode::Smallest
    );
}
