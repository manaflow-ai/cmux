//! Part of `Hub`; see `hub/mod.rs`.

use super::full_access_bound::FullAccessEnd;
use super::policy_mode::refusal_record;
use super::*;

use super::adoption::{Adoption, adopted_in, start_folder};
use super::new_request::{claude_resume_refusal, suffixed_name_among, unique_name_among};
// `turns.rs` names it here.
pub(super) use super::new_request::profile_takes_model_at_spawn;
use super::resolve::{Draft, Resolved, draft_meta};
use super::start_watch::{StartWatch, start_deadline_exceeded, start_hung};
#[path = "lifecycle_cold_start.rs"]
mod cold_start;

/// How often the person's agent start that is still under way says so (`person_start`).
const START_PROGRESS: std::time::Duration = std::time::Duration::from_secs(10);

/// Owns a session while a creation future is still configuring it. If that future is cancelled
/// after publication, the guard purges the exact session rather than guessing from its name.
pub(super) struct CreationGuard {
    hub: Arc<Hub>,
    session: Arc<Session>,
    created_stops: u64,
    /// The inline `/btw` request's transcript owner, read when the guard is made: the request
    /// may end (and drop its mark) before the spawned purge runs.
    inline: Option<super::InlineBtwOwner>,
    armed: bool,
}

impl CreationGuard {
    pub(super) fn new(hub: Arc<Hub>, session: Arc<Session>, created_stops: u64) -> Self {
        let inline = hub.inline_btw_owner(&session);
        Self { hub, session, created_stops, inline, armed: true }
    }

    pub(super) fn disarm(mut self) {
        self.armed = false;
    }
}

impl Drop for CreationGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let hub = self.hub.clone();
        let session = self.session.clone();
        let created_stops = self.created_stops;
        let inline = self.inline.take();
        tokio::spawn(async move {
            hub.discard_failed_creation_owned(&session, created_stops, inline).await;
        });
    }
}

impl Hub {
    // --------------------------------------------------------- lifecycle

    pub async fn new_session(self: &Arc<Self>, req: NewRequest) -> Result<Arc<Session>, RpcError> {
        self.new_session_with_id(req, None).await
    }

    /// Create a session, optionally using a caller-selected id.
    ///
    /// The fixed-id path is private to the authenticated trigger bridge. It never
    /// takes an id from the warm pool, and publishes under the sessions lock so a
    /// concurrent creator cannot replace an existing chat.
    pub(crate) async fn new_session_with_id(
        self: &Arc<Self>,
        req: NewRequest,
        fixed_id: Option<String>,
    ) -> Result<Arc<Session>, RpcError> {
        if let Some(id) = fixed_id.as_deref()
            && !crate::adopt::is_bare_id(id)
        {
            return Err(RpcError::invalid_params(
                "fixed session id must contain only letters, digits, '-' or '_'",
            ));
        }
        if fixed_id.is_some() && req.adopt.is_some() {
            return Err(RpcError::invalid_params("fixed session ids cannot adopt another chat"));
        }
        let caller_selected_id = fixed_id.is_some();
        // Harness discovery and launcher checks finish in the background; a new chat waits for
        // them only, never for another chat's adoption or log (`startup.rs`). Bounded: a
        // preparation that never ends answers with its phase, not silence.
        self.wait_spawn_ready_within(super::startup::NEW_SESSION_STARTUP_WAIT).await?;
        // Mutations wait for the complete index. A later durable check also refuses
        // malformed or partially written chats that the startup loader could not install.
        if caller_selected_id {
            self.wait_store().await;
        }
        let NewRequest {
            harness,
            preset,
            name,
            suffix_taken_name,
            cwd,
            policy,
            model,
            effort,
            adopt,
            remote,
            vm_boundary,
            env: session_env,
            workspace_id,
            keep_harness_mode,
            starter,
            route,
            subsession,
            lineage,
            created_by,
            disallowed_tools,
            checked_cwd,
            additional_directories,
            stop_condition,
            restricted,
            person,
            wait_start,
            throwaway,
            require_asking,
            credential,
            create_key,
            placed_by,
        } = req;
        // A create sent again after a restart cut its reply: the session the first one made
        // answers it, on this daemon or the one before (`create_key.rs`).
        if let Some(key) = create_key.as_deref()
            && let Some(made) = self.created_with_key(key).await
        {
            return Ok(made);
        }
        // The proven agent session that asked for this one, as it is now; never for a remote
        // chat, and never one a remote connection started (`remote_origin`).
        let starter = starter
            .filter(|_| !remote)
            .and_then(|id| self.resolve(&id).ok().filter(|s| s.id == id))
            .filter(|s| !s.meta().remote_origin)
            .map(|s| s.id.clone());
        // An adopted session's harness names the head unless one was given.
        let harness = harness.or_else(|| adopt.as_ref().and_then(|a| a.harness.clone()));
        // A harness installed since the catalog loaded serves this start (`rediscover.rs`).
        self.rediscover_head(harness.as_deref(), preset.as_deref()).await;
        // Resolution is a lookup, never a guess: preset → head (family or
        // profile) → defaults chain → explicit values on top.
        let (
            Resolved {
                agent,
                profile,
                launch_digest,
                defaults,
                head,
                preset_name,
                folder_root,
                preset_digest,
            },
            preset_plain,
        ) = {
            let cfg = self.config.read().await;
            let r =
                self.resolve_new(&cfg, harness, &preset, model.as_deref(), remote, cwd.as_deref())?;
            // Held to asking: checked on this profile, under this read (`require_asking.rs`).
            if require_asking {
                let adopting = adopt.is_some();
                super::require_asking::holds_at_start(
                    &cfg, &r.agent, &r.profile, policy, adopting,
                )?;
            }
            let plain = super::start_mode::plain_for_mode(r.preset_name.as_deref(), &cfg);
            (r, plain)
        };
        let agent = agent.as_str();
        if profile.kind == crate::config::HarnessKind::Terminal {
            return Err(terminal_harness_refusal(agent));
        }
        let family = crate::config::derive_family(agent, &profile);
        // The store an adopt reads: every Claude Code profile's is Claude's, whatever its family
        // (`claude-sr2`); the chat keeps `family` and the profile it was asked on.
        let store_family = crate::config::store_family(agent, &profile);
        // The starter whose limits this chat takes (`start_mode.rs`, "Inherit"): a sub-session's
        // parent, a starter in full access, or any starter under `holdAgentStartsToStarter`. Else
        // the chat starts at the person's configured default, as a start with no starter does
        // (user 2026-11-03: an agent in Manual left the chats it opened in Manual).
        let held = self.config.read().await.hold_agent_starts_to_starter;
        let limits_from = match starter.as_deref() {
            Some(id) if !held && subsession.is_none() => {
                let full = self.resolve(id).ok().is_some_and(|s| {
                    self.caller_access(&s.meta()) == super::subsession_guard::Access::Full
                });
                full.then(|| id.to_owned())
            }
            _ => starter.clone(),
        };
        // No policy asked: the defaults' when it is no wider than a starter's, else the starter's
        // own (`start_mode.rs`, "Inherit").
        let inherits_policy = policy.is_none() && limits_from.is_some();
        let policy = match (policy, limits_from.as_deref()) {
            (Some(asked), _) => Some(asked),
            (None, Some(id)) => {
                let daemon = self.config.read().await.permission_policy;
                super::start_mode::inherited_policy(defaults.policy, self.own_policy(id), daemon)
            }
            (None, None) => defaults.policy,
        };
        // `${model}` in argv or env: the model is a spawn parameter, not a set_model call.
        let spawn_model = profile_takes_model_at_spawn(&profile)
            || defaults.env.values().any(|v| v.contains("${model}"));
        // What a new chat starts on when nothing pins it (start_defaults.rs):
        // the saved default (acpmux defaults or the person's pick), else the catalog default.
        // A request value, a preset, a folder profile, a profile's own
        // model/effort (or a model in its argv or env) and an adopted
        // conversation keep today's chain (request, then `defaults`).
        let eligible = adopt.is_none() && preset_name.is_none() && folder_root.is_none();
        // The start mode also skips a remote-origin session (the remote
        // guard settles its mode) and a profile that pins its mode; a built-in Chief subagent
        // preset's chat takes it as a plain chat does (`start_mode.rs`, cmux#27847).
        let mode_plain = adopt.is_none() && preset_plain && folder_root.is_none();
        let mode_eligible =
            super::start_mode::mode_eligible(mode_plain, remote, keep_harness_mode, &profile);
        // A harness that takes its model at spawn (Claude Code's `--model`)
        // gets the start model there (`model_request` below).
        let model_pinned = model.is_some()
            || !eligible
            || profile.model.is_some()
            || super::start_defaults::profile_sets_model(&profile, &defaults.env);
        let effort_pinned = effort.is_some() || !eligible || profile.effort.is_some();
        let pinned_model =
            if model_pinned { model.or_else(|| defaults.model.clone()) } else { None };
        let (start_model, start_effort) = if eligible {
            self.start_defaults(agent, &profile, &defaults, pinned_model.as_deref())
        } else {
            (None, None)
        };
        // A catalog default (not a saved pick) is skipped when the harness doesn't offer it.
        let model_from_catalog = !model_pinned
            && start_model
                .as_ref()
                .is_some_and(|s| s.source == super::start_defaults::StartSource::Catalog);
        let (model, model_soft) = match (model_pinned, start_model) {
            (true, _) | (false, None) => (pinned_model, false),
            (false, Some(start)) => (Some(start.value), true),
        };
        // Every model a chat starts on, from any entry point (`new -m`, `exec -m`, ACP and MCP
        // starts, a preset, the defaults, a saved pick), as the catalog names it: `fable-5.2`
        // runs as `claude-fable-5-2` (`model_alias.rs`).
        let model_rewrite = match &model {
            Some(m) => Some(self.canonical_model_for(agent, &profile, m)?).filter(|c| c.changed()),
            None => None,
        };
        let model = match model_rewrite.as_ref() {
            Some(c) => Some(c.model.clone()),
            None => model,
        };
        let (effort, effort_soft) = match (effort_pinned, start_effort) {
            (true, _) | (false, None) => (effort.or_else(|| defaults.effort.clone()), false),
            (false, Some(start)) => (Some(start.value), true),
        };
        // Adopting checks the id against the harness's own store before
        // anything is created, and takes the conversation's recorded cwd.
        let env = [&defaults.env, &profile.env];
        let (recorded, fork, adopted_file, chat_store) =
            match self.adoption(adopt.as_ref(), agent, &store_family, &env, remote).await? {
                Adoption::Existing(existing) => return Ok(existing),
                Adoption::Found { cwd, fork, file, store } => (cwd, fork, file, store),
            };
        // A fork resumes nothing as itself: it forks the adopted id into a new conversation.
        let fork_from = adopt.as_ref().filter(|_| fork).map(|a| a.agent_session_id.clone());
        // A gone recorded folder may be remapped: git runs to compare repositories.
        let cwd_map = adopt.as_ref().map(|a| a.cwd_map.clone()).unwrap_or_default();
        let fam = store_family.clone();
        let (cwd, adopted_cwd, git) =
            tokio::task::spawn_blocking(move || start_folder(cwd, recorded, &fam, &cwd_map))
                .await
                .map_err(|e| RpcError::internal(e.to_string()))??;
        // A folder profile runs only in chats whose folder is inside its folder (H4).
        if let Some(root) = &folder_root
            && !std::fs::canonicalize(&cwd).unwrap_or_else(|_| cwd.clone()).starts_with(root)
        {
            return Err(RpcError::invalid_params(format!(
                "harness {agent} is a folder profile of {}; the chat folder must be inside it",
                root.display()
            )));
        }
        // A remote chain's Claude Code stubs empty package.json, lockfiles and .env* into its
        // folder (scrub mode, `remote_sandbox.rs`): only a checkout or a scratch folder takes it
        // (`remote_cwd.rs`). Creation only: an existing session's respawn is never re-checked, and
        // the trigger bridge's fixed-id chats (`server/trigger_chat.rs`) keep their own folder rule.
        super::remote_cwd::admit_new(
            super::remote_cwd::NewSession {
                remote,
                trigger: fixed_id.is_some(),
                kind: profile.kind,
            },
            &cwd,
            &std::env::temp_dir(),
            dirs::home_dir().as_deref(),
        )?;
        let mut meta = draft_meta(Draft {
            id: String::new(),
            agent,
            profile: &profile,
            family: &family,
            preset: preset_name.clone(),
            model_request: if spawn_model { model.clone() } else { None },
            cwd,
            // Set before the first spawn, so the harness resumes it.
            agent_session_id: adopt
                .as_ref()
                .filter(|_| fork_from.is_none())
                .map(|a| a.agent_session_id.clone()),
            policy,
            remote,
        });
        (meta.session_env, meta.chat_store, meta.adopted_cwd, meta.git_branch, meta.git_head) =
            (session_env, chat_store, adopted_cwd, git.branch, git.head);
        if !remote && adopt.is_none() {
            let cfg = self.config.read().await;
            meta.cmux_preset_prompt = crate::context_inventory::preset_override(&meta, &cfg);
            meta.cmux_context = Some(crate::context_inventory::snapshot_session(&meta, &cfg));
        }
        // Claude Code takes a plain start effort on its command line (`--effort`), as it takes
        // the model: set after `initialize` it cost one `apply_flag_settings` round trip
        // (213-271 ms on a Linux lane VM) before the chat could take its first prompt. Anything
        // else (another harness, "default", Ultracode) is still set live below.
        meta.effort_request = effort
            .clone()
            .filter(|_| profile.kind == crate::config::HarnessKind::ClaudeStdio)
            .filter(|e| crate::claude_stdio::takes_effort_at_spawn(e));
        meta.workspace_id = workspace_id;
        meta.additional_directories =
            super::additional_dirs::without_cwd(additional_directories, &meta.cwd);
        // Claude Code (stdio) takes it as a Stop hook, Codex (codex-acp) as its goal
        // (`stop_condition.rs`); the session/new answer says whether it was kept.
        meta.stop_condition =
            stop_condition.filter(|_| super::stop_condition::kept_by(&profile, &family));
        // Read-only in a folder not trusted (`restricted.rs`): only a harness that can keep it.
        if restricted && !super::restricted::kept_by(&profile) {
            return Err(super::restricted::unsupported(&meta.harness));
        }
        meta.restricted = restricted;
        meta.vm_boundary = remote && vm_boundary;
        meta.subsession = subsession;
        meta.lineage = lineage;
        meta.created_by = created_by;
        meta.tools
            .off
            .extend(disallowed_tools.iter().map(|t| format!("{}{t}", super::tools::BUILT_IN)));
        // A pooled session of exactly this shape (`pool/`) gives the session its id; `ensure_child`
        // then takes it instead of starting cold. Never with this session's own env, route or
        // disallowed tools, nor in a folder a sub-session start checked: a pooled harness started
        // wherever the path led. Never for an agent's create (`starter`): the warm agent is kept
        // for the person's next chat, which never waits behind a lane's start. A Claude Code chat
        // only the person made: a pooled one started for the person (`pool/start.rs`) and asked
        // for a next-prompt suggestion after every turn, which Claude Code decides once, at
        // `initialize` (`host_level.rs` `start_params`).
        let shaped = fixed_id.is_none()
            && adopt.is_none()
            && starter.is_none()
            && (profile.kind != crate::config::HarnessKind::ClaudeStdio
                || super::host_level::made_for_a_person(meta.created_by.as_ref(), person))
            && meta.session_env.is_empty()
            && route.is_none()
            && meta.tools.off.is_empty()
            && meta.additional_directories.is_empty()
            && meta.stop_condition.is_none()
            && !meta.restricted
            && checked_cwd.is_none();
        // A Cloud chat's owner credential (`agent_credentials.rs`) takes only an entry warmed with
        // that same credential (`_acpmux/prewarm` `credentials`, cmux#45953): the key's auth
        // fingerprint hashes the credentialed spawn env, so another credential, or none, misses.
        let mut asked = None;
        let pooled = if shaped {
            self.pool_claim(&meta, &profile, &defaults.env, credential.as_ref(), &mut asked).await
        } else {
            None
        };
        // Only a shape with no credential of its own is remembered for a spare or the last-used
        // role: those start with no credential, so they never hold one.
        let claimable = shaped && credential.is_none();
        // Every way out of here (an error, or this future dropped) before
        // `ensure_child` took the entry puts it back or ends it.
        let _claim = pooled.as_ref().map(|id| self.pool_claim_guard(id.clone()));
        let warm = pooled.is_some();
        let id =
            fixed_id.unwrap_or_else(|| pooled.unwrap_or_else(|| uuid::Uuid::now_v7().to_string()));
        meta.id = id.clone();
        // A named route is checked before anything is created: it exists and
        // serves this chat's harness family.
        if let Some(route_id) = &route {
            self.check_new_route(route_id, &family).await?;
        }
        let stores = super::adoption::store_families(&*self.config.read().await);
        // An evicted chat this create may meet (its id, key, name, or adopted agent session) is
        // back in memory first, so the checks below see it as they did (`evict.rs`).
        self.rehydrate_where(|m| {
            m.id == id
                || (create_key.is_some() && m.create_key == create_key)
                || name.as_deref().is_some_and(|n| m.name == n)
                || adopt.as_ref().is_some_and(|a| {
                    m.agent_session_id.as_deref() == Some(a.agent_session_id.as_str())
                })
        });
        // Pick or check the name and insert under one lock, so concurrent
        // creations can never publish the same name twice.
        let session = {
            let mut sessions = self.sessions.lock().unwrap();
            // The shutdown reads the sessions after it starts: a session
            // inserted after that is never ended, so none is (shutdown.rs).
            // Nothing is made yet: the CLI sends the create to the next daemon.
            if self.shutting_down() {
                return Err(super::shutting_down_before_create());
            }
            if sessions.contains_key(&id) || self.importing.lock().unwrap().contains(&id) {
                return Err(RpcError::invalid_params(format!(
                    "session id {id:?} is already in use"
                )));
            }
            if caller_selected_id {
                refuse_stored_fixed_id(self.store.as_ref(), &id)?;
            }
            // Two creates with one key at once get one session.
            if let Some(made) =
                create_key.as_deref().and_then(|key| super::create_key::made_in(&sessions, key))
            {
                return Ok(made);
            }
            // Checked again under the insert lock: two concurrent adopts of
            // one id get one session.
            if let Some(a) = adopt.as_ref().filter(|_| fork_from.is_none())
                && let Some(existing) =
                    adopted_in(&sessions, &stores, &store_family, &a.agent_session_id)
            {
                return Ok(existing);
            }
            meta.name = match name {
                Some(n) => {
                    let taken = sessions.values().any(|s| s.read_meta(|m| m.name == n));
                    // A placed or forwarded start keeps its name, suffixed (`NAME-2`), never the
                    // agent's; any other start is refused, so `new --reuse` finds the one running.
                    let n = if taken && suffix_taken_name {
                        suffixed_name_among(&sessions, &self.evicted.names(), &n)
                    } else if taken {
                        return Err(RpcError::invalid_params(format!(
                            "session name {n:?} is taken"
                        )));
                    } else {
                        n
                    };
                    // The name is a handle (a lane's): the chat is still titled (`titles.rs`).
                    meta.title_source = Some(super::titles::LAUNCHED.to_owned());
                    meta.name_given = true;
                    n
                }
                // A pooled harness was started under its name: keep it.
                None => match self
                    .pool_claimed_name(&id)
                    .filter(|n| !sessions.values().any(|s| s.read_meta(|m| m.name == *n)))
                    .filter(|n| !self.evicted.any_keys(|m| m.name == *n))
                {
                    Some(n) => n,
                    None => unique_name_among(&sessions, &self.evicted.names(), agent),
                },
            };
            meta.wait_start = wait_start;
            meta.throwaway = throwaway;
            meta.create_key = create_key;
            meta.placed_by = placed_by;
            let session = self.make_session(meta);
            *session.codex_answer_asked.lock().unwrap_or_else(|e| e.into_inner()) = asked;
            session.person.store(person, Ordering::SeqCst);
            // A chat that records no creator (an adopt, a move's target) is the person's only
            // when the person asked for it: its first start says so (`host_level.rs`).
            if session.read_meta(|m| m.created_by.is_none()) {
                let start_for = super::host_level::start_for_creator(person);
                session.start_for.store(start_for, Ordering::SeqCst);
            }
            // Before the session is published, so its first spawn already has it; memory only.
            *session.credential.lock().unwrap_or_else(|e| e.into_inner()) = credential;
            *session.fork_from.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                fork_from.clone();
            // In its meta too, written below: a restart before its first start forks it still.
            session.keep_fork_start(true);
            // Read before the session is published: a stop from then on ends its first start.
            let stops = session.stops.load(Ordering::SeqCst);
            sessions.insert(id.clone(), session.clone());
            // A purge this run fenced the id (a trigger's fixed id, recreated): the new chat's
            // answers and spend are recorded again. Sent under the insert lock, so before any of
            // its records.
            self.audit.reopen(&id);
            self.ledger.reopen(&id);
            super::admission::claim(&id);
            (session, stops)
        };
        let (session, created_stops) = session;
        self.update_live_session_index(&session);
        // A session that came may be another row's parent: every closed row is built again. Its
        // `created` record, below, notes the rows that read it (`Hub::note_rows_reading`).
        self.events.all_rows_stale();
        let creation_guard = CreationGuard::new(self.clone(), session.clone(), created_stops);
        if let Err(e) = self.write_meta(&session) {
            // Leave the instance registered until CreationGuard finishes its purge;
            // a retry must not publish the same id ahead of that cleanup.
            return Err(RpcError::internal(e.to_string()));
        }
        // The chat's route is bound once the session exists and before its
        // harness starts, so its first spawn already runs on it (route_switch.rs).
        if let Some(route_id) = &route {
            let (_, state) = crate::routes::places(&*self.config.read().await);
            if let Err(e) =
                crate::routes::set_binding(&state, &format!("chat:{id}"), Some(route_id))
            {
                // CreationGuard owns cleanup, including unregistering this instance.
                return Err(RpcError::invalid_params(e.message().to_owned()));
            }
        }
        // No `git` record exists yet; retain that baseline even if the chat grows before attach.
        self.restore_git_branch(&session, session.meta().git_branch);
        self.append(&session, "mux", "created", json!({"harness": agent, "preset": preset_name}));
        if let Some(c) = &model_rewrite {
            self.record_model_rewrite(&session, c, "new");
        }
        // Opt-in usage patterns: one more chat on this harness (its kind, not the chat).
        cmux_usage_patterns::count("agent-chat", agent);
        if let Some(a) = &adopt {
            let adopted = if fork_from.is_some() {
                json!({"agentSessionId": a.agent_session_id, "fork": true})
            } else {
                json!({"agentSessionId": a.agent_session_id})
            };
            self.append(&session, "mux", "adopted", adopted);
        }
        self.note_preset_resolved(&session, preset_digest);
        // A watch starts no harness: it shows and follows the transcript (`watch.rs`).
        if let (Some(file), true) = (&adopted_file, adopt.as_ref().is_some_and(|a| a.watch)) {
            creation_guard.disarm();
            return Ok(self.begin_watch(&session, &store_family, file.clone()));
        }
        // A fresh Claude Code chat the person started spawns in its start mode (`--permission-mode`,
        // `claude_spawn_start_mode`), so `start_mode_for` below finds it there and sends no
        // `set_mode`, which Claude Code would answer only once booted. The chat's modes are the
        // agent's own once it started (`cold_start`); a process that cannot take the mode (bypass
        // not allowed) runs Claude Code's own, and the `set_mode` below moves it as before.
        let spawn_start_mode = if !warm
            && mode_eligible
            && limits_from.is_none()
            && profile.kind == crate::config::HarnessKind::ClaudeStdio
        {
            self.claude_spawn_start_mode(&session).await
        } else {
            None
        };
        if let Some(mode) = &spawn_start_mode {
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).modes =
                Some(json!({ "currentModeId": mode }));
        }
        let spawned =
            match self.spawn_profile(&session, &profile, launch_digest, &defaults.env).await {
                Ok(spawn) => {
                    let checked = checked_cwd.as_ref();
                    self.ensure_checked_child(&session, &spawn, checked, created_stops).await
                }
                Err(e) => Err(e),
            };
        if let Err(e) = spawned {
            // A session whose agent never started is not left behind, and
            // neither is a child that spawned but failed to initialize.
            self.discard_failed_creation(&session, created_stops).await;
            creation_guard.disarm();
            return Err(e);
        }
        // A start mode the agent spawned in and runs is cmux's own, as `set_mode` records it
        // (`trust_wait.rs` `full_access_by_cmux`).
        if let Some(mode) = spawn_start_mode {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if crate::web_modes::mode_of(&m).as_deref() == Some(mode.as_str()) {
                m.mode_set_by_cmux = Some(mode);
            }
        }
        // An agent that started fresh instead of resuming fails creation.
        if let Some(a) = adopt.as_ref().filter(|_| fork_from.is_none()) {
            self.check_resumed(&session, a, agent).await?;
            // The adopted chat shows its past at once: Claude Code's resume replays nothing, and a
            // Codex session/load's history is logged as `.replay` records no client shows, so both
            // replay their own transcript (OpenCode's store is a database: not replayed).
            if matches!(store_family.as_str(), "claude" | "codex")
                && let Some(file) = adopted_file.clone()
            {
                self.replay_adopted(&session, &store_family, file).await;
            }
        }
        // Defaults and explicit values, applied once the harness is up. A bad
        // value fails creation loudly rather than starting a session that
        // silently runs another model.
        // Each step reaches the agent through `child_for`, under the creation's stop count: a
        // stop meanwhile fails the step and starts nothing again (`REQUEST_STOPS`).
        let request = (session.id.clone(), created_stops);
        let applied: Result<(), RpcError> = REQUEST_STOPS.scope(request, async {
            if let Some(m) = &model
                && !spawn_model {
                    // `opencode/big-pickle` was written as `-m opencode/big-pickle`:
                    // the harness lacks `big-pickle` but lists `opencode/big-pickle`.
                    let catalog = self.catalog_ids(agent).await;
                    let full = format!("{head}/{m}");
                    let m = if !catalog.is_empty() && !catalog.iter().any(|id| id == m) && catalog.contains(&full) { full } else { m.clone() };
                    // A start value this session's harness does not list (its account
                    // lacks it): the harness accepts set_model, then fails every prompt.
                    if model_from_catalog && !self.harness_offers(agent, &profile, &m) {
                        tracing::warn!(harness = agent, model = %m, "start model skipped: not offered by the harness");
                        self.append(&session, "mux", "start_default_skipped", json!({"modelId": m, "error": "the harness does not offer this model"}));
                    } else if let Err(e) = self.set_model(&session, &m).await {
                        // A start value the harness refuses (start_defaults.rs): the
                        // chat runs the harness's own default instead.
                        if model_soft {
                            tracing::warn!(harness = agent, model = %m, "start model skipped: {}", e.message);
                            self.append(&session, "mux", "start_default_skipped", json!({"modelId": m, "error": e.message}));
                        } else if e.message.contains("Method not found") {
                            return Err(RpcError::invalid_params(format!(
                                "harness {agent} takes no model over ACP (no session/set_model); choose it in the harness's own settings, or give its profile a `${{model}}` argv or env entry in config.json"
                            )));
                        } else {
                            let hint = if catalog.is_empty() { String::new() } else { format!("; models: {}", catalog.join(", ")) };
                            return Err(RpcError::invalid_params(format!("model {m:?} for {agent}: {}{hint}", e.message)));
                        }
                    }
                }
            // A process spawned on this effort (`effort_request`), as it reported it, is not
            // asked again; one that runs another (a pooled agent, which starts on the harness's
            // own level) is switched live.
            let spawned_on = |e: &str| {
                let m = session.meta();
                m.effort_request.as_deref() == Some(e) && current_effort(&m).as_deref() == Some(e)
            };
            if let Some(e) = effort.as_deref().filter(|e| spawned_on(e)) {
                session.applied.lock().unwrap_or_else(std::sync::PoisonError::into_inner).effort =
                    Some(e.to_owned());
            } else if let Some(e) = &effort {
                match self.set_config(&session, "effort", json!(e)).await {
                    Ok(_) => {}
                    Err(err) if effort_soft => {
                        tracing::warn!(harness = agent, effort = %e, "start effort skipped: {}", err.message);
                        self.append(&session, "mux", "start_default_skipped", json!({"effort": e, "error": err.message}));
                    }
                    Err(err) => return Err(RpcError::invalid_params(format!("effort {e:?} for {agent}: {}", err.message))),
                }
            }
            // The permission mode a new chat starts in (start_mode.rs): full
            // access unless the person picked or set otherwise. Soft.
            // A proven agent starter's instead, never wider (`start_mode.rs`, "Inherit").
            let start_mode = if mode_eligible {
                // Boxed, as the hold below: inline they outgrow a debug build's 2 MiB stack.
                Box::pin(self.start_mode_for(&session, limits_from.as_deref())).await
            } else {
                None
            };
            if let Some(mode) = start_mode {
                match self.set_mode(&session, &mode).await {
                    Ok(_) => {
                        let starter = limits_from.as_deref();
                        self.inherited_full_access_is_cmux_only_if_theirs(&session, starter);
                    }
                    Err(err) => {
                        tracing::warn!(harness = agent, mode = %mode, "start mode skipped: {}", err.message);
                        self.append(&session, "mux", "start_default_skipped", json!({"modeId": mode, "error": err.message}));
                    }
                }
            }
            // Never asking less than the starter as it is now (it may have narrowed or left full
            // access meanwhile, or the child's family has no mode that asks): an inherited policy
            // is narrowed to the starter's, and the harness moved, else refused.
            let starter = limits_from.as_deref();
            Box::pin(self.hold_to_starter(&session, starter, inherits_policy, mode_eligible))
                .await?;
            // Every chat, eligible or not: a preset's or a pinned profile's policy holds too.
            let cfg = self.config.read().await;
            // Any policy narrower than approve-all, however the chat got it, holds or the chat is
            // not created (`policy_mode.rs` `require_enforced`).
            super::policy_mode::require_enforced_as(&session.meta(), &cfg, true)?;
            self.note_unenforced_policy(&session, &cfg);
            Ok(())
        })
        .await;
        if let Err(e) = applied {
            // Never leave a half-configured session behind.
            self.discard_failed_creation(&session, created_stops).await;
            creation_guard.disarm();
            return Err(e);
        }
        // An agent's create warms nothing: the pool is the person's (`pool/`).
        if adopt.is_none() && starter.is_none() {
            self.pool_note_used(&session, claimable);
        }
        creation_guard.disarm();
        Ok(session)
    }

    /// A chat `starter` started, held to it as it is now (`start_mode.rs`, "Inherit"): an
    /// inherited policy (`inherits_policy`) laxer than the starter's is narrowed to it, and a
    /// harness whose mode the inheritance chose (`mode_eligible`) moved, else refused. The
    /// starter is read again after each round: one that changed meanwhile is held to again, and
    /// one that keeps changing refuses the start.
    async fn hold_to_starter(
        self: &Arc<Self>,
        session: &Arc<Session>,
        starter: Option<&str>,
        inherits_policy: bool,
        mode_eligible: bool,
    ) -> Result<(), RpcError> {
        const ROUNDS: usize = 4;
        let live = || {
            let theirs = starter.and_then(|id| self.resolve(id).ok().filter(|s| s.id == id));
            theirs.map(|s| s.meta())
        };
        let level = |m: &SessionMeta| (m.permission_policy.clone(), crate::web_modes::mode_of(m));
        for _ in 0..ROUNDS {
            let Some(theirs) = live() else { return Ok(()) };
            if inherits_policy && self.policy_set_laxer(&session.meta(), &theirs).await {
                let narrowed = self.set_policy_of(&theirs).await;
                self.set_policy(session, narrowed).await;
            }
            if mode_eligible {
                self.hold_mode(&theirs, session).await?;
            }
            if live().is_none_or(|now| level(&now) == level(&theirs)) {
                return Ok(());
            }
        }
        Err(super::subsession_guard::refusal(
            "start.starter_changing",
            "session/new refused: the session that started this one kept changing its permissions while it started; start it again".into(),
            json!({"starter": starter}),
        ))
    }

    pub(super) fn unique_name(&self, agent: &str) -> String {
        unique_name_among(&self.sessions.lock().unwrap(), &self.evicted.names(), agent)
    }

    /// The session's agent, for a request that came when the session had been stopped `stops`
    /// times ([`Session::stops`]): a stopped session reopens for it, and a stop since then ends
    /// the agent it started (`acpmux session stop` must leave it closed, ergo-walk2).
    pub(super) async fn ensure_child(
        self: &Arc<Self>,
        session: &Arc<Session>,
        profile: &super::spawn::Spawn,
        stops: u64,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        // MDM's off as this start begins: its one read, before it waits on anything (review 123),
        // which every check of the start takes, so an off that comes and goes while it starts
        // still holds for it (reviews 73, 75 and 77 of #23322).
        let off = self.off_latch();
        #[cfg(test)]
        super::full_access_bound::operation_entry(self);
        // Harness startup can itself run repository hooks and write files. A harness that gates
        // every tool on the sync itself starts at the repository's head (repo_sync.rs).
        let head_ok = super::repo_sync::gates_its_tools(profile);
        let cwd = session.meta().cwd;
        let _repo_ready = super::repo_sync::wait_for_start(session, cwd, head_ok, || {
            session.stops.load(Ordering::SeqCst) != stops
        })
        .await?;
        // One spawn at a time per session; a caller that waited here finds
        // the child the previous holder started. The idle pass never ends the harness meanwhile.
        self.touch(session);
        let _using = session.harness_use.read().await;
        let _spawning = self.spawn_lease(session).await;
        // Stopped since the request: it starts nothing and touches no agent. One a later request
        // started after the stop is that request's (it reopened the session).
        // A chat being deleted starts nothing either, whatever stop count its request read
        // (`Session::purging`).
        if session.stops.load(Ordering::SeqCst) != stops || session.purging.load(Ordering::SeqCst) {
            return Err(stopped_while_starting());
        }
        // A start its policy refused, with nothing it depends on changed since, fails as it did and
        // starts nothing (`policy_mode.rs` `RefusalLatch`): no harness, no log line per wake.
        let refusal_key = super::policy_mode::refusal_key(
            &session.meta(),
            self.config.read().await.permission_policy,
            &profile.launch_digest,
        );
        // Only while nothing of the chat still runs: an agent or host a failed stop left behind is
        // reached below, which ends or adopts it and holds it to the policy again (review F1).
        // A harness that exited while it started, with the same error again, is not started
        // again on every wake until its window passed (`launch_backoff.rs`).
        let held = session.policy_refusal.held(&refusal_key);
        let held = held.or_else(|| session.launch_backoff.held(std::time::Instant::now()));
        if let Some(e) = held {
            let child = session.child.lock().await.clone();
            let alive = match child {
                Some(child) => child.is_alive().await,
                None => false,
            };
            if !alive && !Self::host_record_live(&session.id) {
                return Err(e);
            }
        }
        // A transcript a cloud offload removed comes back before the agent resumes from it
        // (`transcript_offload.rs`): one `stat` when none ever was.
        self.restore_transcripts(session).await;
        // Boxed: a start is a deep future, and the stack a caller polls it on is not.
        let wake = self.wake_began(session);
        let child = match Box::pin(self.reach_or_start(session, profile, stops, &off)).await {
            Ok(child) => child,
            Err(e) if super::policy_mode::is_unenforceable(&e) => {
                // Keyed by the chat as the refused start left it (its agent reports its mode).
                let key = super::policy_mode::refusal_key(
                    &session.meta(),
                    self.config.read().await.permission_policy,
                    &profile.launch_digest,
                );
                if session.policy_refusal.hold(key, &e) {
                    tracing::warn!(session = %session.id, "not started until its policy, mode or harness changes or the person writes to it: {}", e.message);
                }
                self.wake_ended(session, wake, Some(&e));
                return Err(e);
            }
            Err(e) => {
                self.wake_ended(session, wake, Some(&e));
                if super::launch_backoff::is_launch_failure(&e)
                    && let Some((fails, hold)) =
                        session.launch_backoff.failed(&e, std::time::Instant::now())
                {
                    tracing::warn!(session = %session.id, fails, hold_secs = hold.as_secs(), "the same launch failure again: not started for {}s unless the person writes to it: {}", hold.as_secs(), e.message);
                }
                return Err(e);
            }
        };
        // Stopped while this agent started (no other start can run while this one holds the
        // spawn lock): the stop found no agent to end yet, or the start went on after it. The
        // agent is ended here and the session stays closed.
        if session.stops.load(Ordering::SeqCst) != stops
            || session.status() == SessionStatus::Closed
            || session.purging.load(Ordering::SeqCst)
        {
            if let Some(started) = session.child.lock().await.take() {
                started.terminate(super::shutdown::SHUTDOWN_GRACE).await;
            }
            if Self::host_record_live(&session.id) {
                self.end_unadopted_host(session).await;
            }
            child.kill().await;
            // A chat deleted while this agent started: what the start made after the delete
            // removed the chat's own goes too (its temporary folder, its caller token, its MCP
            // config), or it outlived the chat.
            if session.purging.load(Ordering::SeqCst) {
                self.forget_start_leftovers(session).await;
            }
            session.loading.store(false, Ordering::SeqCst);
            // As `kill` left it: a start above may have cleared it.
            session.closing.store(true, Ordering::SeqCst);
            self.append(session, "mux", "stopped_while_starting", json!({}));
            let e = stopped_while_starting();
            self.wake_ended(session, wake, Some(&e));
            return Err(e);
        }
        self.wake_ended(session, wake, None);
        session.launch_backoff.clear();
        // The start is over: its harness runs at its CPU class from now on (`cpu_class.rs`); an
        // AutoCloud-placed chat at the background class, below the owner's own work.
        child.enter_run_class(session.read_meta(|m| m.placed_by.is_some())).await;
        // A Codex that went ahead at the head but started without the repository hook gets no
        // prompt before the whole checkout is in (repo_sync.rs).
        if super::repo_sync::start_waits_for_all(head_ok, profile, &child) {
            let _repo_ready = super::repo_sync::wait(session, session.meta().cwd, || {
                session.stops.load(Ordering::SeqCst) != stops
            })
            .await?;
        }
        Ok(child)
    }

    /// What an agent start of `session` writes beside the chat's own folder, removed again for a
    /// start that ended because the chat is being deleted (`ensure_child`): the delete may have
    /// removed them before the start wrote them.
    async fn forget_start_leftovers(&self, session: &Session) {
        crate::agent_tools::remove_mcp_config(&crate::config::home(), &session.id);
        self.caller_registry.forget(&session.id);
        #[cfg(unix)]
        {
            let id = session.id.clone();
            let _ =
                tokio::task::spawn_blocking(move || crate::agent::session_tmp::remove_session(&id))
                    .await;
        }
    }

    /// A creation that failed (`new_session`) leaves no session behind, unless a stop came
    /// during it and a request after that stop reopened the session: that one is the later
    /// request's, and its agent keeps running. The spawn lock, which every reopen holds
    /// (`ensure_child`), is held from the read to the end of the purge (`kill` never takes it).
    pub(super) async fn discard_failed_creation(&self, session: &Arc<Session>, created_stops: u64) {
        let inline = self.inline_btw_owner(session);
        self.discard_failed_creation_owned(session, created_stops, inline).await;
    }

    /// The inline `/btw` request's mark on this session (`btw.rs` `InlineOwned`), if any.
    pub(super) fn inline_btw_owner(&self, session: &Session) -> Option<super::InlineBtwOwner> {
        self.inline_btw
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&session.meta().name)
            .cloned()
    }

    /// `discard_failed_creation` with the inline owner already read: an inline /btw's
    /// session takes its harness transcript with it.
    pub(super) async fn discard_failed_creation_owned(
        &self,
        session: &Arc<Session>,
        created_stops: u64,
        inline: Option<super::InlineBtwOwner>,
    ) {
        if session.purged.load(Ordering::SeqCst) {
            return;
        }
        let _spawning = session.spawn_lock.lock().await;
        // A cancelled creation may be cleaned up long after an import or another
        // creation took its id. Its guard owns this Arc, never the new incarnation.
        if session.purged.load(Ordering::SeqCst)
            || session.replaced.load(Ordering::SeqCst)
            || !self
                .sessions
                .lock()
                .unwrap()
                .get(&session.id)
                .is_some_and(|current| Arc::ptr_eq(current, session))
        {
            return;
        }
        let reopened_since = session.stops.load(Ordering::SeqCst) != created_stops
            && session.status() != SessionStatus::Closed;
        if !reopened_since {
            // An inline /btw's session takes its harness transcript with it (`btw.rs`).
            match inline {
                Some((family, env)) => Box::pin(self.btw_cleanup(session, &family, &env)).await,
                None => {
                    let _ = self.kill(session, true).await;
                }
            }
        }
    }

    /// A stopped session reopens for a request that came after its last stop (`ensure_child`);
    /// one stopped since refuses the start.
    pub(super) fn reopen_to_start(&self, session: &Session, stops: u64) -> Result<(), RpcError> {
        if let Some(to) = session.meta().moved_to {
            return Err(super::transfer_out::moved_error(&to));
        }
        if session.status() == SessionStatus::Closed && !self.reopen(session, stops) {
            return Err(stopped_while_starting());
        }
        Ok(())
    }

    /// Before an agent start: a start under way ends `closing`, unless a stop came since the
    /// start's request (it stays set for that stop, `ensure_child`).
    fn starting(session: &Session, stops: u64) {
        if session.stops.load(Ordering::SeqCst) == stops {
            session.closing.store(false, Ordering::SeqCst);
        }
    }

    /// `ensure_child` under `spawn_lock`: the live agent, the agent host reached again, a pooled
    /// session or a cold start.
    async fn reach_or_start(
        self: &Arc<Self>,
        session: &Arc<Session>,
        profile: &super::spawn::Spawn,
        stops: u64,
        off: &super::full_access_bound::OffLatch,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        if self.shutting_down() {
            return Err(super::shutdown::shutting_down_error());
        }
        self.refuse_cleared_host(session).await?;
        // MDM forces full access off (#23322): an agent still in it, live or left by a restart,
        // ends here and is never reached again; the start below asks, or refuses a pinned profile.
        // A host whose end failed may still run in it: the chat is refused until it ends (review 51).
        // Under the start's one read of the off (`off`).
        if self.end_if_runs_full_access(session, off.off()).await == FullAccessEnd::StillRunning {
            return Err(super::start_mode::full_access_off());
        }
        let live = session.child.lock().await.clone();
        if let Some(child) = live
            && child.is_alive().await
        {
            // A closed session with a live agent: a host the daemon adopted at its start that
            // outlived the stop. It reopens for this request, ready.
            if session.status() == SessionStatus::Closed {
                self.reopen_to_start(session, stops)?;
                self.set_status(session, NotWaiting::Ready);
            }
            return Ok(child);
        }
        // A running agent host for this session is reached again, never
        // started or initialized a second time.
        if Self::host_record_live(&session.id) {
            Self::starting(session, stops);
            // A stopped session whose host outlived the stop reopens, as a cold start does.
            self.reopen_to_start(session, stops)?;
            match self.readopt(session).await {
                Some(child) if child.is_alive().await => {
                    // Reached again, not started: no start below decides its Ctrl-B.
                    self.note_host_kind(session, &child, Some(profile.kind)).await;
                    return Ok(child);
                }
                // The host ended meanwhile: start a fresh agent below.
                _ if !Self::host_record_live(&session.id) => {}
                // Live but unreachable even after a reconnect: end it (nonce
                // proof) and start a fresh agent, so the session never locks.
                _ => {
                    self.end_unadopted_host(session).await;
                    if Self::host_record_live(&session.id) {
                        return Err(RpcError::internal(
                            "this session's agent host is still running, cannot be reached and did not end; close the session to end it",
                        ));
                    }
                    self.append(session, "mux", "host_unreachable_ended", json!({}));
                }
            }
        }

        // Every start below (pooled, cold, resumed, a fork or sub-session) runs this profile.
        if let Err(e) = self.refuse_pinned_full_access(off, profile) {
            self.append(session, "mux", "full_access_refused", json!({}));
            return Err(e);
        }
        let current = self.opencode_ask_now(session, profile).await;
        let profile = current.as_ref().unwrap_or(profile);
        self.record_spawn_inputs(session, profile).await;
        // What the agent runs is this argv, not the creation's (`FullAccessView::of_session`). On
        // disk before the agent starts: a daemon that dies while it starts leaves a host the next
        // one judges by this argv (review 44 of #23322). Not left to the folder check's save, which
        // a slow git read skips.
        // So is the digest of the profile it starts from (`profile_respawn.rs`): an agent host
        // the next daemon adopts is judged by it, and this start settles a respawn that waited.
        let argv_changed = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let changed = m.spawn_argv.as_ref() != Some(&profile.argv)
                || m.launch_digest.as_ref() != Some(&profile.launch_digest);
            // What another launch's agent said at `initialize` (a fork's or a failover's copy)
            // is not this one's: an `asksBeforeTools` claim must come from the agent this start
            // runs (`policy_mode.rs` `claim_distrust`), which `initialize` records again.
            if m.launch_digest.as_ref() != Some(&profile.launch_digest) {
                m.agent_capabilities = None;
            }
            m.spawn_argv = Some(profile.argv.clone());
            m.launch_digest = Some(profile.launch_digest.clone());
            changed
        };
        self.settle_profile_respawn(session);
        if argv_changed {
            self.save_meta(session);
        }
        *session.launch_env.lock().unwrap_or_else(|e| e.into_inner()) = Some(profile.env.clone());
        let moves = super::processes::backgrounds_work(profile.kind);
        session.backgrounds_work.store(moves, Ordering::SeqCst);
        // A fresh agent: what acpmux set on the last one is replayed, not assumed.
        self.fresh_agent(session, profile);
        Self::starting(session, stops);
        // A pooled session claimed for this id (`pool/`): its host already
        // runs with the harness initialized and its session created.
        // The name its Claude Code was started under (`--name`), before the claim is taken.
        let pooled_name = self.pool_claimed_name(&session.id);
        if let Some(pooled) = self.pool_take_claimed_for(&session.id, profile, &session.meta(), off)
        {
            #[cfg(debug_assertions)]
            self.take_off_seam();
            // Reopened before it is taken, so the pooled start's Ready lands on an open session.
            if let Err(e) = self.reopen_to_start(session, stops) {
                super::pool::end_pooled(pooled).await;
                return Err(e);
            }
            let reported_off = pooled.reported_off();
            // The chat judges the entry under MDM's off as the entry saw it too, from its start
            // and its claim on (review 122 of #23322): an off it lived through holds for the take,
            // the report check and the cap, though an unset followed.
            let off = off.merge(&pooled.lived_off());
            match self.adopt_pooled(session, pooled).await {
                // MDM forces full access off (#23322, reviews 71 and 77): a report of full access
                // held past the take's check may not have reached the chat when its start is
                // capped, and one made while the off held counts though it is unset by now.
                Ok((_, reported))
                    if reported_off.load(Ordering::SeqCst) || (reported && off.off()) =>
                {
                    self.stop_full_access_agent(session, true).await;
                    return Err(super::start_mode::full_access_off());
                }
                // A harness whose own settings started it in full access: capped like a cold
                // start, under the same budget. Its `session/set_mode` would otherwise wait
                // forever on a harness that stays alive but never answers, holding `spawn_lock`.
                Ok((child, _)) => {
                    // Taken under another name than it started with: its Claude Code takes it.
                    if pooled_name.is_some_and(|n| n != session.meta().name) {
                        self.rename_live_claude(session);
                    }
                    let budget = self.config.read().await.agent_start_timeout();
                    return match tokio::time::timeout(
                        budget,
                        self.cap_full_access(session, &child, profile, &off),
                    )
                    .await
                    {
                        Ok(result) => {
                            result.map(|()| self.keep_account_home(session, profile, child))
                        }
                        Err(_) => {
                            let harness = Self::starting_harness(session).await;
                            self.abandon_cold_start(session, budget).await;
                            Err(start_deadline_exceeded(budget, &harness))
                        }
                    };
                }
                // Not promotable: it was ended; start cold below.
                Err(e) => tracing::warn!(session = %session.id, "pooled session not taken: {e:#}"),
            }
        }

        // A cold start is bounded (cx-m5up): an agent that stays alive but
        // never answers `initialize`, `session/load` or `session/new` would
        // otherwise hold `spawn_lock`, and every later request of this
        // session, forever. Re-adoption and pool adoption above keep their
        // own bounds: they serve agents that may be mid-turn.
        let budget = self.config.read().await.agent_start_timeout();
        let mut retried = false;
        loop {
            // Boxed: a cold start is a deep future, and this loop keeps it beside the retry's
            // state on the stack its caller polls it on.
            let started = Box::pin(self.cold_start(session, profile, stops, off));
            // The person's start has no deadline, nor has one that asked to wait on its harness:
            // both end when the harness stops working (`waiting_start`, `StartWatch`); an
            // agent's or a lane's has a deadline.
            let hung_after = *self.start_hung.lock().unwrap_or_else(|e| e.into_inner());
            let waited = async {
                if waits_on_harness(session) {
                    let watch = StartWatch::after(hung_after);
                    self.waiting_start(session, budget, started, Some(watch)).await
                } else {
                    tokio::time::timeout(budget, started).await.ok()
                }
            };
            // A retry's start ends at its turn's Stop (`start_retry.rs`), however it waits (the
            // person may have taken the chat since its first try), as any start ends at a stop
            // of the chat: what it started is ended, and nothing runs after it.
            let raced = tokio::select! {
                started = waited => Some(started),
                () = super::start_retry::stopped_during_retry(session) => None,
            };
            let Some(started) = raced else {
                self.end_cold_start(session).await;
                self.append(session, "mux", "agent_start_stopped", json!({}));
                return Err(super::turns::stopped_before_prompt());
            };
            let failed = match started {
                Some(Ok(child)) => return Ok(self.keep_account_home(session, profile, child)),
                Some(Err(e)) => Some(e),
                None => None,
            };
            // What its harness was doing, read before it is ended (`cpu_class.rs`).
            let harness = Self::starting_harness(session).await;
            // A start that failed with its harness at background class anyway (set again during
            // the start by another process: acpmux clears it at the spawn) runs once more
            // (`cpu_class.rs`, item 3). Each try has the whole budget: a caller waits up to twice
            // that (Chief's `SESSION_NEW_DEADLINE`).
            // A start that waits on its harness ends with None only when its harness did no work
            // for `START_HUNG` (`StartWatch`): said apart from a missed deadline, so its caller
            // does not wait on it again; Chief starts a fresh harness (`turn::is_hung_start`).
            let hung = waits_on_harness(session);
            // A policy refusal is no start failure: the same agent would be refused again.
            let refused = failed.as_ref().is_some_and(|e| {
                e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str)
                    == Some("policy_unenforceable")
            });
            if let Some(state) = harness.background().filter(|_| !retried && !refused) {
                self.end_cold_start(session).await;
                let why = match (&failed, hung) {
                    (Some(_), _) => "failed",
                    (None, true) => "did no work",
                    (None, false) => "missed its deadline",
                };
                tracing::warn!(session = %session.id, "the agent start {why} at background CPU class ({state}); starting it once more");
                self.append(
                    session,
                    "mux",
                    "agent_start_retried_at_normal",
                    json!({"timedOut": failed.is_none() && !hung, "hung": failed.is_none() && hung, "harness": state}),
                );
                retried = true;
                continue;
            }
            return Err(match failed {
                Some(e) => e,
                None => {
                    self.abandon_cold_start(session, budget).await;
                    if hung {
                        start_hung(&harness, hung_after)
                    } else {
                        start_deadline_exceeded(budget, &harness)
                    }
                }
            });
        }
    }

    pub(super) fn absorb_session_response(&self, session: &Session, v: &Value) {
        let present = |k: &str| v.get(k).filter(|x| !x.is_null()).cloned();
        let mut writes = Vec::new();
        writes.extend(present("modes").map(ModeWrite::Modes));
        writes.extend(present("configOptions").map(ModeWrite::ConfigOptions));
        self.write_mode_state(session, writes);
        if let Some(models) = present("models") {
            session.meta.lock().unwrap().models = Some(models);
        }
    }

    /// How many requests wait on the agent of the session `key` now; None when it has none
    /// running.
    pub async fn agent_pending_requests(&self, key: &str) -> Option<usize> {
        let session = self.resolve(key).ok()?;
        let child = session.child.lock().await.clone()?;
        Some(child.pending_requests().await)
    }

    /// How many client requests this hub's connections serve now, each holding its work slot
    /// on its connection (`server/in_flight.rs`): a cancelled one leaves at once.
    pub fn requests_in_flight(&self) -> usize {
        self.requests_in_flight.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub(super) async fn child_for(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        // A step of a request that read the count earlier (`REQUEST_STOPS`), else now.
        let stops = REQUEST_STOPS
            .try_with(|(id, stops)| (*id == session.id).then_some(*stops))
            .ok()
            .flatten()
            .unwrap_or_else(|| session.stops.load(Ordering::SeqCst));
        self.child_for_since(session, stops).await
    }

    /// `child_for` for a request that came when the session had been stopped `stops` times
    /// ([`Session::stops`], `ensure_child`).
    pub(super) async fn child_for_since(
        self: &Arc<Self>,
        session: &Arc<Session>,
        stops: u64,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        // A live full-access harness may execute tools without permission RPCs.
        // Wait before handing it a new prompt, including the already-live path; one that gates
        // every tool on the sync itself gets its prompt at the repository's head (repo_sync.rs).
        // A running agent is judged by what it speaks (a reload may change the profile's harness
        // without replacing it); one started below waits again in `ensure_child`, by its profile.
        let live = session.child.lock().await.clone();
        let head_ok = match live {
            Some(child) => super::repo_sync::child_gates_its_tools(&child),
            None => {
                let meta = session.meta();
                let cfg = self.config.read().await;
                super::resolve::session_profile(&cfg, &meta.harness, &meta.cwd, meta.remote_origin)
                    .is_ok_and(|p| super::repo_sync::gates_its_tools(&p))
            }
        };
        let cwd = session.meta().cwd;
        let _repo_ready = super::repo_sync::wait_for_start(session, cwd, head_ok, || {
            session.stops.load(Ordering::SeqCst) != stops
        })
        .await?;
        // A watched chat starts no agent until Take Over: every lazy start (warm, model, mode, fork).
        if session.meta().watching.is_some() {
            return Err(super::watch::read_only());
        }
        // `ensure_child` publishes the child before `initialize` and
        // `session/load` answer (the inbound loop needs it to answer the
        // agent's own requests meanwhile). A live child is ready only while
        // no start holds the spawn lock; otherwise wait for that start below.
        // A closed session, or one stopped since the request, goes through `ensure_child`.
        // Under MDM's off, a host whose replay is not all in the log is not handed out here either:
        // `ensure_child` judges it first, as the off's teardown does (review 3 of #26057).
        let off = self.off_latch();
        if session.status() != SessionStatus::Closed
            && session.stops.load(Ordering::SeqCst) == stops
            && let Ok(_idle) = session.spawn_lock.try_lock()
            && !self.managed_off_runs_full_access(&off, session)
            && let Some(child) = session.child.lock().await.as_ref()
            && child.is_alive().await
            && !(off.off() && child.replay_pending())
            // Under MDM's off an agent whose reader stopped is not heard: `ensure_child` ends it
            // (`host_unheard`, review 68 of #23322).
            && !(child.is_stopped() && self.full_access_managed_off())
        {
            return Ok(child.clone());
        }
        // Its own host first, when one ran at the start (a second agent would take its turn),
        // then what any agent start needs; never every other chat's adoption (`startup.rs`).
        self.wait_adopted(session).await;
        self.wait_spawn_ready().await;
        let meta = session.meta();
        let agent = meta.harness.clone();
        let (profile, defaults) = {
            let cfg = self.config.read().await;
            let profile =
                super::resolve::session_profile(&cfg, &agent, &meta.cwd, meta.remote_origin)
                    .map_err(RpcError::invalid_params)?;
            (profile, cfg.defaults_for(&agent))
        };
        let digest = profile.launch_digest();
        let spawn = self.spawn_profile(session, &profile, digest, &defaults.env).await?;
        self.ensure_child(session, &spawn, stops).await
    }
}

tokio::task_local! {
    /// The session a request is for and its stop count ([`Session::stops`]) when the request
    /// came, for the request's later steps (`new_session` sets the defaults a new chat starts
    /// with through `set_model`, `set_config`, `set_mode`): `child_for` fences them with it.
    pub(super) static REQUEST_STOPS: (String, u64);
}

/// An agent start that a stop (`acpmux session stop`) came after the request for.
pub(super) fn stopped_while_starting() -> RpcError {
    RpcError::invalid_params("the session was stopped while its agent started")
}

/// Under the publication lock, refuse every existing durable path, including a
/// partial creation, corrupt metadata or a symlink. Never turn a read error into
/// permission to overwrite a chat. Memory stores use their metadata instead.
fn refuse_stored_fixed_id(store: &dyn crate::store::Store, id: &str) -> Result<(), RpcError> {
    let taken = if let Some(path) = store.session_path(id) {
        match std::fs::symlink_metadata(path) {
            Ok(_) => true,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
            Err(error) => {
                return Err(RpcError::internal(format!("read fixed session id: {error}")));
            }
        }
    } else {
        store.load(id).map_err(|error| RpcError::internal(error.to_string()))?.is_some()
    };
    if taken {
        return Err(RpcError::invalid_params(format!(
            "session id {id:?} already exists in the store"
        )));
    }
    Ok(())
}

#[cfg(test)]
#[path = "fixed_id_tests.rs"]
mod fixed_id_tests;

#[cfg(test)]
#[path = "stop_fence_tests.rs"]
mod stop_fence_tests;

#[cfg(test)]
#[path = "probe_off_tests.rs"]
mod probe_off_tests;

#[cfg(test)]
#[path = "taken_name_tests.rs"]
mod taken_name_tests;

/// The agent messages of a `session/load` (or a Claude fork's prime) never reach the session's
/// preview, so its `lastMessage` stays the chat's own newest reply, as `wait --print` reads it
/// from the log. ACP answers a load once its history is sent, and every reader (direct, Codex
/// bridge, agent host, a pooled agent's hold) queues an agent's notifications in order before
/// it resolves the answer, so the `ReplayDone` that `end` queues lands behind the whole replay,
/// and before the next prompt is even written. The hold names the agent's generation: another
/// agent's updates and markers never touch it. A start abandoned mid-load never ends it, so
/// what that agent still had queued stays out of the preview as well, beside the next agent's
/// own hold (`Session::replaying` keeps both).
struct ReplayHold<'a> {
    session: &'a Session,
    agent: &'a crate::agent::ChildAgent,
}

impl<'a> ReplayHold<'a> {
    fn start(session: &'a Session, agent: &'a crate::agent::ChildAgent) -> Self {
        session.replaying.lock().unwrap_or_else(|e| e.into_inner()).push(agent.generation);
        Self { session, agent }
    }

    /// Lifts the hold once the inbound loop reaches what the agent sent so far; at once when
    /// its queue is closed (nothing more can arrive).
    async fn end(self) {
        if !self.agent.queue_replay_done().await {
            self.session.end_replay(self.agent.generation);
        }
    }
}

/// Whether `session`'s start waits on its harness instead of a deadline: the person's
/// (`Session::person`), or one that asked to (`Session::wait_start`). Either ends when its harness
/// does no work for `START_HUNG` (`StartWatch`).
fn waits_on_harness(session: &Session) -> bool {
    session.person.load(Ordering::SeqCst) || session.wait_start.load(Ordering::SeqCst)
}
