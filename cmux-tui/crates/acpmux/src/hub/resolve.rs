//! Part of `Hub`; see `hub/mod.rs`. What a new session resolves to before it
//! exists: its profile and defaults (`resolve_new`) and its draft meta.
//! Shared by `session/new` and the session pool, which keys and starts
//! hidden sessions from the same resolution.

use super::*;

use crate::config::check_preset_args;

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
        let resolved = cfg
            .resolve_harness(&head)
            .map_err(|e| RpcError::invalid_params(self.with_model_hint(cfg, &head, model, e)))?;
        if let Some(reason) = cfg.unavailable.get(&resolved) {
            return Err(RpcError::invalid_params(format!(
                "harness {resolved} is unavailable: {reason}"
            )));
        }
        let profile = cfg.harnesses[&resolved].clone();
        let mut d = cfg.defaults_for(&resolved);
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
        Ok(Resolved { agent: resolved, profile, defaults: d, head, preset_name: preset.clone() })
    }
}

/// `Hub::resolve_new`: what a new session resolves to before it exists.
pub(super) struct Resolved {
    pub(super) agent: String,
    pub(super) profile: HarnessProfile,
    pub(super) defaults: crate::config::SessionDefaults,
    pub(super) head: String,
    pub(super) preset_name: Option<String>,
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
    }
}
