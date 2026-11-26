//! Metadata-only paths for the focused agent session (`_acpmux/session_files`).
//!
//! This surface is deliberately local Unix-socket only. Paths are derived by the
//! daemon that owns the session, so the app never reconstructs a Claude/Codex
//! home from its own environment or accidentally reads a same-named local file
//! for a remote chat. The reply contains no file contents, environment values or
//! credentials.

use super::Origin;
use crate::hub::{Hub, Session};
use crate::rpc::RpcError;
use crate::session_identity::LOCAL_HOST_ID;
use crate::store::SessionMeta;
use cmux_chat_index::{AdapterKind, ChatKey};
use serde::Serialize;
use serde_json::{Value, json};
use std::path::PathBuf;

pub(crate) const CAPABILITY: &str = "session-files-v1";
pub(crate) const LOCAL_ONLY_REASON: &str = "session_files.local_only";

/// One named path in the reply. `kind` is a stable wire enum; clients must
/// preserve unknown kinds for forward compatibility.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct SessionFile {
    kind: &'static str,
    path: String,
}

/// The metadata contract consumed by native palette copy actions.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct SessionFiles {
    schema: &'static str,
    /// `local` is the acpmux route identity, not a human hostname.
    host_id: &'static str,
    qualified_session_id: String,
    session_id: String,
    name: String,
    harness: String,
    family: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_session_id: Option<String>,
    cwd: String,
    files: Vec<SessionFile>,
}

/// Refuse the method before resolving a session for every non-Unix origin.
/// This is intentionally a distinct reason from a missing session or a daemon
/// that predates the capability, so the native caller can report unavailable
/// honestly instead of presenting an empty file list.
pub(crate) fn require_local(origin: Origin) -> Result<(), RpcError> {
    if origin == Origin::Local {
        return Ok(());
    }
    Err(RpcError::new(-32601, "_acpmux/session_files is accepted only over the local unix socket")
        .with_data(json!({"reason": LOCAL_ONLY_REASON, "capability": CAPABILITY})))
}

/// Build the reply from daemon-owned metadata. No filesystem reads occur.
pub(crate) fn describe(hub: &Hub, session: &Session) -> Value {
    let meta = session.meta();
    describe_meta(hub, &meta)
}

fn describe_meta(hub: &Hub, meta: &SessionMeta) -> Value {
    let files = paths(hub, meta)
        .into_iter()
        .map(|(kind, path)| SessionFile { kind, path: path.to_string_lossy().into_owned() })
        .collect();
    serde_json::to_value(SessionFiles {
        schema: CAPABILITY,
        host_id: LOCAL_HOST_ID,
        qualified_session_id: format!("{LOCAL_HOST_ID}/{}", meta.id),
        session_id: meta.id.clone(),
        name: meta.name.clone(),
        harness: meta.harness.clone(),
        family: meta.family.clone(),
        agent_session_id: meta.agent_session_id.clone(),
        cwd: meta.cwd.to_string_lossy().into_owned(),
        files,
    })
    .unwrap_or(Value::Null)
}

/// Return each known path in stable order. Inputs are all daemon-owned: the
/// session record, the chat index, and the store directory. A path is omitted
/// when the daemon cannot prove its owning root or transcript.
fn paths(hub: &Hub, meta: &SessionMeta) -> Vec<(&'static str, PathBuf)> {
    let mut out = Vec::new();
    if let Some(root) = harness_store_root(meta) {
        match meta.family.as_deref() {
            Some("claude") => {
                out.push(("claude_config", root.join(".claude.json")));
                out.push(("claude_settings", root.join("settings.json")));
            }
            Some("codex") => out.push(("codex_config", root.join("config.toml"))),
            _ => {}
        }
    }
    if let Some(transcript) = transcript_path(hub, meta) {
        out.push(("transcript", transcript));
    }
    if let Some(dir) = hub.session_dir(&meta.id) {
        out.push(("acpmux_session", dir.join("session.json")));
        out.push(("acpmux_events", dir.join("events")));
    }
    out
}

/// The effective Claude/Codex store. `chat_store` is authoritative for an
/// account override. Otherwise `harness_roots` records the profile env at the
/// last spawn (`claude` roots end in `projects`; Codex roots are the home).
fn harness_store_root(meta: &SessionMeta) -> Option<PathBuf> {
    if let Some(path) = meta.chat_store.as_ref().filter(|p| p.is_absolute()) {
        return Some(path.clone());
    }
    let family = meta.family.as_deref()?;
    let profile = |harness: &str| {
        meta.harness_roots.iter().find(|root| root.harness == harness).map(|root| root.path.clone())
    };
    let path = match family {
        "claude" => {
            // Only the built-in adapter root proves the Claude config dir.
            // A custom `sessions.roots` entry is indexed under the profile id
            // but may point anywhere and must not be treated as ~/.claude.
            let candidate = profile("claude-code").or_else(|| profile("claude"))?;
            if candidate.file_name().is_some_and(|name| name == "projects") {
                candidate.parent()?.to_path_buf()
            } else {
                candidate
            }
        }
        // As above, ignore profile-specific extra roots: only the adapter's
        // CODEX_HOME root is authoritative for config.toml.
        "codex" => profile("codex")?,
        _ => return None,
    };
    path.is_absolute().then_some(path)
}

fn transcript_path(hub: &Hub, meta: &SessionMeta) -> Option<PathBuf> {
    if let Some(path) = meta.watching.as_ref().map(|watching| watching.file.clone()) {
        return path.is_absolute().then_some(path);
    }
    let agent_session_id = meta.agent_session_id.as_deref()?;
    let adapter = match meta.family.as_deref()? {
        "claude" => AdapterKind::ClaudeCode,
        "codex" => AdapterKind::Codex,
        _ => return None,
    };
    let key = ChatKey { harness: adapter, session_id: agent_session_id.to_owned() };
    hub.chat_index()?.get(&key).map(|chat| chat.entry.source_path).filter(|p| p.is_absolute())
}

#[cfg(test)]
mod tests {
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
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(config, store)
    }

    fn local_hub() -> (std::sync::Arc<Hub>, std::path::PathBuf) {
        let root =
            std::env::temp_dir().join(format!("acpmux-session-files-{}", std::process::id()));
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
        assert!(files.iter().any(
            |f| f == &json!({"kind":"claude_config","path":"/tmp/claude-account/.claude.json"})
        ));
        assert!(
            files.iter().any(|f| f
                == &json!({"kind":"claude_settings","path":"/tmp/claude-account/settings.json"}))
        );
        assert!(
            files.iter().any(|f| f == &json!({"kind":"transcript","path":"/tmp/native.jsonl"}))
        );
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
        assert!(value["files"].as_array().unwrap().iter().any(|f| {
            f == &json!({"kind":"codex_config","path":"/tmp/codex-account/config.toml"})
        }));
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
}
