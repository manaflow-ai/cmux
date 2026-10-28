//! Part of `Hub`; see `hub/mod.rs`. The harness command line a session
//! spawns with: its profile, its preset's env, args and system prompt file.

use super::*;
use crate::no_panic::JsonExt;

use crate::config::check_preset_args;

impl Hub {
    /// `session/new` or `session/load` params for acpmux session `id`'s ACP
    /// harness: its folder and cmux's MCP servers (agent_tools.rs), none for
    /// a remote origin or an isolated profile.
    pub(super) fn acp_params(
        &self,
        id: &str,
        meta: &SessionMeta,
        profile: &HarnessProfile,
        session_id: Option<&str>,
        child: &crate::agent::ChildAgent,
    ) -> Value {
        let all =
            crate::agent_tools::lists_all_tools(&meta.harness, profile, &profile.env, &meta.cwd);
        // A fork through this child asks for the same list (`fork.rs`).
        child.all_tools.store(all, std::sync::atomic::Ordering::Relaxed);
        let servers =
            crate::agent_tools::acp_servers_for(meta.remote_origin, &profile.env, id, all);
        let mut params = json!({"cwd": meta.cwd, "mcpServers": servers});
        if let Some(id) = session_id {
            params.set("sessionId", json!(id));
        }
        params
    }

    /// The profile as it is spawned for this session: family and profile
    /// default env underneath the profile's own, the preset's env on top,
    /// then `${cwd}`, `${home}`, `${model}` and a leading `~/` expanded in
    /// every env value and argv word. The preset's args (checked against the
    /// allowlist again) and its system prompt file (checked against its
    /// recorded sha256) are appended here, at every spawn; a remote-origin
    /// session never gets either. The approval digest of the preset contents
    /// read here goes with the profile, and only a cold start records it
    /// (`Hub::ensure_child`, `hub/start_gate/preset_bind.rs`): a request that
    /// finds the agent running spawns nothing and records nothing.
    pub(super) async fn spawn_profile(
        &self,
        session: &Session,
        profile: &HarnessProfile,
        defaults_env: &std::collections::BTreeMap<String, String>,
    ) -> Result<Spawn, RpcError> {
        // A fork resumes its parent's conversation: it runs in the parent's folder.
        let forking = session.fork_from.lock().unwrap_or_else(|e| e.into_inner()).is_some();
        let meta = session.meta();
        let opencode = super::policy_mode::is_opencode(&meta, profile);
        let (profile, preset_digest, account_home) =
            self.spawn_profile_read(&meta, forking, profile, defaults_env).await?;
        Ok(Spawn { profile, preset_digest, account_home, opencode })
    }

    /// `spawn_profile` for a session's meta, also before the session exists
    /// (the session pool keys and starts hidden sessions with it).
    pub(super) async fn spawn_profile_for(
        &self,
        meta: &SessionMeta,
        profile: &HarnessProfile,
        defaults_env: &std::collections::BTreeMap<String, String>,
    ) -> Result<HarnessProfile, RpcError> {
        self.spawn_profile_read(meta, false, profile, defaults_env).await.map(|(p, ..)| p)
    }

    /// `spawn_profile_for`, and the approval digest of the preset contents
    /// it read (under the one config lock it read them with).
    async fn spawn_profile_read(
        &self,
        meta: &SessionMeta,
        forking: bool,
        profile: &HarnessProfile,
        defaults_env: &std::collections::BTreeMap<String, String>,
    ) -> Result<(HarnessProfile, Option<String>, Option<std::path::PathBuf>), RpcError> {
        let mut p = profile.clone();
        let mut digest = None;
        for (k, v) in defaults_env {
            p.env.entry(k.clone()).or_insert_with(|| v.clone());
        }
        let mut prompt_file = None;
        {
            let cfg = self.config.read().await;
            if let Some(name) = &meta.preset
                && let Some(preset) = cfg.presets.get(name)
            {
                digest = preset.approval_digest();
                if meta.remote_origin && preset.shapes_command() {
                    return Err(RpcError::invalid_params(format!(
                        "preset {name:?} now carries harness args or a system prompt, which a remote-origin session never starts with"
                    )));
                }
                check_preset_args(profile.kind, &preset.args).map_err(RpcError::invalid_params)?;
                for (k, v) in &preset.env {
                    p.env.insert(k.clone(), v.clone());
                }
                p.argv.extend(preset.args.iter().cloned());
                if let Some(sha) = &preset.system_prompt_sha256 {
                    if profile.kind != crate::config::HarnessKind::ClaudeStdio {
                        return Err(RpcError::invalid_params(format!(
                            "preset {name:?} has a system prompt, which only Claude Code harnesses take"
                        )));
                    }
                    let dir = cfg.presets_dir().ok_or_else(|| {
                        RpcError::invalid_params(format!(
                            "preset {name:?} has a system prompt, but this daemon has no state directory"
                        ))
                    })?;
                    prompt_file = Some(
                        crate::config::checked_system_prompt(&dir, name, sha)
                            .map_err(RpcError::invalid_params)?,
                    );
                }
            }
        }
        if meta.remote_origin {
            let cfg = self.config.read().await;
            super::resolve::admit_remote_profile(&cfg, &meta.harness, &mut p, defaults_env)?;
        }
        let home = dirs::home_dir().unwrap_or_default();
        let model = meta.model_request.clone().unwrap_or_default();
        for v in p.env.values_mut() {
            *v = expand_env_value(v, &meta.cwd, &home, &model);
        }
        for a in p.argv.iter_mut() {
            *a = expand_env_value(a, &meta.cwd, &home, &model);
        }
        // An adopted chat that no profile's store holds runs on its own store.
        meta.apply_chat_store(&mut p.env);
        // The session's own env last, over the preset, never expanded: its
        // values were checked as given (session_env.rs).
        for (k, v) in &meta.session_env {
            p.env.insert(k.clone(), v.clone());
        }
        // The workspace picks the computer use display (agent_displays.rs);
        // `agent/command.rs` removes the key before the harness starts.
        crate::agent_displays::mark(&mut p.env, meta.workspace_id.as_deref());
        // The bound route last: it owns the provider variables (routes.rs).
        let account_home = self.apply_route(meta, forking, profile, &mut p.env).await?;
        p.argv = self.resolved_launcher_argv(p.argv);
        p.env.remove(crate::agent::REMOTE_ENV_POLICY_KEY);
        if meta.remote_origin {
            // Validate every executable after expansion and launcher
            // substitution. The Codex bridge replaces argv0 with CODEX_PATH
            // inside `harness_command`, so freeze that final program too.
            if crate::codex_app_server::is_profile_launch(&p.argv) {
                if let Some(program) = p.env.get_mut("CODEX_PATH").filter(|p| !p.is_empty()) {
                    *program = super::resolve::remote_executable(program)?;
                    super::resolve::refuse_remote_cwd_executable(program, &meta.cwd)?;
                } else {
                    let program = super::resolve::fix_remote_executable(&mut p)?;
                    super::resolve::refuse_remote_cwd_executable(program, &meta.cwd)?;
                }
            } else {
                let program = super::resolve::fix_remote_executable(&mut p)?;
                super::resolve::refuse_remote_cwd_executable(program, &meta.cwd)?;
            }
            p.env.insert(crate::agent::REMOTE_ENV_POLICY_KEY.into(), "1".into());
        }
        // After expansion: the path is acpmux's own, never expanded.
        if let Some(file) = prompt_file {
            p.argv.push("--system-prompt-file".into());
            p.argv.push(file.to_string_lossy().into_owned());
        }
        // Claude Code defers MCP tools behind its tool search, which it turns
        // off by itself behind a router; the cmux server lists every tool
        // for it (agent_tools::lists_all_tools). A profile's own value wins.
        if crate::agent_tools::is_claude_code(&meta.harness, profile)
            && crate::agent_tools::own_provider(&p.env)
        {
            p.env
                .entry(crate::agent_tools::TOOL_SEARCH_ENV.to_owned())
                .or_insert_with(|| "true".to_owned());
        }
        // The MCP servers this chat turned off (`tools.rs`): Claude Code never calls their tools.
        if profile.kind == crate::config::HarnessKind::ClaudeStdio {
            p.argv.extend(super::tools::disallowed_args(&meta.tools));
            // cmux's own servers run behind the cmux server (code mode), so
            // they leave its fold instead (`agent_tools::OFF_ENV`).
            let off: Vec<&str> =
                meta.tools.off.iter().filter_map(|id| id.strip_prefix("mcp:")).collect();
            p.env.remove(crate::agent_tools::OFF_ENV);
            if !off.is_empty() {
                p.env.insert(crate::agent_tools::OFF_ENV.to_owned(), off.join(","));
            }
        }
        // OpenCode asked to ask (`opencode_ask.rs`, `policy_mode.rs`), never by a profile's own marker.
        p.env.remove(crate::opencode_ask::MARKER);
        let default_policy = self.config.read().await.permission_policy;
        if super::policy_mode::asks_opencode(meta, profile, default_policy) {
            p.env.insert(crate::opencode_ask::MARKER.to_owned(), "1".to_owned());
        }
        Ok((p, digest, account_home))
    }

    /// `spawn` with OpenCode asked to ask as `session`'s policy stands now (`policy_mode.rs`),
    /// or `None` when it already is: `ensure_child` reads it again under the spawn lock, so a
    /// narrowing after `spawn_profile` read the policy (`ask_opencode` then finds no agent
    /// running) still holds for this start.
    pub(super) async fn opencode_ask_now(&self, session: &Session, spawn: &Spawn) -> Option<Spawn> {
        let default = self.config.read().await.permission_policy;
        let asks =
            spawn.opencode && super::policy_mode::narrow_policy(&session.meta(), default).is_some();
        if asks == spawn.env.contains_key(crate::opencode_ask::MARKER) {
            return None;
        }
        let mut profile = spawn.profile.clone();
        if asks {
            profile.env.insert(crate::opencode_ask::MARKER.to_owned(), "1".to_owned());
        } else {
            profile.env.remove(crate::opencode_ask::MARKER);
        }
        Some(Spawn {
            profile,
            preset_digest: spawn.preset_digest.clone(),
            account_home: spawn.account_home.clone(),
            opencode: spawn.opencode,
        })
    }
}

/// A session's spawn: the profile as it is spawned, and the approval digest
/// of the preset contents that profile was built from (under one config read).
pub(super) struct Spawn {
    pub profile: HarnessProfile,
    pub preset_digest: Option<String>,
    /// The account home a new chat starts in (route_account.rs `record`).
    pub account_home: Option<std::path::PathBuf>,
    /// Whether the harness is OpenCode, from the profile as configured (`policy_mode::is_opencode`).
    pub opencode: bool,
}

impl std::ops::Deref for Spawn {
    type Target = HarnessProfile;
    fn deref(&self) -> &HarnessProfile {
        &self.profile
    }
}

/// `${cwd}`, `${home}`, `${model}` and a leading `~/` in a profile env value or argv word.
pub fn expand_env_value(
    value: &str,
    cwd: &std::path::Path,
    home: &std::path::Path,
    model: &str,
) -> String {
    let mut out = value
        .replace("${cwd}", &cwd.to_string_lossy())
        .replace("${home}", &home.to_string_lossy())
        .replace("${model}", model);
    if let Some(rest) = out.strip_prefix("~/") {
        out = format!("{}/{rest}", home.to_string_lossy());
    }
    out
}
