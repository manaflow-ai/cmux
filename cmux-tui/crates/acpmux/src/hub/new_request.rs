//! Part of `Hub`; see `hub/mod.rs`. What `session/new` carries
//! ([`NewRequest`]) and the free helpers `lifecycle.rs` uses.

use super::*;

/// The agent name, or `agent-N` for the first N not taken in `sessions`.
pub(super) fn unique_name_among(sessions: &HashMap<String, Arc<Session>>, agent: &str) -> String {
    let taken: Vec<String> = sessions.values().map(|s| s.meta().name).collect();
    for n in 0.. {
        let candidate = if n == 0 { agent.to_owned() } else { format!("{agent}-{n}") };
        if !taken.contains(&candidate) {
            return candidate;
        }
    }
    unreachable!()
}

/// Whether the harness takes its model on the command line or in env.
/// A declared model as `_acpmux/models` lists it: id, name, `declared`, and
/// the catalog fields its profile file gave (shortName, family, efforts…).
pub fn declared_model_json(
    model: &crate::config::DeclaredModel,
    meta: Option<&crate::config::ProfileMeta>,
) -> Value {
    let mut v = json!({"id": model.id(), "name": model.name(), "declared": true});
    if let Some(detail) = meta.and_then(|m| m.model_details.iter().find(|d| d.id == model.id()))
        && let (Some(out), Ok(Value::Object(extra))) =
            (v.as_object_mut(), serde_json::to_value(detail))
    {
        for (k, x) in extra {
            if k != "id" && k != "name" {
                out.insert(k, x);
            }
        }
    }
    v
}

/// `session/new` for a terminal harness: it runs in a terminal tab.
pub fn terminal_harness_refusal(name: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "harness.terminal: {name} is a terminal harness without ACP; open it with `cmux harness run {name}`"
    ))
    .with_data(json!({"reason": "harness.terminal", "harness": name}))
}

pub fn profile_takes_model_at_spawn(profile: &HarnessProfile) -> bool {
    // Claude Code takes `--model` at spawn (`claude_stdio::spawn_plan`).
    // Switching it after start with session/set_model makes Claude Code
    // check the model with the API first: with 16 sessions starting at
    // once that check took about 6 s per session (session/new p50 7.9 s,
    // 0.9-1.6 s without it) and sometimes failed ("Couldn't confirm
    // model"), so a new session never switches. A running session still
    // switches with session/set_model.
    profile.kind == crate::config::HarnessKind::ClaudeStdio
        || profile.argv.iter().any(|a| a.contains("${model}"))
        || profile.env.values().any(|v| v.contains("${model}"))
}

/// What `session/new` carries: `harness` is a family or profile name
/// (the head of `-m HEAD/MODEL`), `preset` a `presets` entry. Explicit
/// values win over the preset, which wins over the defaults chain.
#[derive(Debug, Clone, Default)]
pub struct NewRequest {
    pub harness: Option<String>,
    pub preset: Option<String>,
    pub name: Option<String>,
    /// None: the adopted session's recorded cwd, else the home directory.
    pub cwd: Option<PathBuf>,
    pub policy: Option<PermissionPolicy>,
    pub model: Option<String>,
    pub effort: Option<String>,
    /// Requested over a remote-origin connection (the WebSocket listener).
    pub remote: bool,
    /// A harness session to resume instead of starting a new one.
    pub adopt: Option<crate::adopt::AdoptRequest>,
    /// Per-session env (`session_env.rs`), already checked by the caller.
    pub env: std::collections::BTreeMap<String, String>,
    /// The session's cmux workspace (`session_env::workspace_id`), already
    /// checked by the caller.
    pub workspace_id: Option<String>,
    /// Keep the harness's own start mode (`start_mode.rs`): a handoff target
    /// of a source that is not in full access is never wider than it.
    pub keep_harness_mode: bool,
    /// The acpmux session whose agent asked for this one, as the connection
    /// proved it with its caller token (`Conn::caller`, never a request
    /// value), and never the person. A start that names no policy or mode
    /// inherits that session's, never wider (`start_mode.rs`, "Inherit").
    pub starter: Option<String>,
    /// A route (`routes.rs`) bound to this chat before its harness first
    /// starts (`_meta.acpmux.route`, unix socket only): the chat's model
    /// provider from its first turn. Checked by the caller as a route id.
    pub route: Option<String>,
    /// The new session is a sub-session (`hub/subsessions.rs`): its parent,
    /// short name and depth, checked against the parent's limits by the caller.
    pub subsession: Option<crate::store::SubsessionLink>,
    /// The session's place under the session that started it (`hub/lineage.rs`),
    /// already checked by the caller; None for a root.
    pub lineage: Option<crate::store::Lineage>,
    /// Claude Code built-in tools this chat never gets
    /// (`_meta.acpmux.disallowedTools`, checked by the caller): kept in its
    /// meta as `tool:<name>` rows that are off, so every start of its Claude
    /// Code passes `--disallowedTools <name>` (`tools.rs`).
    pub disallowed_tools: Vec<String>,
    /// A sub-session's folder as its start checked it (`subsession_guard.rs`): its harness
    /// spawns only while `cwd` still leads to that very folder.
    pub checked_cwd: Option<super::subsession_guard::CheckedFolder>,
}

/// Why the Claude conversation `sid` cannot be resumed on `profile` (None:
/// it can): it never finished a turn, or another profile ran it and this
/// profile's store (its CLAUDE_CONFIG_DIR) does not have it.
pub(super) fn claude_resume_refusal(
    meta: &SessionMeta,
    profile: &HarnessProfile,
    sid: &str,
) -> Option<&'static str> {
    if meta.claude_unstored {
        return Some("never finished a turn");
    }
    let ran_elsewhere = meta.claude_profile.as_deref().is_some_and(|p| p != meta.harness);
    if ran_elsewhere {
        let store = meta.claude_store(&profile.env);
        if !crate::adopt::claude_session_exists(&store, sid) {
            return Some("is not in this profile's Claude store");
        }
    }
    None
}
