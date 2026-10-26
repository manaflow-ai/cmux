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
        let (resolved, mut profile, mut d, folder_root) = match folder {
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
        if remote {
            admit_remote_profile(cfg, &resolved, &mut profile, &d.env)?;
        }
        Ok(Resolved {
            agent: resolved,
            profile,
            defaults: d,
            head,
            preset_name: preset.clone(),
            folder_root,
            preset_digest: preset_cfg.as_ref().and_then(|p| p.approval_digest()),
        })
    }

    /// Resolve exactly what `new_session` will run while the remote request
    /// is still in admission, before a session or child process exists.
    pub(crate) async fn preflight_remote_new(
        &self,
        harness: Option<String>,
        preset: Option<String>,
        model: Option<String>,
        cwd: Option<PathBuf>,
    ) -> Result<(String, bool), RpcError> {
        self.wait_startup().await;
        let cfg = self.config.read().await;
        let resolved =
            self.resolve_new(&cfg, harness, &preset, model.as_deref(), true, cwd.as_deref())?;
        let family = crate::config::derive_family(&resolved.agent, &resolved.profile);
        let any_mode = crate::codex_app_server::is_profile_launch(&resolved.profile.argv);
        Ok((family, any_mode))
    }
}

/// A remote request never chooses argv[0] with cwd/model expansion or the
/// child working directory. Freeze a bare PATH program or configured
/// absolute path to its canonical absolute executable before any spawn.
pub(super) fn fix_remote_executable(profile: &mut HarnessProfile) -> Result<(), RpcError> {
    let Some(program) = profile.argv.first() else { return Err(remote_executable_refused()) };
    profile.argv[0] = remote_executable(program)?;
    Ok(())
}

/// Canonicalize one final remote program. This runs both on profile argv0
/// and after any launcher (CODEX_PATH/subrouter) substitutes another binary.
pub(super) fn remote_executable(program: &str) -> Result<String, RpcError> {
    let path = Path::new(program);
    if program.contains("${")
        || program.starts_with("~/")
        || (!path.is_absolute() && (program.contains('/') || program.contains('\\')))
    {
        return Err(remote_executable_refused());
    }
    let selected = if path.is_absolute() {
        path.to_path_buf()
    } else {
        crate::config::which(program).map(PathBuf::from).ok_or_else(remote_executable_refused)?
    };
    let selected = std::fs::canonicalize(selected).map_err(|_| remote_executable_refused())?;
    if !selected.is_file() || !selected.is_absolute() {
        return Err(remote_executable_refused());
    }
    Ok(selected.to_string_lossy().into_owned())
}

pub(super) fn refuse_remote_cwd_executable(program: &str, cwd: &Path) -> Result<(), RpcError> {
    let program = Path::new(program);
    let cwd = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    if program.starts_with(cwd) {
        return Err(remote_executable_refused());
    }
    Ok(())
}

fn remote_executable_refused() -> RpcError {
    RpcError::invalid_params(
        "this harness has no reviewed asking mode for a remote WebSocket connection",
    )
    .with_data(json!({"reason": "remote.executable_refused"}))
}

fn remote_launch_shape_refused() -> RpcError {
    remote_executable_refused()
}

/// The request's cwd and model are data passed to a reviewed agent, never
/// pieces of its process command or environment. Local sessions retain the
/// legacy expansion behavior.
fn refuse_remote_launch_shape<'a>(
    values: impl IntoIterator<Item = &'a String>,
) -> Result<(), RpcError> {
    if values.into_iter().any(|value| value.contains("${cwd}") || value.contains("${model}")) {
        return Err(remote_launch_shape_refused());
    }
    Ok(())
}

pub(super) fn admit_remote_profile(
    cfg: &crate::config::Config,
    name: &str,
    profile: &mut HarnessProfile,
    defaults_env: &std::collections::BTreeMap<String, String>,
) -> Result<(), RpcError> {
    refuse_remote_launch_shape(
        profile.argv.iter().chain(profile.env.values()).chain(defaults_env.values()),
    )?;
    let effective_codex = crate::codex_app_server::is_profile_launch(&profile.argv)
        .then(|| profile.env.get("CODEX_PATH").or_else(|| defaults_env.get("CODEX_PATH")))
        .flatten()
        .filter(|program| !program.is_empty());
    if let Some(program) = effective_codex {
        remote_executable(program)?;
    } else {
        fix_remote_executable(profile)?;
    }
    crate::web_modes::remote_start_for_config(cfg, name, profile).map(|_| ()).map_err(|_| {
        RpcError::invalid_params(
            "this harness has no reviewed asking mode for a remote WebSocket connection",
        )
        .with_data(json!({"reason": "remote.mode_not_asking"}))
    })
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
    session_profile_checked(cfg, harness, cwd, remote).map_err(|e| e.message)
}

/// `session_profile` with the refusal's reason (`data.reason`) kept, for a
/// caller that records or answers it: a held prompt whose agent may not start
/// ends with the reason (`queue.rs` `resume_queues`).
pub(super) fn session_profile_checked(
    cfg: &crate::config::Config,
    harness: &str,
    cwd: &Path,
    remote: bool,
) -> Result<HarnessProfile, RpcError> {
    let profile = if let Some(p) = cfg.profile(harness) {
        p.clone()
    } else {
        match folder_profiles::resolve_for_session(cfg, harness, cwd, remote) {
            Some(found) => found.map(|(profile, _)| profile).map_err(folder_refusal),
            None => Err(RpcError::invalid_params(format!("unknown harness {harness:?}"))),
        }?
    };
    if remote {
        crate::web_modes::remote_start_for_config(cfg, harness, &profile).map_err(|_| {
            RpcError::invalid_params(
                "this harness has no reviewed asking mode for a remote WebSocket connection",
            )
            .with_data(json!({"reason": "remote.mode_not_asking", "harness": harness}))
        })?;
    }
    Ok(profile)
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
    /// The approval digest of the preset contents read here (`hub/start_gate/preset_bind.rs`).
    pub(super) preset_digest: Option<String>,
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
        steering: false,
        html_previews: false,
        modes: None,
        mode_set_by_cmux: None,
        config_options: None,
        models: None,
        permission_policy: d.policy.map(|p| p.to_string()),
        title: None,
        title_source: None,
        title_prompt: None,
        title_asking: false,
        title_failures: 0,
        title_thin: false,
        last_prompt: None,
        preview: None,
        event_count: 0,
        turn_count: 0,
        usage: None,
        context_breakdown: None,
        usage_limits: None,
        available_commands: None,
        goal: None,
        permission_rules: None,
        tags: Default::default(),
        unread: false,
        claude_unstored: false,
        claude_profile: None,
        last_turn: None,
        remote_origin: d.remote,
        session_env: Default::default(),
        workspace_id: None,
        chat_store: None,
        adopted_cwd: None,
        harness_roots: vec![],
        watching: None,
        composer_draft: None,
        preset_mode_approval: None,
        bookmarks: Default::default(),
        tools: Default::default(),
        // Read off the async runtime by `session/new` (`adoption::start_folder`).
        totals: None,
        harness_cost_usd: None,
        pull_requests: vec![],
        git_branch: None,
        git_head: None,
        worktree: None,
        subsession: None,
        subsession_limits: Default::default(),
    }
}
