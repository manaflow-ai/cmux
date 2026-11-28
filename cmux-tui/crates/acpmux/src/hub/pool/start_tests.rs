use super::*;

#[test]
fn the_pooled_kimi_host_spec_carries_expiry_outside_the_harness_environment() {
    let profile: HarnessProfile = serde_json::from_value(json!({
        "argv": ["opencode", "acp"],
        "env": {"ACPMUX_LOCAL_KIMI_EXPIRY": "123456"},
    }))
    .unwrap();
    let draft = crate::hub::resolve::draft_meta(crate::hub::resolve::Draft {
        id: "kimi-fixture".into(),
        agent: "opencode",
        profile: &profile,
        family: "opencode",
        preset: None,
        model_request: None,
        cwd: PathBuf::from("/work"),
        agent_session_id: None,
        policy: None,
        remote: false,
    });
    let command = std::process::Command::new("opencode");
    let spec = pooled_host_spec(&draft.id, &draft, &profile, &command, Vec::new(), None);
    assert_eq!(spec.local_kimi_expiry, Some(123456));
    assert!(spec.env.is_empty());
}
