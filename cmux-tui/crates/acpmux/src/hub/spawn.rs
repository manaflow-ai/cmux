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
        crate::home_fs::create_dirs(dst)?;
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
        crate::home_fs::copy(src, dst)?;
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
            crate::home_fs::remove_dir_all(&tmp)?;
        } else {
            crate::home_fs::remove_file(&tmp)?;
        }
    }
    copy_legacy_tree(src, &tmp)?;
    if let Some(parent) = dst.parent() {
        std::fs::File::open(parent)?.sync_all()?;
    }
    crate::home_fs::rename(&tmp, dst)?;
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
        crate::home_fs::create_dirs(new_root)?;
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
            crate::home_fs::create_dirs(&new_events)?;
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
    /// a remote origin or an isolated profile. `init` is this child's own `initialize` answer:
    /// whether it takes HTTP servers (the daemon's gateway, `mcp_gateway.rs`) comes from it,
    /// never from `meta`, a copy taken before the answer was recorded (a fresh chat's has no
    /// capabilities, so a Codex chat got five stdio `acpmux *-mcp` processes, bench 2026-11-25).
    #[allow(clippy::too_many_arguments)]
    pub(super) fn acp_params(
        &self,
        id: &str,
        meta: &SessionMeta,
        profile: &HarnessProfile,
        session_id: Option<&str>,
        child: &crate::agent::ChildAgent,
        answer: &crate::agent_tools::CodexAnswer,
        init: &Value,
    ) -> Value {
        let all =
            crate::agent_tools::lists_all_tools(&meta.harness, profile, &profile.env, &meta.cwd);
        // A fork through this child asks for the same list (`fork.rs`).
        child.all_tools.store(all, std::sync::atomic::Ordering::Relaxed);
        // Codex's answer for the person's own `cmux` entry, asked once for this start (its tool
        // rows', `record_spawn_inputs`, or its pool spec's) off the runtime.
        let codex = crate::agent_tools::is_codex(meta, Some(profile)).then_some(
            crate::agent_tools::CodexLaunch {
                cwd: &meta.cwd,
                argv: &profile.argv,
                answer: Some(answer),
            },
        );
        let http = crate::agent_tools::takes_http(init.get("agentCapabilities"));
        let servers = crate::agent_tools::acp_servers_for(
            meta.remote_origin,
            &profile.env,
            id,
            all,
            http,
            &meta.cwd,
            codex,
        );
        // A harness whose ACP server refuses per-session servers (OpenClaw's bridge) gets none:
        // its `session/new` would fail whole.
        let servers = if crate::agent_tools::takes_session_mcp(&meta.harness, profile) {
            // A harness that scrubs its MCP children's env (Hermes) gets the routing env inline.
            crate::agent_tools::with_routing_env(servers, &meta.harness, profile, &profile.env)
        } else {
            json!([])
        };
        *child.given_servers.lock().unwrap_or_else(|e| e.into_inner()) = Some(servers.clone());
        // The person's own stdio `cmux` entry learns which chat starts it, where cmux gives none.
        let entry_env = codex.and_then(|launch| {
            crate::agent_tools::person_entry_env(&servers, launch, &profile.env, id)
        });
        let mut params = json!({"cwd": meta.cwd, "mcpServers": servers});
        crate::agent_tools::send_person_entry_env(&mut params, entry_env);
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
        // The owner's Cloud credential, held for this session only (`agent_credentials.rs`).
        let credential = session.credential.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let (profile, preset_digest, account_home) = self
            .spawn_profile_read(&meta, forking, profile, defaults_env, credential.as_ref())
            .await?;
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
        self.spawn_profile_with(meta, profile, defaults_env, None).await
    }

    /// `spawn_profile_for` on the owner's Cloud credential a chat launches with (the session
    /// pool's key and start for a hinted Cloud chat, `PrewarmShape`, cmux#45953).
    pub(super) async fn spawn_profile_with(
        &self,
        meta: &SessionMeta,
        profile: &HarnessProfile,
        defaults_env: &std::collections::BTreeMap<String, String>,
        credential: Option<&crate::agent_credentials::AgentCredential>,
    ) -> Result<HarnessProfile, RpcError> {
        self.spawn_profile_read(meta, false, profile, defaults_env, credential)
            .await
            .map(|(p, ..)| p)
    }

    /// `spawn_profile_for`, and the approval digest of the preset contents
    /// it read (under the one config lock it read them with).
    async fn spawn_profile_read(
        &self,
        meta: &SessionMeta,
        forking: bool,
        profile: &HarnessProfile,
        defaults_env: &std::collections::BTreeMap<String, String>,
        credential: Option<&crate::agent_credentials::AgentCredential>,
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
        // A chat a person started asks sr2 for its person reserve (`sr2_priority.rs`), decided
        // here from who created it, after the session env: never a profile's or request's.
        crate::sr2_priority::mark(
            &mut p.env,
            meta.created_by.as_ref().is_some_and(|c| c.kind == crate::store::CreatorKind::Person),
        );
        // A remote-origin chat with no answer of its own (a phone or Web client started it; one
        // another Mac's daemon started carries that Mac's, `cmux_tools_answer.rs`) gets none of
        // cmux's servers (`agent_tools::left_out`), and its person's own `cmux` entry gets `off`.
        crate::agent_tools::remote_origin_answer(&mut p.env, meta.remote_origin);
        // The person's per-agent switch (cmux#49395): a Claude Code or Codex chat switched off in
        // Settings > Agents gets the answer `off`.
        let agent = if crate::agent_tools::is_codex(meta, Some(&p)) {
            Some("codex")
        } else if crate::agent_tools::is_claude_code(&meta.harness, &p) {
            Some("claude")
        } else {
            None
        };
        crate::agent_tools::agent_switch_answer(
            &mut p.env,
            crate::user_settings::text().as_deref(),
            agent,
        );
        // A Claude Code cut off from cmux's tools passes the answer `off` to its own stdio servers
        // (a person's `cmux` entry), as a Codex one does (`agent_tools::person_entry_env`).
        if crate::agent_tools::is_claude_code(&meta.harness, &p)
            && crate::agent_tools::cut_off(&p.env)
        {
            p.env.insert(crate::agent_tools::TOOLS_ANSWER_ENV.to_owned(), "off".to_owned());
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
        // Only `apply` marks an agent as launched on the owner's credential: a marker a profile,
        // preset or request env set would have its own login read back after a restart as one.
        p.env.remove(crate::agent_credentials::MARKER);
        // The owner's Cloud credential: straight to the provider, no coderouter route
        // (`agent_credentials.rs`). Its names only are logged, never a value.
        let direct = credential.is_some_and(|c| {
            let family = crate::config::derive_family(&meta.harness, &p);
            let applied = crate::agent_credentials::apply(c, &family, &mut p.argv, &mut p.env);
            let names: Vec<&str> = c.names().collect();
            if applied {
                tracing::info!(session = %meta.id, ?names, "agent launches on the owner's credential");
            } else {
                tracing::warn!(session = %meta.id, %family, ?names, "a credential of another family: the agent keeps this machine's route");
            }
            applied
        });
        // Codex on a cmux Cloud machine: the image's own-or-team rule, as its launcher applies it
        // (codex_cloud_auth.rs). A bound route or the owner's credential owns the provider instead.
        if !direct
            && crate::codex_app_server::is_profile_launch(&p.argv)
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
            // A machine joined to the cmux hub, not a Cloud image, whose launch opted in: the
            // hub's gateway route, the machine credential filled in by the egress proxy
            // (joined_model_plane.rs). Off unless asked for; asked for on a join that cannot
            // serve it, the launch fails with the reason rather than run own mode.
            let joined = match (!inputs.owner_cloud_image()
                && crate::joined_model_plane::opted_in(&inputs, "CMUX_CODEX_AUTH", "codex"))
            .then(crate::joined_model_plane::state)
            {
                Some(Err(why)) => return Err(joined_declined(&meta.id, "codex", "join", &why)),
                Some(Ok(join)) => join,
                None => None,
            };
            if let Some(join) = joined {
                let launch = |k: &str| p.env.get(k).cloned();
                if crate::joined_model_plane::names_provider(&p.argv) {
                    tracing::info!(session = %meta.id, "codex launch picks its own provider; it keeps it");
                } else if let Some(proxy) = crate::vault::egress::machine_credential_env(&launch) {
                    crate::joined_model_plane::apply_codex(&mut p.argv, &join);
                    p.env.extend(proxy);
                    tracing::info!(session = %meta.id, "codex on this joined machine uses the team's model plane through the hub");
                } else {
                    return Err(joined_declined(&meta.id, "codex", "no_proxy", NO_PROXY));
                }
            } else {
                // Off a Cloud image and off a join, a Codex with no way in at all is refused here,
                // naming the host and the fix, instead of starting and failing every turn
                // (`codex_signed_out.rs`, hq#21792 event 12). Keychain sign-ins are not read on
                // macOS, so there no sign-in seen is no proof of none.
                if !cfg!(target_os = "macos")
                    && !inputs.owner_cloud_image()
                    && crate::codex_signed_out::no_way_in(&inputs, &p.argv)
                {
                    let codex_home = inputs.codex_home().to_string_lossy().into_owned();
                    let probe_env = std::collections::BTreeMap::from([
                        ("CODEX_HOME".to_owned(), codex_home),
                        ("HOME".to_owned(), home.to_string_lossy().into_owned()),
                    ]);
                    let program = p.argv.first().map(String::as_str).unwrap_or("codex");
                    if crate::codex_signed_out::says_not_logged_in(program, &probe_env).await {
                        let host = crate::hand::pair::hostname();
                        tracing::warn!(session = %meta.id, %host, code = "codex.no_sign_in", "codex has no sign-in, key or provider on this machine");
                        return Err(RpcError::invalid_params(crate::codex_signed_out::refusal(
                            &host,
                            &meta.harness,
                        )));
                    }
                }
                match crate::codex_cloud_auth::own_reason(
                    &inputs,
                    crate::codex_cloud_auth::host_resolves,
                )
                .await
                {
                    Some(reason) => {
                        tracing::info!(session = %meta.id, reason, "codex on this Cloud machine uses its own sign-in");
                        let cmux_config = inputs.cmux_config();
                        crate::codex_cloud_auth::apply(&mut p.argv, &mut p.env, &var, cmux_config);
                    }
                    // Team mode: the provider's key in the launch env itself, since a remote-origin
                    // chat gets no login env to carry it.
                    None => {
                        if crate::codex_cloud_auth::apply_team(&mut p.env, &inputs) {
                            tracing::info!(session = %meta.id, "codex on this Cloud machine uses the team's model plane");
                        }
                    }
                }
            }
        }
        // Claude on a cmux Cloud machine: the model-plane pair the image's launcher puts back in
        // team mode (claude_cloud_auth.rs). A bound route owns the provider instead.
        // The family as the launch derives it (`agent/command.rs`): a discovered Claude profile has
        // none set. The sign-in check reads the env the child gets: the profile's `${env:…}` and
        // keychain references resolved as the launch resolves them (`resolved_profile_env`; one
        // that does not resolve keeps own), over the vault's and `machine.env`'s values, and its
        // project settings (`claude_cloud_auth::launch_env`). A remote-origin launch (the app's
        // Cloud chat, over its peer link) gets none of those, only the host base and its profile
        // (`agent/command.rs`), so only those count as its sign-in (#43821).
        // Only an owner Cloud machine's Claude, so no other launch resolves its references twice.
        // A launcher that picks Claude's provider itself (`claude-sr`, `claude-cr`) owns it too.
        // The owner's credential owns the provider, as for Codex above: a kept team choice on the
        // machine must not clear the token the launch just set.
        // A machine joined to the cmux hub that is no Cloud image takes the hub's gateway route the
        // same way, only when the launch opted in (joined_model_plane.rs; a cheap check first, so
        // no other launch resolves its references twice). Not for a remote chain: its sandbox
        // reaches no loopback proxy to fill the machine credential. Opted in, every gate that
        // declines fails the launch with its reason (`joined_declined`); not opted in, a launch
        // with no sign-in of its own fails with the fix (`joined_model_plane::no_sign_in`). An
        // opted-in launch that keeps own on purpose (a launcher of its own, a pair it sets) logs
        // why and keeps it.
        let claude_family = !direct
            && crate::config::derive_family(&meta.harness, &p) == "claude"
            && !p.env.contains_key(crate::routes::NAME_KEY);
        let claude_launch =
            claude_family && crate::claude_cloud_auth::launches_claude_itself(&p.argv);
        if claude_family
            && !claude_launch
            && !meta.remote_origin
            && crate::joined_model_plane::may_opt_in(&p.env, "CMUX_CLAUDE_AUTH", "claude")
            && !crate::codex_cloud_auth::owner_cloud_image_at(&self.vm_marker_root())
            && crate::joined_model_plane::now().is_some()
        {
            let file = p.argv.first().map(Path::new).and_then(Path::file_name);
            let why = format!(
                "the launch runs {}, not claude",
                file.map(|f| f.to_string_lossy()).unwrap_or_default()
            );
            tracing::warn!(session = %meta.id, agent = "claude", why = %why, code = "joined_model_plane.keeps_own", "a launch that chose the team's model route keeps its own on this joined machine");
        }
        let claude_on_cloud =
            claude_launch && crate::codex_cloud_auth::owner_cloud_image_at(&self.vm_marker_root());
        let claude_here = claude_launch && !claude_on_cloud && !meta.remote_origin;
        let claude_opted = claude_here
            && crate::joined_model_plane::may_opt_in(&p.env, "CMUX_CLAUDE_AUTH", "claude");
        let claude_joined = match claude_here.then(crate::joined_model_plane::state) {
            Some(Err(why)) if claude_opted => {
                return Err(joined_declined(&meta.id, "claude", "join", &why));
            }
            Some(Ok(join)) => join,
            _ => None,
        };
        let claude_unchosen = claude_joined.is_some() && !claude_opted;
        let claude_join = claude_joined.filter(|_| claude_opted);
        let resolved = match (claude_on_cloud || claude_join.is_some() || claude_unchosen)
            .then(|| crate::agent::resolved_profile_env(&p))
        {
            Some(Ok(env)) => Some(env),
            Some(Err(error)) if claude_join.is_some() => {
                let why = format!("its profile env does not resolve: {error}");
                return Err(joined_declined(&meta.id, "claude", "profile_env", &why));
            }
            Some(Err(error)) => {
                tracing::info!(session = %meta.id, %error, "claude profile env does not resolve; it keeps its own sign-in");
                None
            }
            None => None,
        };
        if let Some(resolved) = resolved {
            let env = crate::claude_cloud_auth::launch_env_now(resolved, meta.remote_origin);
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
            if let Err(error) = &flag
                && claude_join.is_some()
            {
                let why = format!("its --settings does not read: {error}");
                return Err(joined_declined(&meta.id, "claude", "settings_flag", &why));
            }
            // Keychain sign-ins are never read (`claude_auth.rs`), so on macOS no sign-in seen is
            // no proof of none.
            if claude_unchosen
                && !cfg!(target_os = "macos")
                && let Ok(flag) = &flag
                && crate::claude_cloud_auth::joined_without_sign_in(
                    &inputs,
                    &env,
                    flag.as_ref(),
                    cwd,
                )
            {
                tracing::warn!(session = %meta.id, code = "joined_model_plane.no_sign_in", "claude on this joined machine has no sign-in and no choice");
                return Err(RpcError::invalid_params(crate::joined_model_plane::no_sign_in()));
            }
            let pair = match &flag {
                Ok(flag) if claude_on_cloud => {
                    crate::claude_cloud_auth::team_pair(
                        &inputs,
                        &env,
                        flag.as_ref(),
                        cwd,
                        crate::codex_cloud_auth::host_resolves,
                    )
                    .await
                }
                Ok(flag) => {
                    crate::claude_cloud_auth::joined_pair(
                        &inputs,
                        &env,
                        flag.as_ref(),
                        cwd,
                        claude_join.as_ref(),
                        crate::codex_cloud_auth::host_resolves,
                    )
                    .await
                }
                Err(error) => {
                    tracing::info!(session = %meta.id, %error, "claude --settings does not read; it keeps its own sign-in");
                    None
                }
            };
            if pair.is_none()
                && let (Some(join), Ok(flag)) = (&claude_join, &flag)
            {
                match crate::claude_cloud_auth::joined_own_reason(&inputs, &env, flag.as_ref(), cwd)
                {
                    Some(why) => {
                        tracing::warn!(session = %meta.id, agent = "claude", why, code = "joined_model_plane.keeps_own", "a launch that chose the team's model route keeps its own on this joined machine");
                    }
                    None => {
                        let why = format!("the hub's host {} does not resolve", join.host());
                        return Err(joined_declined(&meta.id, "claude", "hub_unresolved", &why));
                    }
                }
            }
            let headers =
                env.get(crate::claude_cloud_auth::HEADERS).map(String::as_str).unwrap_or("");
            // A joined machine's launch: the header with the machine credential's placeholder,
            // and the egress proxy that fills it; without the proxy, own mode.
            let joined = match (&pair, claude_on_cloud) {
                (Some(_), false) => {
                    let launch = |k: &str| p.env.get(k).cloned();
                    let Some(proxy) = crate::vault::egress::machine_credential_env(&launch) else {
                        return Err(joined_declined(&meta.id, "claude", "no_proxy", NO_PROXY));
                    };
                    Some(Some((proxy, crate::joined_model_plane::claude_headers(headers))))
                }
                _ => None,
            };
            let pair = pair.filter(|_| !matches!(joined, Some(None)));
            if let (Some(pair), Ok(flag)) = (pair, &flag) {
                let headers = match &joined {
                    Some(Some((proxy, headers))) => {
                        p.env.extend(proxy.iter().cloned());
                        tracing::info!(session = %meta.id, "claude on this joined machine uses the team's model plane through the hub");
                        headers.as_str()
                    }
                    _ => {
                        tracing::info!(session = %meta.id, "claude on this Cloud machine uses the team's model plane");
                        headers
                    }
                };
                crate::claude_cloud_auth::apply_team(
                    &mut p.env,
                    &mut p.argv,
                    flag.as_ref(),
                    pair,
                    headers,
                    meta.remote_origin,
                );
            }
        }
        // Gemini, Grok and Antigravity on a cmux Cloud machine: the team's gateway when the person has no
        // sign-in of their own and the gateway serves the agent (provider_cloud_auth.rs,
        // hq#11225). A bound route, or a launcher that picks the provider itself, owns it instead.
        // The probe waits at most `PROBE_DEADLINE`; any failure keeps own.
        // The own-key check reads the env the child gets, as Claude's above does: the profile's
        // references resolved (one that does not resolve keeps own), over the vault's and
        // `machine.env`'s values (`provider_cloud_auth::LaunchEnv`, #43800); a remote-origin launch
        // (the app's Cloud chat, over its peer link) gets none of those, only its profile.
        // Only an owner Cloud machine's launch, so no other resolves its references twice.
        let root = self.vm_marker_root();
        let provider = crate::provider_cloud_auth::Provider::for_family(
            &crate::config::derive_family(&meta.harness, &p),
        )
        .filter(|provider| {
            !p.env.contains_key(crate::routes::NAME_KEY)
                && crate::provider_cloud_auth::launches_itself(*provider, &p.argv)
                && crate::codex_cloud_auth::owner_cloud_image_at(&root)
        });
        let resolved = provider.map(|provider| (provider, crate::agent::resolved_profile_env(&p)));
        let provider = match resolved {
            Some((provider, Ok(resolved))) => Some((provider, resolved)),
            Some((provider, Err(error))) => {
                tracing::info!(session = %meta.id, agent = provider.name(), %error, "agent profile env does not resolve; it keeps its own sign-in");
                None
            }
            None => None,
        };
        if let Some((provider, resolved)) = provider {
            let launch = crate::provider_cloud_auth::LaunchEnv::now(
                provider.name(),
                resolved,
                meta.remote_origin,
            );
            match crate::provider_cloud_auth::decide_launch(
                provider,
                &launch,
                &root,
                crate::provider_cloud_auth::probe_providers,
            )
            .await
            {
                crate::provider_cloud_auth::Mode::LeftAlone => {}
                crate::provider_cloud_auth::Mode::Own(reason) => {
                    tracing::info!(session = %meta.id, agent = provider.name(), reason, "agent on this Cloud machine uses its own sign-in");
                }
                crate::provider_cloud_auth::Mode::Team(team) => {
                    tracing::info!(session = %meta.id, agent = provider.name(), "agent on this Cloud machine uses the team's gateway");
                    crate::provider_cloud_auth::apply_team(&mut p.env, team);
                }
            }
        }
        // Antigravity with no key in its launch: the person's own one from `~/.gemini/.env`, where
        // the Cloud sign-in card saves it; `agy` reads only its environment (acp_key_auth.rs).
        let family = crate::config::derive_family(&meta.harness, &p);
        crate::acp_key_auth::fill_key_from_gemini_dotenv(&mut p.env, &family, |k| {
            std::env::var(k).ok()
        });
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
        // The response style and commit attribution the cmux settings choose for the agents cmux
        // starts (`agent_launch_choices.rs`): Claude Code's `outputStyle` and `attribution` in its
        // one `--settings`, Codex's `personality` as a `-c`. Unset passes nothing. A remote
        // chain refuses a profile `--settings`, so a remote-origin chat keeps the agent's own.
        if !meta.remote_origin {
            let choices = crate::agent_launch_choices::LaunchChoices::current();
            if profile.kind == crate::config::HarnessKind::ClaudeStdio {
                let cwd = std::path::Path::new(&meta.cwd);
                crate::agent_launch_choices::apply_claude(&mut p.argv, cwd, &choices);
            } else if crate::codex_app_server::is_profile_launch(&p.argv) {
                crate::agent_launch_choices::apply_codex(&mut p.argv, &choices);
            }
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
            // Per-turn context in the user turn, not a trailing system message the
            // next turn cannot read from the cache (prompt_cache_env.rs).
            crate::prompt_cache_env::keep_turn_context_in_user_turn(&mut p.env, &login);
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

/// Why a joined launch gets no proxy (`vault::egress::machine_credential_env`).
const NO_PROXY: &str = "the egress proxy cannot fill the machine credential for this launch (it \
did not start, or the launch names an HTTPS proxy of its own)";

/// The launch error of a launch that opted in to the joined model plane but whose `gate`
/// declined it, with `why` (joined_model_plane.rs): one WARN with a stable code, then the error
/// the caller (`acpmux run`) prints.
fn joined_declined(session: &str, agent: &str, gate: &str, why: &str) -> RpcError {
    tracing::warn!(
        session,
        agent,
        gate,
        why,
        code = "joined_model_plane.declined",
        "a launch that chose the team's model route cannot get it on this joined machine"
    );
    RpcError::invalid_params(crate::joined_model_plane::declined_text(agent, why))
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

pub use crate::config::expand_env_value;

#[cfg(test)]
#[path = "spawn_claude_cloud_tests.rs"]
mod claude_cloud_tests;

#[cfg(test)]
#[path = "spawn_codex_cloud_tests.rs"]
mod codex_cloud_tests;

#[cfg(all(test, unix, not(target_os = "macos")))]
#[path = "spawn_codex_signed_out_tests.rs"]
mod codex_signed_out_tests;
