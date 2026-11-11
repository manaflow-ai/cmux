//! Part of `Hub`; see `hub/mod.rs`.

use super::full_access_bound::FullAccessEnd;
use super::policy_mode::refusal_record;
use super::*;

use super::adoption::{Adoption, adopted_in, start_folder};
use super::new_request::{claude_resume_refusal, unique_name_among};
// `turns.rs` names it here.
pub(super) use super::new_request::profile_takes_model_at_spawn;
use super::resolve::{Draft, Resolved, draft_meta};
use super::start_watch::{StartWatch, start_deadline_exceeded, start_hung};

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
        // Harness discovery and launcher checks finish in the background. Bounded: a startup that
        // never ends (a wedged agent host's adoption) answers with its phase, not silence.
        self.wait_startup_within(super::startup::NEW_SESSION_STARTUP_WAIT).await?;
        // Mutations wait for the complete index. A later durable check also refuses
        // malformed or partially written chats that the startup loader could not install.
        if caller_selected_id {
            self.wait_store().await;
        }
        let NewRequest {
            harness,
            preset,
            name,
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
            person,
            wait_start,
            require_asking,
        } = req;
        // The proven agent session that asked for this one, as it is now; never for a remote
        // chat, and never one a remote connection started (`remote_origin`).
        let starter = starter
            .filter(|_| !remote)
            .and_then(|id| self.resolve(&id).ok().filter(|s| s.id == id))
            .filter(|s| !s.meta().remote_origin)
            .map(|s| s.id.clone());
        // An adopted session's harness names the head unless one was given.
        let harness = harness.or_else(|| adopt.as_ref().and_then(|a| a.harness.clone()));
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
        meta.workspace_id = workspace_id;
        meta.additional_directories =
            super::additional_dirs::without_cwd(additional_directories, &meta.cwd);
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
        // for the person's next chat, which never waits behind a lane's start.
        let claimable = fixed_id.is_none()
            && adopt.is_none()
            && starter.is_none()
            && meta.session_env.is_empty()
            && route.is_none()
            && meta.tools.off.is_empty()
            && meta.additional_directories.is_empty()
            && checked_cwd.is_none();
        let pooled =
            if claimable { self.pool_claim(&meta, &profile, &defaults.env).await } else { None };
        // Every way out of here (an error, or this future dropped) before
        // `ensure_child` took the entry puts it back or ends it.
        let _claim = pooled.as_ref().map(|id| self.pool_claim_guard(id.clone()));
        let id =
            fixed_id.unwrap_or_else(|| pooled.unwrap_or_else(|| uuid::Uuid::now_v7().to_string()));
        meta.id = id.clone();
        // A named route is checked before anything is created: it exists and
        // serves this chat's harness family.
        if let Some(route_id) = &route {
            self.check_new_route(route_id, &family).await?;
        }
        let stores = super::adoption::store_families(&*self.config.read().await);
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
                    if sessions.values().any(|s| s.meta().name == n) {
                        return Err(RpcError::invalid_params(format!(
                            "session name {n:?} is taken"
                        )));
                    }
                    // The name is a handle (a lane's): the chat is still titled (`titles.rs`).
                    meta.title_source = Some(super::titles::LAUNCHED.to_owned());
                    meta.name_given = true;
                    n
                }
                // A pooled harness was started under its name: keep it.
                None => match self
                    .pool_claimed_name(&id)
                    .filter(|n| !sessions.values().any(|s| s.meta().name == *n))
                {
                    Some(n) => n,
                    None => unique_name_among(&sessions, agent),
                },
            };
            meta.wait_start = wait_start;
            let session = self.make_session(meta);
            session.person.store(person, Ordering::SeqCst);
            *session.fork_from.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                fork_from.clone();
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
        // A session that came may be another row's parent: every closed row is built again.
        self.events.changed();
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
            if let Some(e) = &effort {
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
            super::policy_mode::require_enforced(&session.meta(), &cfg)?;
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
        unique_name_among(&self.sessions.lock().unwrap(), agent)
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
        let head_ok = super::repo_sync::gates_its_tools(profile.kind);
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
        if session.stops.load(Ordering::SeqCst) != stops {
            return Err(stopped_while_starting());
        }
        // Boxed: a start is a deep future, and the stack a caller polls it on is not.
        let wake = self.wake_began(session);
        let child = match Box::pin(self.reach_or_start(session, profile, stops, &off)).await {
            Ok(child) => child,
            Err(e) => {
                self.wake_ended(session, wake, Some(&e));
                return Err(e);
            }
        };
        // Stopped while this agent started (no other start can run while this one holds the
        // spawn lock): the stop found no agent to end yet, or the start went on after it. The
        // agent is ended here and the session stays closed.
        if session.stops.load(Ordering::SeqCst) != stops
            || session.status() == SessionStatus::Closed
        {
            if let Some(started) = session.child.lock().await.take() {
                started.terminate(super::shutdown::SHUTDOWN_GRACE).await;
            }
            if Self::host_record_live(&session.id) {
                self.end_unadopted_host(session).await;
            }
            child.kill().await;
            session.loading.store(false, Ordering::SeqCst);
            // As `kill` left it: a start above may have cleared it.
            session.closing.store(true, Ordering::SeqCst);
            self.append(session, "mux", "stopped_while_starting", json!({}));
            let e = stopped_while_starting();
            self.wake_ended(session, wake, Some(&e));
            return Err(e);
        }
        self.wake_ended(session, wake, None);
        // The start is over: its harness runs at its CPU class from now on (`cpu_class.rs`).
        child.enter_run_class().await;
        Ok(child)
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
                self.set_status(session, SessionStatus::Ready);
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
            // The person's start has no deadline, one that asked to wait on its harness ends when
            // the harness stops working (`waiting_start`); an agent's or a lane's has a deadline.
            let waited = async {
                if session.person.load(Ordering::SeqCst) {
                    self.waiting_start(session, budget, started, None).await
                } else if session.wait_start.load(Ordering::SeqCst) {
                    self.waiting_start(session, budget, started, Some(StartWatch::default())).await
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
            let hung =
                !session.person.load(Ordering::SeqCst) && session.wait_start.load(Ordering::SeqCst);
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
                        start_hung(&harness)
                    } else {
                        start_deadline_exceeded(budget, &harness)
                    }
                }
            });
        }
    }

    /// Its starting harness while the start itself is not being polled: the start may hold the
    /// locks this reads, so a held one answers None (nothing known this tick) rather than waiting.
    async fn harness_now(session: &Session) -> Option<crate::cpu_class::HarnessSeen> {
        let child = session.child.try_lock().ok()?.clone();
        let Some(child) = child else {
            return Some(crate::cpu_class::HarnessSeen::NotStarted);
        };
        tokio::time::timeout(std::time::Duration::from_secs(1), child.harness_seen()).await.ok()
    }

    /// Its starting harness, as a deadline error says it (`cpu_class::HarnessSeen`).
    async fn starting_harness(session: &Session) -> crate::cpu_class::HarnessSeen {
        let child = session.child.lock().await.clone();
        match child {
            Some(child) => child.harness_seen().await,
            None => crate::cpu_class::HarnessSeen::NotStarted,
        }
    }

    /// End what a failed cold start left before it is retried: as `abandon_cold_start`, with no
    /// event of its own (the retry logs one).
    async fn end_cold_start(self: &Arc<Self>, session: &Arc<Session>) {
        let started = session.child.lock().await.take();
        if let Some(child) = &started {
            child.terminate(super::shutdown::SHUTDOWN_GRACE).await;
        }
        if Self::host_record_live(&session.id) {
            self.end_unadopted_host(session).await;
        }
        session.loading.store(false, Ordering::SeqCst);
        if session.status() != SessionStatus::Closed {
            self.set_status(session, SessionStatus::Idle);
        }
    }

    /// The person's agent start (`Session::person`) has no deadline: a loaded host may take
    /// minutes, and Leo: "I TSHOULDN'T FUCKING MATTER IF MY COMPUTER IS LOADED" / "I SHOULD BE
    /// ALWAYS ABLE TO SATRT NEW FUCKGN CHATS". It ends only as the start does: answered, or failed
    /// because its harness exited, its spawn failed or a stop ended it. Every `START_PROGRESS`
    /// (sooner when `agentStartTimeoutMs` is shorter) its log says it is still starting
    /// (`agent_start_waiting`, `waitedMs`), so the app can show that the host is busy. An agent's
    /// or a lane's start keeps `agentStartTimeoutMs` (cx-m5up).
    ///
    /// A start that asked to wait on its harness (`Session::wait_start`) waits the same way under
    /// `watch`, and answers None when its harness stopped working (`StartWatch`), which the caller
    /// ends as a missed deadline.
    async fn waiting_start<T>(
        &self,
        session: &Arc<Session>,
        budget: std::time::Duration,
        start: impl std::future::Future<Output = T>,
        mut watch: Option<StartWatch>,
    ) -> Option<T> {
        let every = START_PROGRESS.min(budget).max(std::time::Duration::from_millis(100));
        let began = tokio::time::Instant::now();
        let mut tick = tokio::time::interval_at(began + every, every);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        tokio::pin!(start);
        let mut said = false;
        loop {
            tokio::select! {
                done = &mut start => return Some(done),
                _ = tick.tick() => {
                    let waited = began.elapsed();
                    if !said && waited >= budget {
                        said = true;
                        tracing::warn!(
                            session = %session.id,
                            "the agent start is past {budget:?}; it keeps waiting"
                        );
                    }
                    if let Some(watch) = &mut watch
                        && let Some(seen) = Self::harness_now(session).await
                        && watch.hung(&seen, waited)
                    {
                        tracing::warn!(session = %session.id, "the agent start's harness stopped working ({seen:?})");
                        return None;
                    }
                    let waited_ms = u64::try_from(waited.as_millis()).unwrap_or(u64::MAX);
                    let waiting = json!({"waitedMs": waited_ms});
                    self.append(session, "mux", "agent_start_waiting", waiting);
                }
            }
        }
    }

    /// End what a cold start that missed its budget left: the agent it
    /// spawned (in `session.child` or only as a live host record) and its
    /// half-way flags. The session stays open and idle; a later request
    /// starts the agent again.
    async fn abandon_cold_start(
        self: &Arc<Self>,
        session: &Arc<Session>,
        budget: std::time::Duration,
    ) {
        self.end_cold_start(session).await;
        self.append(
            session,
            "mux",
            "agent_start_timed_out",
            json!({"timeoutMs": u64::try_from(budget.as_millis()).unwrap_or(u64::MAX)}),
        );
    }

    /// The cold-start half of `ensure_child`, under `spawn_lock`: spawn the
    /// agent, initialize it, load or create its session, replay its config.
    async fn cold_start(
        self: &Arc<Self>,
        session: &Arc<Session>,
        profile: &HarnessProfile,
        stops: u64,
        off: &super::full_access_bound::OffLatch,
    ) -> Result<Arc<ChildAgent>, RpcError> {
        // Its worktree back if cleanup reclaimed it, and reopened if stopped.
        self.ready_to_start(session, stops).await?;
        let meta = session.meta();
        let tap = self.session_tap(session);
        let is_claude = profile.kind == crate::config::HarnessKind::ClaudeStdio;
        let mut existing_sid = session.meta().agent_session_id.clone();
        // Cleared only once the fork has started; a failed start retries it.
        let fork_from = session.fork_from.lock().unwrap().clone();
        // Resume a Claude conversation only from a store that has it: one
        // that never finished a turn may not be stored at all, and one that
        // another profile ran lives in that profile's store (a failover onto
        // a fallback with its own CLAUDE_CONFIG_DIR). Else a fresh one starts
        // with the restored transcript, never a turn failed on `--resume`.
        if is_claude
            && fork_from.is_none()
            && let Some(why) =
                existing_sid.as_deref().and_then(|sid| claude_resume_refusal(&meta, profile, sid))
            && let Some(sid) = existing_sid.take()
        {
            tracing::info!(session = %session.id, agent_session = %sid, "starting a fresh Claude conversation: {why}");
            // A chat woken from hibernation had no turn when it hibernated (`idle.rs` keeps one
            // with turns but none stored awake), so it has nothing to restore: it starts fresh
            // with no row and no restored transcript. (The prompt waking it is counted already.)
            let untouched = self.waking(session);
            if !untouched {
                self.append(
                    session,
                    "mux",
                    "resume_failed",
                    json!({"error": format!("Claude conversation {sid} {why}, so a fresh one starts")}),
                );
            }
            {
                let mut m = session.meta.lock().unwrap();
                m.set_agent_session_id(None, "claude");
                m.claude_unstored = false;
            }
            if !untouched {
                session.rehydrate.store(true, Ordering::SeqCst);
            }
        }
        // The --permission-mode acpmux started a Claude process in.
        let mut started_mode = None;
        // What a Claude process was started in: its profile's argv and the mode it was given.
        let mut spawned = super::full_access_bound::FullAccessView::default();
        let child = if is_claude {
            // Claude carries its own session in the process: resume by id, or
            // fork from a parent id into a fresh session.
            let (resume, fork) = match (&fork_from, &existing_sid) {
                (Some(parent), _) => (Some(parent.as_str()), true),
                (None, Some(sid)) => (Some(sid.as_str()), false),
                (None, None) => (None, false),
            };
            let fresh_id =
                if resume.is_none() { Some(uuid::Uuid::now_v7().to_string()) } else { None };
            let effort = current_effort(&meta).unwrap_or_else(|| "default".into());
            let fast = current_option(&meta, "fast-mode").as_deref() == Some("on");
            let suggestions = crate::claude_stdio::prompt_suggestions::chat_pick(current_option(
                &meta,
                crate::claude_stdio::prompt_suggestions::OPTION,
            ));
            let recap = current_option(&meta, crate::claude_stdio::RECAP_OPTION);
            let mode = meta
                .modes
                .as_ref()
                .and_then(|m| m.get("currentModeId"))
                .and_then(Value::as_str)
                // A Web start begins in Manual until the remote guard settles it.
                .unwrap_or(if meta.remote_origin {
                    "default"
                } else {
                    crate::claude_stdio::OWN_MODE
                })
                .to_owned();
            // A remote chain never runs in full access (remote_sandbox.rs),
            // even when a transfer moved a full-access chat here.
            let mode = if meta.remote_origin && mode == "bypassPermissions" {
                "default".to_owned()
            } else {
                mode
            };
            // Nor does any chat saved in full access while sessions.allowFullAccess is off.
            // A profile pinning --permission-mode keeps it (spawn_plan adds none), so its record does too.
            let saved_mode = mode.clone();
            let mode = if super::start_mode::profile_sets_mode(profile) {
                mode
            } else {
                super::start_mode::resumable_mode(mode, "default", off.allows_full_access())
            };
            if mode != saved_mode {
                tracing::info!(session = %session.id, "resume: full access is off; {saved_mode} runs as {mode}");
                self.write_mode_state(session, [ModeWrite::CurrentMode(json!(mode))]);
            }
            // Nor does a chat whose policy is narrower than approve-all start in a mode that never
            // asks (`policy_mode.rs`); a pinned argv mode is moved after the start.
            let default = self.config.read().await.permission_policy;
            let mode = match super::policy_mode::claude_spawn_mode(&meta, default, &mode) {
                Some(asking) => {
                    self.write_mode_state(session, [ModeWrite::CurrentMode(json!(asking))]);
                    asking
                }
                None => mode,
            };
            if !super::start_mode::profile_sets_mode(profile) {
                started_mode = Some(mode.clone());
            }
            spawned = super::full_access_bound::FullAccessView {
                argv: profile.argv.clone(),
                mode: Some(mode.clone()),
                ..Default::default()
            };
            let model = current_model(&meta).unwrap_or_else(|| "default".into());
            let plan = crate::claude_stdio::spawn_plan(
                profile,
                resume,
                fork,
                fresh_id.as_deref(),
                Some(&effort),
                &mode,
                Some(&model),
            );
            // The chat's Sources (`additional_dirs.rs`), at every start.
            let mut plan = plan;
            plan.args.extend(super::additional_dirs::claude_args(&meta));
            let (plan, profile) = self.remote_chain_plan(session, profile, plan).await?;
            // A fresh process was given its id; a resumed one already has it.
            let known = if fork { None } else { fresh_id.clone().or_else(|| existing_sid.clone()) };
            if self.agent_hosts_enabled() {
                let translator = crate::agent_host::TranslatorSpec {
                    acp_session_id: session.id.clone(),
                    mode: mode.clone(),
                    model: model.clone(),
                    effort: effort.clone(),
                    fast,
                    prompt_suggestions: suggestions,
                    recap: recap.clone(),
                    claude_session_id: known.clone(),
                };
                self.spawn_hosted_child(
                    session,
                    &profile,
                    &meta,
                    Some((plan.program.clone(), plan.args.clone())),
                    Some(translator),
                    tap,
                )
                .await?
            } else {
                let tr = crate::claude_stdio::Translator::new(
                    session.id.clone(),
                    &mode,
                    &model,
                    &effort,
                );
                *tr.fast.lock().await = fast;
                tr.prompt_suggestions.store(suggestions, std::sync::atomic::Ordering::SeqCst);
                tr.set_recap(recap.as_deref());
                if let Some(sid) = known {
                    *tr.session_id.lock().await = Some(sid);
                }
                let program = plan.program.clone();
                ChildAgent::spawn_with(
                    &meta.harness,
                    &profile,
                    &meta.cwd,
                    session.inbound_tx.clone(),
                    tap,
                    Some((plan.program, plan.args)),
                    Some(tr),
                    Some((&session.id, &meta.name)),
                )
                .await
                .map_err(|e| {
                    crate::launch_policy::spawn_error(e, |e| {
                        crate::recovery::spawn_failed(&e, &meta.harness, &program, &meta.cwd)
                    })
                })?
            }
        } else if self.agent_hosts_enabled() {
            self.spawn_hosted_child(session, profile, &meta, None, None, tap).await?
        } else {
            ChildAgent::spawn_with(
                &meta.harness,
                profile,
                &meta.cwd,
                session.inbound_tx.clone(),
                tap,
                None,
                None,
                Some((&session.id, &meta.name)),
            )
            .await
            .map_err(|e| {
                crate::launch_policy::spawn_error(e, |e| {
                    let program = profile.argv.first().map(String::as_str).unwrap_or_default();
                    crate::recovery::spawn_failed(&e, &meta.harness, program, &meta.cwd)
                })
            })?
        };
        // An agent with no host ends with this run, so no earlier run's token is its own
        // (`caller_registry.rs`).
        if !self.agent_hosts_enabled() {
            self.caller_registry.forget(&session.id);
        }
        // A direct start records the format its command was pinned to (a host's: hosts.rs).
        if let Some(format) = child.preview_format {
            self.record_preview_format(session, format);
        }
        {
            // The shutdown marks itself started, then takes each session's
            // child: checked under that lock, either the shutdown finds this
            // child or this spawn sees the shutdown and ends what it started.
            let mut slot = session.child.lock().await;
            if self.shutting_down() {
                drop(slot);
                child.terminate(super::shutdown::SHUTDOWN_GRACE).await;
                if child.host_record().is_some() {
                    self.end_unadopted_host(session).await;
                }
                return Err(super::shutdown::shutting_down_error());
            }
            *slot = Some(child.clone());
        }
        // A new harness runs none of the background subagents of one it replaced.
        self.end_background_subagents(session);
        // Nor has its sandbox refused anything yet (`harness_sandbox.rs`).
        self.harness_sandbox_recovered(session, "respawn");
        self.wake_idle_reaper();

        // Start the inbound loop for this session once.
        self.spawn_inbound_loop(session).await;

        let init = match child.request(method::INITIALIZE, super::pool::initialize_params()).await {
            Ok(v) => v,
            Err(e) => return Err(Self::explain_start_failure(session, e).await),
        };
        let supports_load = init
            .get("agentCapabilities")
            .and_then(|c| c.get("loadSession"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let steering = init
            .get("_meta")
            .and_then(|m| m.get("steering"))
            .and_then(|s| s.get("supported"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        session.steering.store(steering, Ordering::SeqCst);
        {
            let mut m = session.meta.lock().unwrap();
            m.agent_info = init.get("agentInfo").cloned();
            m.agent_capabilities = init.get("agentCapabilities").cloned();
            m.steering = steering;
        }
        // What it says about asking before its tools, and whether acpmux believes it.
        self.note_asks_claim(session).await;

        if is_claude {
            // MDM may have forced full access off since `ensure_child` checked the profile: the
            // process runs nothing, not even a fork's priming turn, in full access (review 31).
            self.refuse_started_in_full_access(session, off, &spawned).await?;
            // A forked process only learns its new id from system/init on the
            // first turn. Prime it then; fresh and resumed ids are known already.
            let known = child.claude_state().await.and_then(|state| state.session_id);
            if known.is_none() {
                let hold = ReplayHold::start(session, &child);
                session.loading.store(true, Ordering::SeqCst);
                let primed = child
                    .request(method::SESSION_PROMPT, json!({"sessionId": session.id, "prompt": [{"type": "text", "text": "This session was just forked. Reply with exactly: ready"}]}))
                    .await;
                session.loading.store(false, Ordering::SeqCst);
                hold.end().await;
                if let Err(e) = primed {
                    let e = Self::explain_start_failure(session, e).await;
                    return Err(RpcError::internal(format!("claude did not start: {}", e.message)));
                }
            }
            // A hosted agent's host that did not answer (the shutdown detached it, or it ended)
            // told nothing of its session: the start fails, never recording no id over the one
            // it was given and handing out an agent with none ("no agent session").
            let Some(state) = child.claude_state().await else {
                return Err(if self.shutting_down() {
                    super::shutdown::shutting_down_error()
                } else {
                    RpcError::internal("the agent host did not answer as its agent started")
                });
            };
            let (sid, modes, opts) = (state.session_id, state.modes, state.config_options);
            {
                let mut m = session.meta.lock().unwrap();
                let level = if fork_from.is_some() {
                    "fork"
                } else if existing_sid.is_some() {
                    "exact"
                } else {
                    "new"
                };
                m.set_agent_session_id(sid.clone(), "claude");
                m.claude_unstored = level == "new";
                if level != "exact" {
                    m.claude_profile = Some(m.harness.clone());
                }
                drop(m);
                self.write_mode_state(
                    session,
                    [ModeWrite::Modes(modes), ModeWrite::ConfigOptions(opts)],
                );
                if let Some(mode) = started_mode.as_deref() {
                    self.restore_mode_mark(session, mode);
                }
                if fork_from.is_some() {
                    session.fork_from.lock().unwrap().take();
                }
                if level != "new" {
                    self.append(
                        session,
                        "mux",
                        "resumed",
                        self.wake_marked(session, json!({"level": level})),
                    );
                }
            }
            // Nor is it handed out in full access by any form it now reports (`cap_full_access`).
            self.refuse_started_in_full_access(
                session,
                off,
                &super::full_access_bound::FullAccessView::of_session(session),
            )
            .await?;
            // A profile that pins its mode in argv (`--permission-mode`, a skip flag) started in it.
            // An agent that cannot keep the chat's policy is stopped and the start fails.
            let pinned = super::start_mode::profile_sets_mode(profile);
            if let Err(e) = self.hold_policy_mode(session, &child, pinned).await {
                let record = refusal_record(&e);
                self.stop_started_agent(session, false, "policy_refused", record).await;
                return Err(e);
            }
            self.set_status(session, SessionStatus::Ready);
            self.note_launch(session, &child);
            self.save_meta(session);
            let meta_now = session.meta();
            self.remember_models(&meta_now.harness, &meta_now);
            return Ok(child);
        }
        let existing = session.meta().agent_session_id;
        // What the user had chosen before; replayed after load or new.
        let saved = session.meta();
        let loaded = match existing {
            Some(sid) if supports_load => {
                let hold = ReplayHold::start(session, &child);
                session.loading.store(true, Ordering::SeqCst);
                let res = child
                    .request(
                        method::SESSION_LOAD,
                        self.acp_params(&session.id, &meta, profile, Some(&sid), &child),
                    )
                    .await;
                session.loading.store(false, Ordering::SeqCst);
                hold.end().await;
                match res {
                    Ok(v) => {
                        self.absorb_session_response(session, &v);
                        self.health.record_acp_auth_success(
                            &meta.harness,
                            "ACP session/load authenticated the harness",
                        );
                        self.append(
                            session,
                            "mux",
                            "resumed",
                            self.wake_marked(session, json!({"level": "exact"})),
                        );
                        true
                    }
                    Err(e) => {
                        tracing::warn!(session = %session.id, "session/load failed: {e}");
                        self.note_load_failed(session, &e);
                        if meta.harness == "cmux-harness" {
                            return Err(Self::explain_start_failure(session, e).await);
                        }
                        false
                    }
                }
            }
            Some(_) => false,
            None => false,
        };
        if !loaded {
            let had_history = session.meta().agent_session_id.is_some();
            let res = match child
                .request(
                    method::SESSION_NEW,
                    self.acp_params(&session.id, &meta, profile, None, &child),
                )
                .await
            {
                Ok(v) => v,
                Err(e) => return Err(Self::explain_start_failure(session, e).await),
            };
            let sid = res
                .get("sessionId")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::internal("session/new returned no sessionId"))?
                .to_owned();
            {
                let mut m = session.meta.lock().unwrap();
                m.set_agent_session_id(Some(sid), "non-claude");
            }
            self.absorb_session_response(session, &res);
            self.health.record_acp_auth_success(
                &meta.harness,
                "ACP session/new authenticated the harness",
            );
            if had_history {
                session.rehydrate.store(true, Ordering::SeqCst);
                self.append(
                    session,
                    "mux",
                    "resumed",
                    self.wake_marked(session, json!({"level": "rehydrate"})),
                );
            }
        }
        if saved.agent_session_id.is_some() || saved.fork_before.is_some() {
            self.replay_config(session, &child, &saved, off).await;
        }
        self.cap_full_access(session, &child, profile, off).await?;
        self.set_status(session, SessionStatus::Ready);
        self.note_launch(session, &child);
        self.save_meta(session);
        let meta_now = session.meta();
        self.remember_models(&meta_now.harness, &meta_now);
        Ok(child)
    }

    /// Marks `mode` as set by cmux again when it is the mode cmux had put the
    /// last agent in and this agent now reports it (`fresh_agent`).
    fn restore_mode_mark(&self, session: &Session, mode: &str) {
        let last = session.applied.lock().unwrap_or_else(|e| e.into_inner()).replay_mark.clone();
        let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        if last.as_deref() == Some(mode) && crate::web_modes::mode_of(&m).as_deref() == Some(mode) {
            m.mode_set_by_cmux = last;
        }
    }

    /// Re-assert the saved mode, then model, then every config option on a
    /// respawned ACP session, in that order. The model is sent even when
    /// unchanged: its acknowledgement reconciles sibling options such as
    /// Codex's reasoning effort. Failures are logged, never fatal.
    async fn replay_config(
        &self,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        saved: &SessionMeta,
        off: &super::full_access_bound::OffLatch,
    ) {
        let Some(sid) = session.meta().agent_session_id else { return };
        // A resumed chat saved in a full-access mode does not get it back while the setting is off.
        if let Some(mode) = saved
            .modes
            .as_ref()
            .and_then(|m| m.get("currentModeId"))
            .and_then(Value::as_str)
            .filter(|mode| !super::start_mode::is_full_access(mode) || off.allows_full_access())
        {
            if let Err(e) = child
                .request(method::SESSION_SET_MODE, json!({"sessionId": sid, "modeId": mode}))
                .await
            {
                tracing::warn!(session = %session.id, "replay mode {mode}: {}", e.message);
            } else {
                self.write_mode_state(session, [ModeWrite::CurrentMode(json!(mode))]);
                self.restore_mode_mark(session, mode);
            }
        }
        let opts: Vec<(String, Value)> = saved
            .config_options
            .as_deref()
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|o| {
                        Some((o.get("id")?.as_str()?.to_owned(), o.get("currentValue")?.clone()))
                    })
                    .collect()
            })
            .unwrap_or_default();
        // Model first.
        let ordered: Vec<(String, Value)> = opts
            .iter()
            .filter(|(k, _)| k == "model")
            .chain(opts.iter().filter(|(k, _)| k != "model"))
            .cloned()
            .collect();
        for (id, value) in ordered {
            if value.is_null() {
                continue;
            }
            if value.as_str().is_some_and(super::start_mode::is_full_access)
                && !off.allows_full_access()
            {
                tracing::info!(session = %session.id, "replay {id}: full access is off; kept the harness's own mode");
                continue;
            }
            let params = json!({"sessionId": sid, "configId": id, "value": value});
            let asked = super::full_access_bound::asked_option(&params);
            match child.request(method::SESSION_SET_CONFIG_OPTION, params).await {
                Ok(res) => {
                    // A bare answer took the value asked, as a client's does: under an MDM off
                    // pushed while it was asked, `cap_full_access` then counts it (#26340).
                    super::full_access_bound::record_option_answer(session, &res, asked);
                    if let Some(o) = res.get("configOptions") {
                        self.write_mode_state(session, [ModeWrite::ConfigOptions(o.clone())]);
                    }
                    // A mode that is its `mode` option is cmux's again once this agent runs it.
                    if id == "mode"
                        && let Some(mode) = value.as_str()
                    {
                        self.restore_mode_mark(session, mode);
                    }
                }
                Err(e) => tracing::warn!(session = %session.id, "replay {id}: {}", e.message),
            }
        }
        // No model option was replayed (the agent may list other options,
        // such as effort, without one): restore the legacy model id.
        if !opts.iter().any(|(k, v)| k == "model" && !v.is_null())
            && let Some(model) =
                saved.models.as_ref().and_then(|m| m.get("currentModelId")).and_then(Value::as_str)
            && let Err(e) = child
                .request(method::SESSION_SET_MODEL, json!({"sessionId": sid, "modelId": model}))
                .await
        {
            tracing::warn!(session = %session.id, "replay model {model}: {}", e.message);
        }
        self.append(session, "mux", "config", json!({"replayed": true}));
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
                    .is_ok_and(|p| super::repo_sync::gates_its_tools(p.kind))
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
        self.wait_startup().await;
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
