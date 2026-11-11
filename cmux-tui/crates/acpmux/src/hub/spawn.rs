//! Part of `Hub`; see `hub/mod.rs`. The harness command line a session
//! spawns with: its profile, its preset's env, args and system prompt file.

use super::*;

use crate::config::check_preset_args;
use cmux_json::JsonSet as _;

fn pi_session_for(root: &Path, agent_id: &str) -> std::io::Result<Option<PathBuf>> {
    let Ok(entries) = std::fs::read_dir(root) else { return Ok(None) };
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        let meta = std::fs::symlink_metadata(&path)?;
        if !meta.file_type().is_file() || path.extension().and_then(|e| e.to_str()) != Some("jsonl")
        {
            continue;
        }
        let bytes = std::fs::read(&path)?;
        let first = bytes.splitn(2, |b| *b == 10).next().unwrap_or_default();
        let Ok(header) = serde_json::from_slice::<Value>(first) else { continue };
        if header.get("type").and_then(Value::as_str) == Some("session")
            && header.get("id").and_then(Value::as_str) == Some(agent_id)
            && header.get("cwd").and_then(Value::as_str).is_some()
        {
            return Ok(Some(path));
        }
    }
    Ok(None)
}

fn copy_legacy_tree(src: &Path, dst: &Path) -> std::io::Result<()> {
    let meta = std::fs::symlink_metadata(src)?;
    if meta.file_type().is_symlink() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "legacy durable state is symlinked",
        ));
    }
    if meta.file_type().is_dir() {
        std::fs::create_dir_all(dst)?;
        for entry in std::fs::read_dir(src)? {
            let entry = entry?;
            copy_legacy_tree(&entry.path(), &dst.join(entry.file_name()))?;
        }
        std::fs::File::open(dst)?.sync_all()?;
    } else if meta.file_type().is_file() {
        if std::fs::symlink_metadata(dst).is_ok() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "new durable state is occupied",
            ));
        }
        std::fs::copy(src, dst)?;
        std::fs::File::open(dst)?.sync_all()?;
    } else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "legacy durable state is not a file or directory",
        ));
    }
    Ok(())
}

fn copy_legacy_atomic(src: &Path, dst: &Path) -> std::io::Result<()> {
    if std::fs::symlink_metadata(dst).is_ok() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "migration destination is occupied",
        ));
    }
    let name = dst.file_name().and_then(|n| n.to_str()).unwrap_or("state");
    let tmp = dst.with_file_name(format!(".{name}.migrating"));
    if let Ok(meta) = std::fs::symlink_metadata(&tmp) {
        if meta.file_type().is_dir() {
            std::fs::remove_dir_all(&tmp)?;
        } else {
            std::fs::remove_file(&tmp)?;
        }
    }
    copy_legacy_tree(src, &tmp)?;
    if let Some(parent) = dst.parent() {
        std::fs::File::open(parent)?.sync_all()?;
    }
    std::fs::rename(&tmp, dst)?;
    if let Some(parent) = dst.parent() {
        std::fs::File::open(parent)?.sync_all()?;
    }
    Ok(())
}

fn migrate_legacy_harness_state(
    new_root: &Path,
    agent_id: &str,
    home: &Path,
) -> std::io::Result<()> {
    let legacy_root = home.join(".cmux-harness").join("sessions");
    let legacy_store = home.join(".cmux-harness").join("durable").join(agent_id);
    if new_root == legacy_root {
        return Ok(());
    }
    if pi_session_for(new_root, agent_id)?.is_none()
        && let Some(old_pi) = pi_session_for(&legacy_root, agent_id)?
    {
        std::fs::create_dir_all(new_root)?;
        let target = new_root.join(old_pi.file_name().ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "legacy Pi filename missing")
        })?);
        copy_legacy_atomic(&old_pi, &target)?;
    }
    let new_store = new_root.join(agent_id);
    if std::fs::symlink_metadata(&new_store).is_err()
        && std::fs::symlink_metadata(&legacy_store).is_ok()
    {
        copy_legacy_atomic(&legacy_store, &new_store)?;
    }
    let legacy_events = home.join(".cmux-harness").join("events");
    let new_events = new_root.parent().unwrap_or(new_root).join("events");
    for suffix in ["continuity.jsonl", "events.jsonl"] {
        let source = legacy_events.join(format!("{agent_id}.{suffix}"));
        if std::fs::symlink_metadata(&source).is_ok() {
            std::fs::create_dir_all(&new_events)?;
            let target = new_events.join(format!("{agent_id}.{suffix}"));
            if std::fs::symlink_metadata(&target).is_err() {
                copy_legacy_atomic(&source, &target)?;
            }
        }
    }
    Ok(())
}

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
        *child.given_servers.lock().unwrap_or_else(|e| e.into_inner()) = Some(servers.clone());
        let mut params = json!({"cwd": meta.cwd, "mcpServers": servers});
        if let Some(dirs) = super::additional_dirs::acp_value(meta) {
            params.set(super::additional_dirs::FIELD, dirs);
        }
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
    /// `launch_digest`: the launch of the entry `profile` comes from, as the entry is written
    /// (`Resolved::launch_digest`; `profile.launch_digest()` when `profile` is the entry itself).
    pub(super) async fn spawn_profile(
        &self,
        session: &Session,
        profile: &HarnessProfile,
        launch_digest: String,
        defaults_env: &std::collections::BTreeMap<String, String>,
    ) -> Result<Spawn, RpcError> {
        // A fork resumes its parent's conversation: it runs in the parent's folder.
        let forking = session.fork_from.lock().unwrap_or_else(|e| e.into_inner()).is_some();
        let meta = session.meta();
        let opencode = super::policy_mode::is_opencode(&meta, profile);
        let (profile, preset_digest, account_home) =
            self.spawn_profile_read(&meta, forking, profile, defaults_env).await?;
        Ok(Spawn { profile, preset_digest, account_home, opencode, launch_digest })
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
                    let original = crate::config::checked_system_prompt(&dir, name, sha)
                        .map_err(RpcError::invalid_params)?;
                    prompt_file = Some(if let Some(text) = meta.cmux_preset_prompt.as_deref() {
                        let overrides = dir.join(".context-overrides");
                        let key = crate::sha256::sha256_hex(text.as_bytes());
                        let hash = crate::config::write_system_prompt(&overrides, &key, text)
                            .map_err(|e| {
                                RpcError::internal(format!("save selected prompt: {e}"))
                            })?;
                        crate::config::checked_system_prompt(&overrides, &key, &hash)
                            .map_err(RpcError::invalid_params)?
                    } else {
                        original
                    });
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
        // cmux-harness writes its durable journal into acpmux's session store.
        // Bind this after profile and session env so a profile cannot redirect
        // the journal into an arbitrary path; MemoryStore intentionally has no
        // transferable directory and therefore leaves the bridge disabled.
        if p.family.as_deref() == Some("cmux-harness") {
            p.env.remove("CMUX_HARNESS_SESSION_STORE_DIR");
            if let Some(dir) = self
                .store
                .session_path(&meta.id)
                .and_then(|dir| dir.parent().map(Path::to_path_buf))
            {
                let root = dir.to_string_lossy().into_owned();
                if let Some(agent_id) = meta.agent_session_id.as_deref() {
                    migrate_legacy_harness_state(&dir, agent_id, &home).map_err(|e| {
                        RpcError::internal(format!("cmux-harness state migration: {e}"))
                    })?;
                }
                // Keep Pi's ACP JSONL and cmux-harness's durable journal in the
                // same transferable root. The harness session id is learned from
                // ACP and is independent of cmux's outer session id.
                p.env.insert("CMUX_HARNESS_SESSION_DIR".to_owned(), root.clone());
                p.env.insert("CMUX_HARNESS_SESSION_STORE_DIR".to_owned(), root);
            }
        }
        // The workspace picks the computer use display (agent_displays.rs);
        // `agent/command.rs` removes the key before the harness starts.
        crate::agent_displays::mark(&mut p.env, meta.workspace_id.as_deref());
        // The bound route last: it owns the provider variables (routes.rs).
        let account_home = self.apply_route(meta, forking, profile, &mut p.env).await?;
        p.argv = self.resolved_launcher_argv(p.argv);
        // Codex on a cmux Cloud machine: the image's own-or-team rule, as its launcher applies it
        // (codex_cloud_auth.rs). A bound route owns the provider instead.
        if crate::codex_app_server::is_profile_launch(&p.argv)
            && !p.env.contains_key(crate::routes::NAME_KEY)
        {
            let env = p.env.clone();
            let var = move |k: &str| {
                env.get(k)
                    .cloned()
                    .or_else(|| crate::login_env::var(k))
                    .or_else(|| std::env::var(k).ok())
                    .filter(|v| !v.is_empty())
            };
            let home = var("HOME").map(PathBuf::from).or_else(dirs::home_dir).unwrap_or_default();
            let root = self.vm_marker_root();
            #[cfg(unix)]
            let broker = matches!(crate::codex_auth_file::read(), Ok(Some(_)));
            #[cfg(not(unix))]
            let broker = false;
            let inputs =
                crate::codex_cloud_auth::Inputs { root: &root, home: &home, var: &var, broker };
            if let Some(reason) =
                crate::codex_cloud_auth::own_reason(&inputs, crate::codex_cloud_auth::host_resolves)
                    .await
            {
                tracing::info!(session = %meta.id, reason, "codex on this Cloud machine uses its own sign-in");
                let cmux_config = inputs.cmux_config();
                crate::codex_cloud_auth::apply(&mut p.argv, &mut p.env, &var, cmux_config);
            }
        }
        // Claude on a cmux Cloud machine: the model-plane pair the image's launcher puts back in
        // team mode (claude_cloud_auth.rs). A bound route owns the provider instead.
        // The family as the launch derives it (`agent/command.rs`): a discovered Claude profile has
        // none set. The sign-in check reads the env the child gets: the profile's `${env:…}` and
        // keychain references resolved as the launch resolves them (`resolved_profile_env`; one
        // that does not resolve keeps own), over the vault's and `machine.env`'s values
        // (`login_env::effective_for`), and its project settings.
        // Only an owner Cloud machine's Claude, so no other launch resolves its references twice.
        // A launcher that picks Claude's provider itself (`claude-sr`, `claude-cr`) owns it too.
        let claude_on_cloud = crate::config::derive_family(&meta.harness, &p) == "claude"
            && !p.env.contains_key(crate::routes::NAME_KEY)
            && crate::claude_cloud_auth::launches_claude_itself(&p.argv)
            && crate::codex_cloud_auth::owner_cloud_image_at(&self.vm_marker_root());
        let resolved = match claude_on_cloud.then(|| crate::agent::resolved_profile_env(&p)) {
            Some(Ok(env)) => Some(env),
            Some(Err(error)) => {
                tracing::info!(session = %meta.id, %error, "claude profile env does not resolve; it keeps its own sign-in");
                None
            }
            None => None,
        };
        if let Some(resolved) = resolved {
            let env = crate::login_env::effective_for(Some("claude"), &resolved);
            let read = env.clone();
            let var = move |k: &str| read.get(k).cloned().filter(|v| !v.is_empty());
            let home = var("HOME").map(PathBuf::from).or_else(dirs::home_dir).unwrap_or_default();
            let root = self.vm_marker_root();
            let inputs = crate::codex_cloud_auth::Inputs {
                root: &root,
                home: &home,
                var: &var,
                broker: false,
            };
            let cwd = std::path::Path::new(&meta.cwd);
            // The launch's own `--settings`, which Claude applies over every settings file; one
            // it cannot read keeps own.
            let flag = crate::claude_cloud_auth::flag_settings(p.argv.get(1..).unwrap_or(&[]), cwd);
            let pair = match &flag {
                Ok(flag) => {
                    crate::claude_cloud_auth::team_pair(
                        &inputs,
                        &env,
                        flag.as_ref(),
                        cwd,
                        crate::codex_cloud_auth::host_resolves,
                    )
                    .await
                }
                Err(error) => {
                    tracing::info!(session = %meta.id, %error, "claude --settings does not read; it keeps its own sign-in");
                    None
                }
            };
            if let (Some(pair), Ok(flag)) = (pair, &flag) {
                tracing::info!(session = %meta.id, "claude on this Cloud machine uses the team's model plane");
                crate::claude_cloud_auth::apply_team(
                    &mut p.env,
                    &mut p.argv,
                    flag.as_ref(),
                    pair,
                    env.get(crate::claude_cloud_auth::HEADERS).map(String::as_str).unwrap_or(""),
                    meta.remote_origin,
                );
            }
        }
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
                    super::resolve::fix_remote_executable(&mut p)?;
                    super::resolve::refuse_remote_cwd_executable(&p.argv[0], &meta.cwd)?;
                }
            } else {
                super::resolve::fix_remote_executable(&mut p)?;
                super::resolve::refuse_remote_cwd_executable(&p.argv[0], &meta.cwd)?;
            }
            p.env.insert(crate::agent::REMOTE_ENV_POLICY_KEY.into(), "1".into());
        }
        // After expansion: the path is acpmux's own, never expanded.
        if let Some(file) = prompt_file {
            p.argv.push("--system-prompt-file".into());
            p.argv.push(file.to_string_lossy().into_owned());
        }
        // cmux's rules as the chat captured them, on the harness's own system-level channel
        // (Claude's appended system prompt, Codex's developer instructions), at every spawn: the
        // prefix every chat shares, never a hidden addition after the person's first prompt.
        // A remote-origin chat captures none, and a chat moved under a guard takes its rules in
        // its next message instead (`turns.rs`, `append_owed_rules`), as does one whose
        // transcript already has them.
        if !meta.remote_origin && !meta.cmux_rules_in_transcript {
            let rules =
                crate::context_inventory::launch_args(meta.cmux_context.as_deref(), &p, &meta.cwd);
            p.argv.extend(rules);
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
        // Claude Code keeps the prompt cache one hour only on a Claude
        // subscription, five minutes on an API key or any other endpoint:
        // acpmux starts it on the cache `agents.promptCache` names (one
        // hour by default, prompt_cache_env.rs). A profile's own value wins.
        // The login shell's values are applied after this env (agent/command.rs), so one it
        // sets counts as set; a remote-origin chat gets no login env.
        if crate::agent_tools::is_claude_code(&meta.harness, profile) {
            let family = crate::config::derive_family(&meta.harness, profile);
            let remote = meta.remote_origin;
            let login = |key: &str| {
                crate::login_env::var(key)
                    .filter(|v| !remote && crate::login_env::allowed(key, v, Some(&family)))
            };
            crate::prompt_cache_env::apply(
                &mut p.env,
                crate::prompt_cache_env::PromptCache::current(),
                &login,
            );
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
            launch_digest: spawn.launch_digest.clone(),
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
    /// `HarnessProfile::launch_digest` of the profile as configured, before the preset, the
    /// route and the session's own env: what `profile_respawn.rs` compares a reload against.
    pub launch_digest: String,
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

#[cfg(test)]
#[path = "spawn_claude_cloud_tests.rs"]
mod claude_cloud_tests;
