use super::*;
use crate::hand::config::{HandConfig, Profile};
use std::path::PathBuf;

#[test]
fn pair_json_summary_is_safe_and_machine_readable() {
    let cfg = HandConfig {
        api: "https://cloud.example".into(),
        hand: "hand_test".into(),
        key: "secret-key-must-not-leak".into(),
        profile: Profile::Sandbox,
        roots: vec![PathBuf::from("/")],
        allow: Vec::new(),
        agent_policy: "approve-edits".into(),
    };
    let summary = pair_summary(&cfg);
    assert_eq!(summary["paired"], true);
    assert_eq!(summary["hand"], "hand_test");
    assert!(summary.get("key").is_none());
    assert!(!summary.to_string().contains("secret-key"));
}
