use super::*;

fn profile(value: serde_json::Value) -> HarnessProfile {
    serde_json::from_value(value).unwrap()
}

/// opencode stays refused from a remote device, and the reason says why
/// precisely (its own config can turn the asks off); the codex-acp adapter
/// keeps the general reason, and Claude starts in its asking modes.
#[test]
fn opencode_is_refused_with_its_own_reason() {
    let table = WebModeTable::default();
    let opencode = profile(serde_json::json!({"argv": ["opencode", "acp"], "family": "opencode"}));
    assert_eq!(remote_start(&table, "opencode", &opencode), Err(OPENCODE_REFUSAL.to_string()));
    // opencode under another family name is still opencode.
    let renamed = profile(
        serde_json::json!({"argv": ["/opt/homebrew/bin/opencode", "acp"], "family": "claude"}),
    );
    assert_eq!(remote_start(&table, "mine", &renamed), Err(OPENCODE_REFUSAL.to_string()));
    let adapter = profile(serde_json::json!({"argv": ["codex-acp"], "family": "codex"}));
    assert_eq!(remote_start(&table, "codex-acp", &adapter), Err(NO_ASKING_MODE.to_string()));
    let claude = profile(serde_json::json!({"argv": ["claude"], "family": "claude"}));
    assert_eq!(
        remote_start(&table, "claude", &claude),
        Ok(vec!["default".to_string(), "plan".to_string()])
    );
}

/// A new Claude chat carries `prompt-suggestions` in its options (on by default), and a
/// chat brought back from another machine keeps it: it never decides what runs unasked.
#[test]
fn prompt_suggestions_is_carried_with_any_value() {
    assert!(CARRIED_CONFIG_IDS.contains(&crate::claude_stdio::prompt_suggestions::OPTION));
    assert!(!FREE_CONFIG_IDS.contains(&crate::claude_stdio::prompt_suggestions::OPTION));
}
