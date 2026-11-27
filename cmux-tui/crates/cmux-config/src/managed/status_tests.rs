use serde_json::{Value, json};

use super::*;

fn request() -> Value {
    json!({
        "context": { "appVersion": "1.2.3", "bundleID": "com.manaflow.cmux.next" },
        "managed": {
            "forced": { "browser.searchEngine": "kagi", "EnrollmentToken": "tok", "UpdateChannel": "stable" },
            "recommended": { "app.language": "en" },
        },
        "team": {
            "teamID": "team_1", "teamName": "T", "version": 4,
            "enforced": { "browser.searchEngine": "duckduckgo", "agents.chats.enabled": false },
        },
        "effective": {
            "root": { "browser": { "searchEngine": "kagi" } },
            "managedKeys": { "browser.searchEngine": "device", "app.language": { "team": "T" } },
        },
    })
}

#[test]
fn body_names_sources_and_hides_the_token() {
    let body = body(&request());
    assert_eq!(body["schema_version"], 1);
    assert_eq!(body["domain"], "com.manaflow.cmux");
    assert_eq!(body["profile_present"], true);
    assert_eq!(
        body["keys_forced"],
        json!(["EnrollmentToken", "UpdateChannel", "browser.searchEngine"])
    );
    assert_eq!(body["keys_recommended"], json!(["app.language"]));
    assert_eq!(body["policy"], json!({ "EnrollmentToken": "<set>", "UpdateChannel": "stable" }));
    assert_eq!(body["enrollment_token_present"], true);
    assert_eq!(body["managing_team"], json!({ "id": "team_1", "name": "T", "policy_version": 4 }));
    assert_eq!(
        body["applied"],
        json!([
            { "key": "app.language", "source": "team", "value": null },
            { "key": "browser.searchEngine", "source": "mdm", "value": "kagi" },
        ])
    );
    assert!(!body.to_string().contains("\"tok\""));
}

#[test]
fn the_mdm_value_wins_a_conflict_and_chat_keys_are_skipped() {
    let body = body(&request());
    assert_eq!(
        body["conflicts"],
        json!([{ "key": "browser.searchEngine", "mdm_value": "kagi", "team_value": "duckduckgo", "winner": "mdm" }])
    );
}

#[test]
fn an_empty_profile_and_no_team_report_null() {
    let body = body(&json!({ "context": { "appVersion": "1", "bundleID": "b" } }));
    assert_eq!(body["profile_present"], false);
    assert_eq!(body["managing_team"], Value::Null);
    assert_eq!(body["enrollment_token_present"], false);
}

#[test]
fn document_adds_the_write_time() {
    let doc = document(&json!({ "a": 1 }), "2026-11-25T00:00:00Z");
    assert_eq!(doc["written_at"], "2026-11-25T00:00:00Z");
}

#[test]
fn paths_follow_the_bundle() {
    assert_eq!(
        path("com.cmuxterm.app", "/Users/x", false),
        "/Users/x/Library/Application Support/cmux-next/managed-status.json"
    );
    assert_eq!(
        path("com.manaflow.cmux.next", "/Users/x/", true),
        "/Users/x/Library/Application Support/cmux/managed-status.com.manaflow.cmux.next.json"
    );
}
