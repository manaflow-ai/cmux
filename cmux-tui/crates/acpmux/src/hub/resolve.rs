//! Part of `Hub`; see `hub/mod.rs`. What a new session resolves to before it
//! exists: its profile and defaults (`resolve_new`) and its draft meta.
//! Shared by `session/new` and the session pool, which keys and starts
//! hidden sessions from the same resolution.

use super::*;

use crate::config::check_preset_args;
use crate::config::folder_profiles;

impl Hub {
    /// What a new session for `harness`/`preset` resolves to: the profile,
    /// its defaults chain with the preset on top, the head and preset name.
    pub(super) fn resolve_new(
        &self,
        cfg: &crate::config::Config,
        harness: Option<String>,
        preset: &Option<String>,
        model: Option<&str>,
        remote: bool,
        cwd: Option<&Path>,
    ) -> Result<Resolved, RpcError> {
        let preset_cfg = match preset {
            Some(n) => Some(cfg.presets.get(n).cloned().ok_or_else(|| {
                RpcError::invalid_params(format!(
                    "unknown preset {n:?}; presets: {}",
                    if cfg.presets.is_empty() {
                        "none".to_owned()
                    } else {
                        cfg.presets.keys().cloned().collect::<Vec<_>>().join(", ")
                    }
                ))
            })?),
            None => None,
        };
        let head = harness
            .clone()
            .or_else(|| preset_cfg.as_ref().map(|p| p.harness.clone()))
            .or_else(|| cfg.default_harness.clone())
            .ok_or_else(|| {
                RpcError::invalid_params("no harnesses configured; add one to config.json")
            })?;
        // A folder profile (H4) answers only a name the catalog does not know.
        let folder =
            cwd.and_then(|cwd| folder_profiles::resolve_for_session(cfg, &head, cwd, remote));
        let (resolved, profile, mut d, folder_root) = match folder {
            Some(found) => {
                let (profile, root) = found.map_err(folder_refusal)?;
                let d = crate::config::SessionDefaults {
                    model: profile.model.clone(),
                    effort: profile.effort.clone(),
                    policy: profile.policy,
                    ..Default::default()
                };
                (head.clone(), profile, d, Some(root))
            }
            None => {
                let resolved = cfg.resolve_harness(&head).map_err(|e| {
                    RpcError::invalid_params(self.with_model_hint(cfg, &head, model, e))
                })?;
                if let Some(reason) = cfg.unavailable.get(&resolved) {
                    return Err(RpcError::invalid_params(format!(
                        "harness {resolved} is unavailable: {reason}"
                    )));
                }
                let profile = cfg.harnesses[&resolved].clone();
                let d = cfg.defaults_for(&resolved);
                (resolved, profile, d, None)
            }
        };
        if let Some(p) = &preset_cfg {
            if remote && p.shapes_command() {
                return Err(RpcError::invalid_params(format!(
                    "preset {:?} carries harness args or a system prompt, which a remote-origin session never starts with (remote chains build their settings from scratch)",
                    preset.as_deref().unwrap_or_default()
                )));
            }
            check_preset_args(profile.kind, &p.args).map_err(RpcError::invalid_params)?;
            d.overlay(&crate::config::SessionDefaults {
                model: p.model.clone(),
                effort: p.effort.clone(),
                policy: p.policy,
                prefer: vec![],
                env: p.env.clone(),
            });
        }
        Ok(Resolved {
            agent: resolved,
            profile,
            defaults: d,
            head,
            preset_name: preset.clone(),
            folder_root,
        })
    }
}

/// The profile a session's harness name runs at a spawn: the catalog's, else
/// an enabled folder profile for the session's folder (checked again at every
/// spawn: trust, the confirmed bytes, the folder, the origin).
pub(super) fn session_profile(
    cfg: &crate::config::Config,
    harness: &str,
    cwd: &Path,
    remote: bool,
) -> Result<HarnessProfile, String> {
    if let Some(p) = cfg.profile(harness) {
        return Ok(p.clone());
    }
    match folder_profiles::resolve_for_session(cfg, harness, cwd, remote) {
        Some(found) => found.map(|(profile, _)| profile).map_err(|e| e.message),
        None => Err(format!("unknown harness {harness:?}")),
    }
}

/// A folder profile refusal as session/new answers it: invalid params with
/// data {reason, harness, folder} when the app can act on it (its Trust
/// question or Enable harness sheet).
fn folder_refusal(refusal: folder_profiles::FolderRefusal) -> RpcError {
    let error = RpcError::invalid_params(refusal.message);
    match refusal.reason {
        Some(reason) => error
            .with_data(json!({"reason": reason, "harness": refusal.id, "folder": refusal.folder})),
        None => error,
    }
}

/// `Hub::resolve_new`: what a new session resolves to before it exists.
pub(super) struct Resolved {
    pub(super) agent: String,
    pub(super) profile: HarnessProfile,
    pub(super) defaults: crate::config::SessionDefaults,
    pub(super) head: String,
    pub(super) preset_name: Option<String>,
    /// The folder of a folder profile (H4): the session's cwd must be inside it.
    pub(super) folder_root: Option<PathBuf>,
}

/// The inputs of a new session's meta (`draft_meta`).
pub(super) struct Draft<'a> {
    pub(super) id: String,
    pub(super) agent: &'a str,
    pub(super) profile: &'a HarnessProfile,
    pub(super) family: &'a str,
    pub(super) preset: Option<String>,
    pub(super) model_request: Option<String>,
    pub(super) cwd: PathBuf,
    pub(super) agent_session_id: Option<String>,
    pub(super) policy: Option<PermissionPolicy>,
    pub(super) remote: bool,
}

/// A new session's meta, before it has a name.
pub(super) fn draft_meta(d: Draft<'_>) -> SessionMeta {
    let now = now_ms();
    SessionMeta {
        schema: META_SCHEMA.into(),
        id: d.id,
        name: String::new(),
        harness: d.agent.into(),
        harness_argv: d.profile.argv.clone(),
        family: Some(d.family.to_owned()),
        preset: d.preset,
        model_request: d.model_request,
        cwd: d.cwd,
        agent_session_id: d.agent_session_id,
        status: SessionStatus::Idle,
        created_at: now,
        updated_at: now,
        last_seq: 0,
        parent_id: None,
        fork_seq: None,
        agent_info: None,
        agent_capabilities: None,
        modes: None,
        config_options: None,
        models: None,
        permission_policy: d.policy.map(|p| p.to_string()),
        title: None,
        last_prompt: None,
        preview: None,
        event_count: 0,
        turn_count: 0,
        usage: None,
        permission_rules: None,
        tags: Default::default(),
        unread: false,
        last_turn: None,
        remote_origin: d.remote,
        session_env: Default::default(),
        harness_roots: vec![],
    }
}
