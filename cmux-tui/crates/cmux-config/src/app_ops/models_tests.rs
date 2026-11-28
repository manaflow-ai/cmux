//! Pins Swift `SettingsModels`' outputs before the port (`connection(_:)`,
//! `withoutWhitespace`, `isOneWord`, `isModelAPIKey`, `isClaudeToken`,
//! `kind(of:)`), as `SettingsModelsTests` read them.

use serde_json::json;

use super::*;
use crate::app_ops::call as op;

#[test]
fn a_connection_reads_as_the_page_draws_it() {
    let reply = op(
        "models.connections",
        &json!({"connections": [
            {"id": "c1", "kind": "api-key", "provider": "xai", "families": ["grok", 3], "enabled": true,
             "serves_cloud": true, "default_for": ["codex"], "endpoint": {"url": "x"}, "expires_at": 12},
            {"id": "", "kind": "api-key"},
            {"id": "c2", "kind": "mystery"},
            {"id": "c3", "kind": "claude-token", "provider": "bogus", "signedIn": true, "label": "Mine",
             "can_serve_cloud": false, "cloud_families": null, "defaultFor": ["claude"]},
            {"id": "c4", "kind": "native-login", "provider": "cursor", "servesCloud": true},
            {"id": "c5", "kind": "native-login", "provider": "zed"},
            {"id": "c6", "kind": "endpoint", "provider": "my-box", "families": "nope", "launch_harness": "codex"},
        ]}),
    )
    .unwrap();
    let rows = reply["connections"].as_array().unwrap();
    assert_eq!(rows.len(), 5, "no id and unknown kind are left out");
    assert_eq!(
        rows[0],
        json!({"id": "c1", "kind": "api-key", "provider": "xai", "credentialInstance": null, "keyRevision": null,
               "families": ["grok"], "label": "c1", "email": null, "plan": null, "signedIn": false,
               "signInReason": null, "enabled": true, "defaultFor": ["codex"], "servesCloud": true,
               "canServeCloud": true, "cloudFamilies": ["grok"], "canCheckAccess": false, "canReplaceKey": false,
               "endpoint": {"url": "x"}, "launchHarness": null, "expiresAt": 12})
    );
    assert_eq!(rows[1]["provider"], "anthropic", "an unknown provider falls back by kind");
    assert_eq!(rows[1]["signedIn"], true, "the camelCase spelling is read too");
    assert_eq!(rows[1]["label"], "Mine");
    assert_eq!(rows[1]["canServeCloud"], false);
    assert_eq!(rows[1]["cloudFamilies"], json!(null), "a present null stays");
    assert_eq!(rows[1]["defaultFor"], json!(["claude"]));
    assert_eq!(rows[2]["provider"], "cursor");
    assert_eq!(rows[2]["servesCloud"], true);
    assert_eq!(rows[3]["provider"], "openai", "native-login keeps only its own providers");
    assert_eq!(rows[4]["provider"], "my-box", "an endpoint keeps any provider");
    assert_eq!(rows[4]["families"], json!([]));
    assert_eq!(rows[4]["launchHarness"], "codex");
    assert_eq!(op("models.connections", &json!({})).unwrap(), json!({"connections": []}));
}

#[test]
fn a_wrapped_or_padded_claude_token_is_one_token() {
    // Leo, 2026-11-25: "your terminal sometimes gets cut off with spaces and the text entry doesnt
    // strip spaces".
    let pasted = "  sk-ant-oat01-ABCdef_0123\n   -456789\u{200B}xyz \r\n\t";
    let facts = op("models.secret", &json!({ "secret": pasted })).unwrap();
    assert_eq!(facts["clean"], "sk-ant-oat01-ABCdef_0123-456789xyz");
    assert_eq!(facts["claudeToken"], true);
    assert_eq!(facts["apiKey"], false, "a setup token is not an API key");
    assert_eq!(facts["oneWord"], true);
    assert_eq!(without_whitespace("a\u{00A0}b\u{2060}c\u{FEFF}"), "abc");
}

#[test]
fn a_claude_token_has_its_shape() {
    assert!(is_claude_token("sk-ant-oat01-abc"));
    assert!(!is_claude_token("sk-ant-oat01-"), "nothing after the dash");
    assert!(!is_claude_token("sk-ant-oatx1-abc"));
    assert!(!is_claude_token("sk-ant-oat01_abc"));
    assert!(!is_claude_token("sk-ant-oat01-ab.c"));
    assert!(!is_claude_token("sk-proj-abc"));
    let long = format!("sk-ant-oat01-{}", "a".repeat(KEY_LIMIT));
    assert!(!is_claude_token(&long));
}

#[test]
fn an_api_key_is_one_printable_word() {
    assert!(is_model_api_key("sk-proj-abc"));
    assert!(!is_model_api_key("sk-ant-oat01-abc"));
    assert!(!is_model_api_key(""));
    assert!(!is_model_api_key("two words"));
    assert!(!is_model_api_key("caf\u{e9}"));
    assert!(is_one_word(&"a".repeat(KEY_LIMIT)));
    assert!(!is_one_word(&"a".repeat(KEY_LIMIT + 1)));
}

#[test]
fn a_team_key_kind_follows_its_shape() {
    assert_eq!(kind_of("sk-ant-oat01-abc"), "oauth");
    assert_eq!(kind_of(r#"{"tokens":{}}"#), "oauth");
    assert_eq!(kind_of("sk-proj-abc"), "api_key");
    let facts =
        op("models.secret", &json!({"secret": " sk-proj-abc", "provider": "google"})).unwrap();
    assert_eq!(facts["kind"], "api_key");
    assert_eq!(facts["providerKnown"], true);
    let facts = op("models.secret", &json!({"secret": "k", "provider": "mistral"})).unwrap();
    assert_eq!(facts["providerKnown"], false);
    assert!(op("models.secret", &json!({})).is_err());
}
