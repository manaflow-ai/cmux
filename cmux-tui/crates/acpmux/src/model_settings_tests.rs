use super::*;
use serde_json::json;

#[test]
fn chat_defaults_read_nested_and_flat_keys() {
    let nested = json!({"agents": {"defaults": {
        "claude": {"model": "claude-sonnet-5-5", "effort": "high"},
        "codex": {"model": " gpt-6.2-sol ", "effort": "xhigh"}
    }}});
    assert_eq!(
        ChatDefaults::from_doc(&nested, "claude"),
        ChatDefaults { model: Some("claude-sonnet-5-5".into()), effort: Some("high".into()) }
    );
    assert_eq!(
        ChatDefaults::from_doc(&nested, "codex"),
        ChatDefaults { model: Some("gpt-6.2-sol".into()), effort: Some("xhigh".into()) }
    );
    let flat = json!({"agents.defaults.codex.effort": "low"});
    assert_eq!(
        ChatDefaults::from_doc(&flat, "codex"),
        ChatDefaults { model: None, effort: Some("low".into()) }
    );
}

#[test]
fn unset_values_keep_todays_chain() {
    let doc = json!({"agents": {"defaults": {
        "claude": {"model": "", "effort": "auto"},
        "codex": {"model": "default", "effort": 3}
    }}});
    assert_eq!(ChatDefaults::from_doc(&doc, "claude"), ChatDefaults::default());
    assert_eq!(ChatDefaults::from_doc(&doc, "codex"), ChatDefaults::default());
    assert_eq!(ChatDefaults::from_doc(&json!({}), "claude"), ChatDefaults::default());
}

#[test]
fn only_the_listed_families_have_rows() {
    let doc = json!({"agents": {"defaults": {"gemini": {"model": "gemini-3.1-pro-preview"}}}});
    assert_eq!(ChatDefaults::from_doc(&doc, "gemini"), ChatDefaults::default());
}

#[test]
fn text_model_reads_the_titles_row() {
    assert_eq!(
        text_model_from_doc(&json!({"agents": {"titles": {"model": "sonnet"}}})),
        Some("sonnet".into())
    );
    assert_eq!(text_model_from_doc(&json!({"agents.titles.model": "opus"})), Some("opus".into()));
    assert_eq!(text_model_from_doc(&json!({"agents": {"titles": {"model": " "}}})), None);
    assert_eq!(text_model_from_doc(&json!({})), None);
}
