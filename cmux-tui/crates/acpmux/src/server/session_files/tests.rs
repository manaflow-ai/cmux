use super::*;
use crate::config::StoreMode;
use crate::hub::Hub;
use crate::server::Origin;
use serde_json::json;
use std::collections::BTreeSet;

fn meta(extra: Value) -> SessionMeta {
    let mut value = json!({
        "schema": "acpmux.session.v1",
        "id": "mux-session",
        "name": "palette fixture",
        "harness": "claude",
        "family": "claude",
        "cwd": "/tmp/palette-cwd",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 2,
    });
    if let Some(extra) = extra.as_object() {
        for (key, extra_value) in extra {
            value.as_object_mut().unwrap().insert(key.clone(), extra_value.clone());
        }
    }
    serde_json::from_value(value).unwrap()
}

fn hub() -> std::sync::Arc<Hub> {
    let mut config = crate::config::Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

fn local_hub() -> (std::sync::Arc<Hub>, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!("acpmux-session-files-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let mut config = crate::config::Config::default();
    config.store.mode = StoreMode::Local;
    let store = crate::store::open(&config.store, &root).unwrap();
    (Hub::new(config, store), root)
}

fn kinds(value: &Value) -> BTreeSet<String> {
    value["files"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|file| file["kind"].as_str().map(str::to_owned))
        .collect()
}

#[test]
fn claude_paths_use_the_account_store_and_acpmux_store_when_available() {
    let m = meta(json!({
        "chatStore": "/tmp/claude-account",
        "agentSessionId": "claude-native",
        "watching": {"family": "claude", "file": "/tmp/native.jsonl"}
    }));
    let h = hub();
    let value = describe_meta(&h, &m);
    assert_eq!(value["hostId"], "local");
    assert_eq!(value["qualifiedSessionId"], "local/mux-session");
    let files = value["files"].as_array().unwrap();
    assert!(
        files.iter().any(
            |f| f == &json!({"kind":"claude_config","path":"/tmp/claude-account/.claude.json"})
        )
    );
    assert!(files.iter().any(
        |f| f == &json!({"kind":"claude_settings","path":"/tmp/claude-account/settings.json"})
    ));
    assert!(files.iter().any(|f| f == &json!({"kind":"transcript","path":"/tmp/native.jsonl"})));
    assert!(!kinds(&value).contains("codex_config"));
}

#[test]
fn codex_config_uses_the_recorded_root() {
    let m = meta(json!({
        "harness": "codex",
        "family": "codex",
        "harnessRoots": [{"harness":"codex","path":"/tmp/codex-account"}]
    }));
    let h = hub();
    let value = describe_meta(&h, &m);
    assert!(
        value["files"].as_array().unwrap().iter().any(|f| {
            f == &json!({"kind":"codex_config","path":"/tmp/codex-account/config.toml"})
        })
    );
}

#[test]
fn profile_specific_extra_roots_do_not_become_config_paths() {
    let m = meta(json!({
        "harness": "my-claude-profile",
        "family": "claude",
        "harnessRoots": [{"harness":"my-claude-profile","path":"/tmp/profile-sessions"}]
    }));
    let h = hub();
    let value = describe_meta(&h, &m);
    assert!(!kinds(&value).contains("claude_config"));
    assert!(!kinds(&value).contains("claude_settings"));
}

#[test]
fn no_transcript_is_reported_when_no_authoritative_path_is_known() {
    let h = hub();
    let m = meta(json!({}));
    assert!(!kinds(&describe_meta(&h, &m)).contains("transcript"));
}

#[test]
fn local_store_paths_are_named_without_reading_their_contents() {
    let (h, root) = local_hub();
    let m = meta(json!({"agentSessionId": "claude-native"}));
    let value = describe_meta(&h, &m);
    let files = value["files"].as_array().unwrap();
    let session_dir = root.join("sessions/mux-session");
    assert!(files.iter().any(|f| {
            f == &json!({"kind":"acpmux_session","path":session_dir.join("session.json").display().to_string()})
        }));
    assert!(files.iter().any(|f| {
            f == &json!({"kind":"acpmux_events","path":session_dir.join("events").display().to_string()})
        }));
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn every_non_unix_origin_is_refused() {
    assert!(require_local(Origin::Local).is_ok());
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let error = require_local(origin).unwrap_err();
        assert_eq!(
            error.data.as_ref().and_then(|data| data.get("reason")).and_then(Value::as_str),
            Some(LOCAL_ONLY_REASON)
        );
    }
}
