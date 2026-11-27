//! Part of `Hub`; see `hub/mod.rs`. What `session/new` carries
//! ([`NewRequest`]) and the free helpers `lifecycle.rs` uses.

use super::*;

/// The agent name, or `agent-N` for the first N not taken in `sessions`.
pub(super) fn unique_name_among(
    sessions: &HashMap<String, Arc<Session>>,
    evicted: &[String],
    agent: &str,
) -> String {
    let mut taken: Vec<String> =
        sessions.values().map(|s| s.read_meta(|m| m.name.clone())).collect();
    taken.extend_from_slice(evicted);
    for n in 0.. {
        let candidate = if n == 0 { agent.to_owned() } else { format!("{agent}-{n}") };
        if !taken.contains(&candidate) {
            return candidate;
        }
    }
    unreachable!()
}

/// The `_meta.acpmux.ifNameTaken` value that keeps a taken name with a `-N` suffix.
pub const SUFFIX_TAKEN_NAME: &str = "suffix";

/// `name` when no session in `sessions` has it, else `name-N` for the first N from 2 not taken:
/// the requested name kept, never the agent's.
pub(super) fn suffixed_name_among(
    sessions: &HashMap<String, Arc<Session>>,
    evicted: &[String],
    name: &str,
) -> String {
    let mut taken: Vec<String> =
        sessions.values().map(|s| s.read_meta(|m| m.name.clone())).collect();
    taken.extend_from_slice(evicted);
    suffixed_name(&taken, name)
}

/// [`suffixed_name_among`] over the names `taken`.
pub fn suffixed_name(taken: &[String], name: &str) -> String {
    if !taken.iter().any(|t| t == name) {
        return name.to_owned();
    }
    (2..)
        .map(|n| format!("{name}-{n}"))
        .find(|candidate| !taken.contains(candidate))
        .unwrap_or_else(|| name.to_owned())
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
    /// `_meta.acpmux.ifNameTaken: "suffix"`: a `name` another session here has is kept with the
    /// first free `-N` suffix (`NAME-2`, `NAME-3`...) instead of refused. A start placed on or
    /// forwarded to this machine asks for it, so it keeps the name it was given and never falls
    /// back to the agent's (`codex`); its answer reports the name it got.
    pub suffix_taken_name: bool,
    /// None: the adopted session's recorded cwd, else the home directory.
    pub cwd: Option<PathBuf>,
    pub policy: Option<PermissionPolicy>,
    pub model: Option<String>,
    pub effort: Option<String>,
    /// Requested over a remote-origin connection (the WebSocket listener).
    pub remote: bool,
    /// Its caller asked for the VM boundary (`vm_boundary.rs`): a remote
    /// chain's Claude Code here runs without the platform sandbox. Only with
    /// `remote`; checked by the caller (`vm_boundary::asked`).
    pub vm_boundary: bool,
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
    /// Who creates it (`hub/created_by.rs`), decided by the caller from the connection.
    pub created_by: Option<crate::store::CreatedBy>,
    /// Claude Code built-in tools this chat never gets
    /// (`_meta.acpmux.disallowedTools`, checked by the caller): kept in its
    /// meta as `tool:<name>` rows that are off, so every start of its Claude
    /// Code passes `--disallowedTools <name>` (`tools.rs`).
    pub disallowed_tools: Vec<String>,
    /// A sub-session's folder as its start checked it (`subsession_guard.rs`): its harness
    /// spawns only while `cwd` still leads to that very folder.
    pub checked_cwd: Option<super::subsession_guard::CheckedFolder>,
    /// Folders the chat sees beside its own (`additional_dirs.rs`), already checked by the
    /// caller.
    pub additional_directories: Vec<PathBuf>,
    /// When the chat's agent may stop (`_meta.acpmux.stopCondition`, `stop_condition.rs`),
    /// already checked by the caller; None for none.
    pub stop_condition: Option<String>,
    /// `_meta.acpmux.restricted` (`restricted.rs`): read-only work in a folder the person chose
    /// not to trust; its policy was already held to review by the caller.
    pub restricted: bool,
    /// The person asks for this chat (`Session::person`): this host's app, or a connection that
    /// proved it is the person (`server/requests.rs` `person_asks`), never an agent's or a lane's
    /// create. Its start waits as long as its harness works on it (`lifecycle.rs`).
    pub person: bool,
    /// The create asked to wait on its harness (`_meta.acpmux.waitStart`, `Session::wait_start`):
    /// never honored from an agent's, a lane's or a remote connection (`server/requests.rs`).
    pub wait_start: bool,
    /// `_meta.acpmux.throwaway` (`SessionMeta::throwaway`): its creator purges it
    /// after its work.
    pub throwaway: bool,
    /// `_meta.acpmux.requireAsking` (`require_asking.rs`): the start runs only on a harness the
    /// asking table lists, as it resolves it, and its policy fails the start where it is not kept.
    pub require_asking: bool,
    /// The owner's Cloud credential for this chat's agent (`_meta.acpmux.credentials`, unix
    /// socket only, `agent_credentials.rs`): kept on the session in memory, never in its meta.
    pub credential: Option<crate::agent_credentials::AgentCredential>,
    /// The creator's key (`_meta.acpmux.createKey`, local socket only, `create_key.rs`): a
    /// create sent again with it, after a restart cut its reply, gets the session it made.
    pub create_key: Option<String>,
    /// `_meta.acpmux.placedBy` (`SessionMeta::placed_by`): only `autoCloud` is kept.
    pub placed_by: Option<String>,
}

/// Why the Claude conversation `sid` cannot be resumed on `profile` (None:
/// it can): it never finished a turn, or the store this profile resumes from
/// (its CLAUDE_CONFIG_DIR) does not have it.
///
/// The store is checked whoever ran the chat last. A conversation can leave
/// the store a profile of its own never left: the Chief compactor deletes a
/// transcript it folded, and a pruned, rotated or deleted store loses the
/// rest. `--resume` on one of those fails every turn of that session forever
/// (`No conversation found with session ID`, no turn, no self-healing), while
/// a refusal here costs one fresh conversation with the transcript restored
/// from acpmux's own log (`lifecycle.rs`).
pub(super) fn claude_resume_refusal(
    meta: &SessionMeta,
    profile: &HarnessProfile,
    sid: &str,
) -> Option<&'static str> {
    if meta.claude_unstored {
        return Some("never finished a turn");
    }
    let store = meta.claude_store(&profile.env);
    if !crate::adopt::claude_session_exists_near(&store, sid, &meta.cwd) {
        // Which store it is missing from, so the log and the `resume_failed`
        // row read as what happened.
        let ran_elsewhere = meta.claude_profile.as_deref().is_some_and(|p| p != meta.harness);
        return Some(if ran_elsewhere {
            "is not in this profile's Claude store"
        } else {
            "is no longer in Claude's store"
        });
    }
    None
}

#[cfg(test)]
#[path = "claude_resume_tests.rs"]
mod claude_resume_tests;
