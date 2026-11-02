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
use cmux_json::JsonSet as _;

/// The keys a session's env may set. Every key added here needs a comment
/// with its reason; never a variable that changes what runs or where it
/// connects (PATH, DYLD_*, LD_*, NODE_OPTIONS, *_BASE_URL, HOME,
/// CLAUDE_CONFIG_DIR, CODEX_HOME, sockets).
pub const ALLOWED_KEYS: &[&str] = &[
    // The cmux workspace this session's agent works in, so `cmux` calls and
    // agent hooks inside it target that workspace (the same variable a cmux
    // terminal carries). Validated as a workspace id.
    "CMUX_WORKSPACE_ID",
    // A Chief turn's seal (optchat-chief chief_profile.rs TURN_KEY_ENV): the
    // Chief host gives it to its own turn session only, never a subagent's,
    // so its tools socket answers the `chiefs` tool (make and edit other
    // Chiefs) to that turn alone. A secret, not a route: it changes nothing
    // about what runs or where it connects. Validated as 64 hex digits.
    "OPTCHAT_TURN_SEAL",
];

/// Most keys one request may set.
pub const MAX_KEYS: usize = 8;
/// Longest value, in bytes.
pub const MAX_VALUE_BYTES: usize = 256;

fn refusal(reason: &str, message: String, key: Option<&str>) -> RpcError {
    let mut data = json!({"reason": reason});
    if let Some(key) = key {
        data.set("key", json!(key));
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
pub(crate) fn is_workspace_id(value: &str) -> bool {
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
        if key == "OPTCHAT_TURN_SEAL"
            && !(value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit()))
        {
            return Err(refusal(
                "env.value_refused",
                format!("env.{key} must be 64 hex digits"),
                Some(key),
            ));
        }
        env.insert(key.clone(), value.to_owned());
    }
    Ok(env)
}

/// The session's cmux workspace on `session/new` and `session/fork`
/// (cx-ncc.5), from the typed `_meta.acpmux.workspaceId` and the request's
/// session `env` (already [`parse`]d):
///
/// - `workspaceId` a UUID: that id, lowercased; anything else but null is
///   refused (`workspace.value_refused`).
/// - `workspaceId` absent or null: the env's `CMUX_WORKSPACE_ID` (validated
///   as a UUID by [`parse`]), lowercased, so a client that names the
///   workspace only there (the Chief's subagents) gets it too; `None` when
///   the env has none either (a fork then keeps its parent's).
/// - Both, naming two workspaces (after lowercasing): refused
///   (`workspace.mismatch`).
///
/// It picks the computer use display in per-workspace display mode
/// (`agent_displays.rs`); it is not env and reaches no agent process. Any
/// origin may send `workspaceId` (only the unix socket may send an env).
pub fn workspace_id(
    meta: Option<&Value>,
    env: &BTreeMap<String, String>,
) -> Result<Option<String>, RpcError> {
    let typed = match meta.and_then(|m| m.get("workspaceId")) {
        None | Some(Value::Null) => None,
        Some(Value::String(id)) if is_workspace_id(id) => Some(id.to_ascii_lowercase()),
        Some(_) => {
            return Err(refusal(
                "workspace.value_refused",
                "workspaceId must be a workspace id (a UUID)".to_owned(),
                None,
            ));
        }
    };
    let from_env = env.get("CMUX_WORKSPACE_ID").map(|id| id.to_ascii_lowercase());
    match (typed, from_env) {
        (Some(typed), Some(from_env)) if typed != from_env => Err(refusal(
            "workspace.mismatch",
            "workspaceId and env.CMUX_WORKSPACE_ID name different workspaces".to_owned(),
            None,
        )),
        (typed, from_env) => Ok(typed.or(from_env)),
    }
}

/// Keys whose value is a secret: never shown back (`_acpmux/info`).
const SECRET_KEYS: &[&str] = &["OPTCHAT_TURN_SEAL"];

/// The session env as `_acpmux/info` shows it: a secret's value is hidden.
pub fn shown(env: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    env.iter()
        .map(|(k, v)| {
            let v =
                if SECRET_KEYS.contains(&k.as_str()) { "(hidden)".to_owned() } else { v.clone() };
            (k.clone(), v)
        })
        .collect()
}

/// Whether a request carries a session env at all (any non-null `env`).
pub fn present(meta: Option<&Value>) -> bool {
    meta.and_then(|m| m.get("env")).is_some_and(|v| !v.is_null())
}
