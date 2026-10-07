//! Per-session env (`_meta.acpmux.env` on `session/new` and `session/fork`):
//! a few variables a client sets for ONE session, where a preset's env is
//! shared by every session started from it. The Chief gives each subagent
//! `CMUX_WORKSPACE_ID` of its own workspace this way (cx-ebm.40).
//!
//! Only the unix socket may send it (`remote_guard.rs` refuses every other
//! origin with `env.origin_refused`). Only keys in [`ALLOWED_KEYS`] pass
//! (`env.key_refused`, naming the key); there is no prefix rule, because some
//! `CMUX_` variables name sockets. It is merged over the preset env, recorded
//! in the session meta (so a restart and a respawn keep it), and never copied
//! to a fork or a handoff: those set it again or run without it.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use crate::rpc::RpcError;

/// The keys a session's env may set. Every key added here needs a comment
/// with its reason; never a variable that changes what runs or where it
/// connects (PATH, DYLD_*, LD_*, NODE_OPTIONS, *_BASE_URL, HOME,
/// CLAUDE_CONFIG_DIR, CODEX_HOME, sockets).
pub const ALLOWED_KEYS: &[&str] = &[
    // The cmux workspace this session's agent works in, so `cmux` calls and
    // agent hooks inside it target that workspace (the same variable a cmux
    // terminal carries). Validated as a workspace id.
    "CMUX_WORKSPACE_ID",
];

/// Most keys one request may set.
pub const MAX_KEYS: usize = 8;
/// Longest value, in bytes.
pub const MAX_VALUE_BYTES: usize = 256;

fn refusal(reason: &str, message: String, key: Option<&str>) -> RpcError {
    let mut data = json!({"reason": reason});
    if let Some(key) = key {
        data["key"] = json!(key);
    }
    RpcError::invalid_params(message).with_data(data)
}

/// The refusal for a session env sent over any connection but the unix socket.
pub fn origin_refused() -> RpcError {
    refusal(
        "env.origin_refused",
        "a session env is accepted only over the local unix socket".to_owned(),
        None,
    )
}

/// A workspace id: a UUID (8-4-4-4-12 hex digits, either case).
fn is_workspace_id(value: &str) -> bool {
    let groups: Vec<&str> = value.split('-').collect();
    groups.len() == 5
        && groups
            .iter()
            .zip([8, 4, 4, 4, 12])
            .all(|(g, n)| g.len() == n && g.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// The session env of `meta` (`_meta.acpmux.env`): empty when absent or
/// null, else every key allowed and every value valid.
pub fn parse(meta: Option<&Value>) -> Result<BTreeMap<String, String>, RpcError> {
    let raw = match meta.and_then(|m| m.get("env")) {
        None | Some(Value::Null) => return Ok(BTreeMap::new()),
        Some(Value::Object(map)) => map,
        Some(_) => {
            return Err(refusal(
                "env.value_refused",
                "env must be an object of strings".to_owned(),
                None,
            ));
        }
    };
    if raw.len() > MAX_KEYS {
        return Err(refusal(
            "env.value_refused",
            format!("env takes at most {MAX_KEYS} keys"),
            None,
        ));
    }
    let mut env = BTreeMap::new();
    for (key, value) in raw {
        if !ALLOWED_KEYS.contains(&key.as_str()) {
            return Err(refusal(
                "env.key_refused",
                format!(
                    "env key {key} is not one a session may set (allowed: {})",
                    ALLOWED_KEYS.join(", ")
                ),
                Some(key),
            ));
        }
        let Some(value) = value.as_str() else {
            return Err(refusal(
                "env.value_refused",
                format!("env.{key} must be a string"),
                Some(key),
            ));
        };
        if value.len() > MAX_VALUE_BYTES || value.contains(['\0', '\n', '\r']) {
            return Err(refusal(
                "env.value_refused",
                format!("env.{key} must be at most {MAX_VALUE_BYTES} bytes with no NUL or newline"),
                Some(key),
            ));
        }
        if key == "CMUX_WORKSPACE_ID" && !is_workspace_id(value) {
            return Err(refusal(
                "env.value_refused",
                format!("env.{key} must be a workspace id (a UUID)"),
                Some(key),
            ));
        }
        env.insert(key.clone(), value.to_owned());
    }
    Ok(env)
}

/// Whether a request carries a session env at all (any non-null `env`).
pub fn present(meta: Option<&Value>) -> bool {
    meta.and_then(|m| m.get("env")).is_some_and(|v| !v.is_null())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_ids() {
        assert!(is_workspace_id("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"));
        assert!(is_workspace_id("0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"));
        assert!(!is_workspace_id("0a1b2c3d4e5f4a6b8c7d9e0f1a2b3c4d"));
        assert!(!is_workspace_id("../../etc"));
        assert!(!is_workspace_id("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4z"));
    }

    #[test]
    fn the_session_env_survives_the_store() {
        let mut meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "s", "name": "n", "harness": "fake",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        assert!(meta.session_env.is_empty(), "older metas read without one");
        meta.session_env
            .insert("CMUX_WORKSPACE_ID".into(), "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d".into());
        let back: crate::store::SessionMeta =
            serde_json::from_value(serde_json::to_value(&meta).unwrap()).unwrap();
        assert_eq!(back.session_env, meta.session_env);
    }

    #[test]
    fn too_many_keys() {
        let mut env = serde_json::Map::new();
        for i in 0..=MAX_KEYS {
            env.insert(format!("K{i}"), json!("v"));
        }
        let meta = json!({"env": env});
        let err = parse(Some(&meta)).unwrap_err();
        assert_eq!(err.data.unwrap()["reason"], "env.value_refused");
    }
}
