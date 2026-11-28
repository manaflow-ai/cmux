use super::*;
use serde_json::json;

#[test]
fn no_key_or_null_is_off_and_a_bad_value_is_an_error() {
    assert_eq!(from_params(&json!({})), Ok(None));
    assert_eq!(from_params(&json!({"lockdown": null})), Ok(None));
    assert!(from_params(&json!({"lockdown": true})).is_err());
    assert!(from_params(&json!({"lockdown": {"harnesses": 7}})).is_err());
    assert!(from_params(&json!({"lockdown": {"models": [1]}})).is_err());
    assert_eq!(
        from_params(&json!({"lockdown": {"harnesses": [" claude ", ""]}})),
        Ok(Some(Lockdown { harnesses: vec!["claude".into()], models: vec![] }))
    );
}

#[test]
fn empty_lists_allow_everything() {
    let l = Lockdown::default();
    assert_eq!(l.refuses_harness("codex"), None);
    assert_eq!(l.refuses_model("gpt-9"), None);
}

#[test]
fn lists_allow_only_their_entries_and_model_prefixes() {
    let l = Lockdown { harnesses: vec!["claude".into()], models: vec!["claude-opus".into()] };
    assert_eq!(l.refuses_harness("claude"), None);
    assert!(l.refuses_harness("codex").unwrap().contains("sessions.lockdownHarnesses"));
    assert_eq!(l.refuses_model("claude-opus-5-5"), None);
    assert!(l.refuses_model("claude-haiku-5-5").unwrap().contains("sessions.lockdownModels"));
}

#[test]
fn a_start_checks_its_harness_then_its_named_model() {
    let l = Lockdown { harnesses: vec!["claude".into()], models: vec!["claude-opus".into()] };
    assert!(start_refusal(Some(&l), "codex", None).is_some());
    assert!(start_refusal(Some(&l), "claude", Some("claude-sonnet-5-5")).is_some());
    assert_eq!(start_refusal(Some(&l), "claude", Some("")), None);
    assert_eq!(start_refusal(Some(&l), "claude", Some("claude-opus-5-5")), None);
    assert_eq!(start_refusal(None, "codex", Some("gpt-9")), None);
}

#[test]
fn a_list_may_be_the_settings_text_split_on_commas_and_spaces() {
    assert_eq!(
        from_params(
            &json!({"lockdown": {"harnesses": "claude, codex", "models": " claude-opus ,,gpt-5 "}})
        ),
        Ok(Some(Lockdown {
            harnesses: vec!["claude".into(), "codex".into()],
            models: vec!["claude-opus".into(), "gpt-5".into()],
        }))
    );
    assert_eq!(from_params(&json!({"lockdown": {"harnesses": ""}})), Ok(Some(Lockdown::default())));
}
