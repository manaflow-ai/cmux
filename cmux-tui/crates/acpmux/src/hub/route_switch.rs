//! Part of `Hub`; see `hub/mod.rs`. A route (`crate::routes`) at spawn, and
//! a chat's live route switch (ROUTES R1-R2): the chat's binding changes, the
//! harness process restarts with the new route's env and resumes the same
//! agent session (`claude --resume`, ACP `session/load`), the transcript
//! stays. Idle: now. A running turn: after it ends, or now after a cancel.

use super::*;

use crate::{route_account, routes, subscriptions::LOCAL_SUBSCRIPTION_ROUTE};
use cmux_json::JsonSet as _;

impl Hub {
    /// A new chat's named route exists and serves its harness family.
    pub(super) async fn check_new_route(
        &self,
        route_id: &str,
        family: &str,
        profile: &HarnessProfile,
    ) -> Result<(), RpcError> {
        let (dir, _) = crate::routes::places(&*self.config.read().await);
        let found = crate::routes::find(dir.as_deref(), route_id)
            .map_err(|e| RpcError::invalid_params(format!("route {route_id}: {}", e.message())))?;
        found.check_local_launch().map_err(|e| route_error(&e))?;
        if !found.serves(family) {
            return Err(RpcError::invalid_params(format!(
                "route {route_id} does not serve the {family} harness"
            )));
        }
        found.check_local_harness(Some(profile)).map_err(|e| route_error(&e))
    }

    /// The route env of a spawn, applied over `env`: the session's chat
    /// binding, else its workspace's, family's or the global one. No
    /// binding: `env` is unchanged. A binding to a route that is gone or
    /// that cannot start is the spawn's error, never a silent other route;
    /// a non-chat binding to a route of another family is skipped. Returns
    /// the account home it gave a chat whose conversation has none yet
    /// (route_account.rs records it once the chat has started). `forking`:
    /// the session forks its parent's conversation, which has a home.
    pub(super) async fn apply_route(
        &self,
        meta: &SessionMeta,
        forking: bool,
        profile: &HarnessProfile,
        env: &mut std::collections::BTreeMap<String, String>,
    ) -> Result<Option<PathBuf>, RpcError> {
        let workspace = meta.session_env.get("CMUX_WORKSPACE_ID").map(String::as_str);
        let has_home = forking || route_account::has_home(meta);
        self.apply_route_for(&meta.harness, Some(&meta.id), workspace, has_home, profile, env).await
    }

    /// [`Self::apply_route`] for a spawn of harness `harness` that may not
    /// be a chat: without a session (a one-shot `_acpmux/complete`) only the
    /// profile's, family's or global route applies. `has_home`: the chat's
    /// conversation already has a folder, which the route does not change.
    pub(crate) async fn apply_route_for(
        &self,
        harness: &str,
        session: Option<&str>,
        workspace: Option<&str>,
        has_home: bool,
        profile: &HarnessProfile,
        env: &mut std::collections::BTreeMap<String, String>,
    ) -> Result<Option<PathBuf>, RpcError> {
        let (dir, state) = routes::places(&*self.config.read().await);
        let family = crate::config::derive_family(harness, profile);
        let mut bindings = routes::bindings(&state);
        // No chat: no chat binding applies.
        if session.is_none() {
            bindings.chats.clear();
        }
        // A profile's own route (the `cmux` harness) replaces a family or
        // global binding; a chat or workspace binding still wins; your own
        // endpoint is never rewritten by a family or global one.
        let automatic = match family.as_str() {
            "github-copilot" | "openrouter" => {
                routes::automatic_connection(dir.as_deref(), &bindings, &family)
                    .map(|id| (id, "profile"))
            }
            _ => None,
        };
        let Some((id, scope)) = routes::spawn_route(
            dir.as_deref(),
            &bindings,
            session.unwrap_or_default(),
            workspace,
            &family,
            &profile.env,
        )
        .filter(|(_, scope)| {
            !matches!(family.as_str(), "github-copilot" | "openrouter") || *scope == "chat"
        })
        .or(automatic) else {
            return Ok(None);
        };
        let route = if let Some(session) = session.filter(|_| scope == "chat") {
            routes::find_chat_route(dir.as_deref(), &state, session, &id)
        } else {
            routes::find(dir.as_deref(), &id)
        }
        .map_err(|e| {
            route_error(&routes::RouteError::NotFound(format!(
                "{e}: this {scope}'s route is gone; put its file back in ~/.config/{next}/routes \
                 or pick another account in the chat's Account menu",
                next = cmux_config::NEXT_DIR
            )))
        })?;
        if !route.serves(&family) {
            if matches!(scope, "chat" | "profile") {
                return Err(route_error(&routes::RouteError::BadParams(format!(
                    "route {id} does not serve the {family} harness"
                ))));
            }
            return Ok(None);
        }
        route.check_local_harness(Some(profile)).map_err(|e| route_error(&e))?;
        let home = route.file.account_home.clone().map(PathBuf::from);
        let name = route.name();
        let moved = route.clone();
        let before = route_account::home_var(&family).and_then(|var| env.get(var).cloned());
        let fam = family.clone();
        let route_env = tokio::task::spawn_blocking(move || routes::env_for(&route, &fam, &state))
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
            .map_err(|e| route_error(&e))?;
        routes::apply(env, &route_env);
        let chatgpt = moved.file.kind == routes::RouteKind::ChatgptPlan;
        if chatgpt {
            let (_, home) = routes::places(&*self.config.read().await);
            let (token, expires_at) = self
                .chatgpt
                .token(&home, &id)
                .await
                .map_err(|error| connection_error(&error.code, "ChatGPT"))?;
            env.insert(crate::agent_credentials::CHATGPT_TOKEN.into(), token);
            env.insert(
                crate::agent_credentials::LOCAL_REDACTION.into(),
                crate::agent_credentials::CHATGPT_TOKEN.into(),
            );
            env.insert(crate::chatgpt::LOCAL_EXPIRY_ENV.into(), expires_at.to_string());
        }
        use crate::subscriptions::Provider;
        let provider = Provider::for_kind(moved.file.kind);
        if let Some(provider) = provider {
            let grant = async || {
                let (_, home) = routes::places(&*self.config.read().await);
                let (token, expires_at, region) = self
                    .subscriptions
                    .grant(provider, &home, &id, crate::subscriptions::LOCAL_MARGIN)
                    .await
                    .map_err(subscription_error)?;
                Ok::<_, RpcError>((token, expires_at, region, home))
            };
            match provider {
                Provider::Grok => {
                    let _ = session.ok_or_else(|| subscription_error("session_required"))?;
                    env.insert(crate::subscriptions::grok_hook::ROUTE.into(), id.clone());
                }
                Provider::Kimi => {
                    let (token, expires_at, region, _) = grant().await?;
                    let region = region.ok_or_else(|| subscription_error("reauth_required"))?;
                    env.extend(
                        crate::byo_endpoint::opencode_env(
                            "Kimi Code",
                            region.base_url(),
                            &[crate::subscriptions::KIMI_MODEL.into()],
                            true,
                        )
                        .into_iter()
                        .map(|(key, value)| (key.to_owned(), value)),
                    );
                    env.insert(crate::byo_endpoint::OPENAI_KEY_ENV.into(), token);
                    env.insert(
                        crate::agent_credentials::LOCAL_REDACTION.into(),
                        crate::byo_endpoint::OPENAI_KEY_ENV.into(),
                    );
                    env.insert(
                        crate::subscriptions::LOCAL_KIMI_EXPIRY.into(),
                        expires_at.to_string(),
                    );
                }
                Provider::Copilot => {
                    let (token, _, _, _home) = grant().await?;
                    env.insert(crate::agent_credentials::COPILOT_TOKEN.into(), token);
                    #[cfg(unix)]
                    {
                        env.insert(crate::agent::copilot_auth::ROUTE_ENV.into(), id.clone());
                        env.insert(
                            crate::agent::copilot_auth::ROUTE_HOME_ENV.into(),
                            _home.to_string_lossy().into_owned(),
                        );
                    }
                }
            }
        }
        if chatgpt || provider.is_some() {
            let instance = moved.file.credential_instance.as_deref().unwrap_or_default();
            env.insert(LOCAL_SUBSCRIPTION_ROUTE.into(), format!("{id}:{instance}"));
        }
        env.insert(routes::NAME_KEY.into(), name);
        // A home the profile pins (a Chief turn's, a claude-sr profile's) is
        // only replaced by a route picked for this chat or profile.
        let pinned = before.is_some() && !matches!(scope, "chat" | "profile");
        // A started chat moved onto another login that shares its conversations (a Codex
        // shadow home and its base) runs there now, and keeps it as its store.
        if has_home
            && scope == "chat"
            && let Some(to) = route_account::moved_home(
                &moved,
                &family,
                before.as_deref().map(std::path::Path::new),
            )
            && let Some(var) = route_account::home_var(&family)
        {
            env.insert(var.to_owned(), to.display().to_string());
            return Ok(Some(to));
        }
        if has_home || pinned {
            route_account::keep_home(&family, before, env);
            return Ok(None);
        }
        Ok(home)
    }

    /// The turn lock is held. Finish any existing work before restarting a child whose launch
    /// connection was removed. When restarting would interrupt work, refuse the new prompt.
    pub(super) async fn refresh_disconnected_subscription_before_turn(
        &self,
        session: &Arc<Session>,
    ) -> Result<(), RpcError> {
        // A child that is still starting is checked when the prompt acquires it.
        let Ok(_spawn) = session.spawn_lock.try_lock() else { return Ok(()) };
        let Some(child) = session.child.lock().await.clone() else { return Ok(()) };
        if let Err(error) = self.check_local_subscription_child(session, &child).await {
            if !self.route_child_is_idle(session) {
                return Err(error);
            }
            self.detach_child(session).await;
        }
        Ok(())
    }

    /// Check the connection the child actually started with. Current bindings may already
    /// point to a different account, including a replacement with the same route id.
    pub(super) async fn check_local_subscription_child(
        &self,
        session: &Session,
        child: &ChildAgent,
    ) -> Result<(), RpcError> {
        let launch = session
            .launch_env
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .map(|env| env.get(LOCAL_SUBSCRIPTION_ROUTE).cloned());
        let needs_restart = match launch {
            Some(Some(route)) => {
                let (dir, _) = routes::places(&*self.config.read().await);
                !tokio::task::spawn_blocking(move || {
                    let Some((id, instance)) = route.split_once(':') else { return false };
                    routes::find(dir.as_deref(), id).is_ok_and(|current| {
                        current.file.credential_instance.as_deref().unwrap_or_default() == instance
                    })
                })
                .await
                .unwrap_or_default()
            }
            Some(None) => false,
            // An adopted host has no launch snapshot. A recorded local expiry identifies a
            // subscription even after its bindings have gone. Older Codex hosts can also be
            // identified by the launch environment while they are still running.
            None => {
                if let Some(record) = child.host_record() {
                    record.local_kimi_expiry.is_some()
                        || record.local_chatgpt_expiry.is_some()
                        || self
                            .legacy_adopted_chatgpt_expiry(session, record.harness_pid)
                            .await
                            .is_some()
                } else {
                    false
                }
            }
        };
        if needs_restart { Err(subscription_error("reauth_required")) } else { Ok(()) }
    }

    /// A local Kimi agent holds its launch grant until the next restart.
    pub(super) async fn refresh_local_kimi_between_turns(&self, session: &Arc<Session>) {
        let expiry = session
            .child
            .lock()
            .await
            .as_ref()
            .and_then(|child| child.host_record())
            .and_then(|record| record.local_kimi_expiry);
        let expiry = expiry.or_else(|| {
            let launch = session.launch_env.lock().unwrap_or_else(|e| e.into_inner());
            launch.as_ref()?.get(crate::subscriptions::LOCAL_KIMI_EXPIRY)?.parse::<i64>().ok()
        });
        if expiry.is_some_and(|expiry| {
            expiry.saturating_sub(crate::subscriptions::now()) <= crate::subscriptions::LOCAL_MARGIN
        }) {
            self.detach_idle_route_child(session).await;
        }
    }

    /// The prompt owns the turn lock and has yet to start its turn. Reopening the agent
    /// through the ordinary spawn path refreshes the route and resumes its conversation.
    pub(super) async fn refresh_local_chatgpt_between_turns(&self, session: &Arc<Session>) {
        let expires = {
            let launch = session.launch_env.lock().unwrap_or_else(|e| e.into_inner());
            match launch.as_ref() {
                Some(env) => match env
                    .get(crate::chatgpt::LOCAL_EXPIRY_ENV)
                    .and_then(|value| value.parse::<i64>().ok())
                {
                    Some(expiry) => Some(expiry),
                    None => return,
                },
                None => None,
            }
        };
        let expires = match expires {
            Some(expiry) => Some(expiry),
            None => {
                let record =
                    session.child.lock().await.as_ref().and_then(|child| child.host_record());
                match record {
                    Some(record) => match record.local_chatgpt_expiry {
                        Some(expiry) => Some(expiry),
                        None => {
                            self.legacy_adopted_chatgpt_expiry(session, record.harness_pid).await
                        }
                    },
                    None => None,
                }
            }
        };
        if expires.is_none_or(|expiry| {
            expiry.saturating_sub(crate::chatgpt::now_unix()) > crate::chatgpt::REFRESH_MARGIN_SECS
        }) {
            return;
        }
        self.detach_idle_route_child(session).await;
    }

    async fn detach_idle_route_child(&self, session: &Arc<Session>) {
        let _spawn = session.spawn_lock.lock().await;
        if self.route_child_is_idle(session) && session.child.lock().await.is_some() {
            self.detach_child(session).await;
        }
    }

    pub(super) fn route_child_is_idle(&self, session: &Session) -> bool {
        session.turn().is_none()
            && !session.harness_turn.load(Ordering::SeqCst)
            && !session.compacting.load(Ordering::SeqCst)
            && session.asks_in_flight.load(Ordering::SeqCst) == 0
            && session.pending_permissions().is_empty()
            && !self.holds_work_below(session)
    }

    pub(super) async fn uses_local_chatgpt_plan(&self, session: &Session) -> bool {
        let launch = session
            .launch_env
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .map(|env| env.contains_key(crate::chatgpt::LOCAL_EXPIRY_ENV));
        if launch == Some(true) {
            return true;
        }
        if launch.is_none() {
            let host = session.child.lock().await.as_ref().and_then(|child| child.host_record());
            if let Some(record) = host
                && (record.local_chatgpt_expiry.is_some()
                    || self
                        .legacy_adopted_chatgpt_expiry(session, record.harness_pid)
                        .await
                        .is_some())
            {
                return true;
            }
        }
        let meta = session.meta();
        let config = self.config.read().await;
        let Ok(profile) =
            super::resolve::session_profile(&config, &meta.harness, &meta.cwd, meta.remote_origin)
        else {
            return false;
        };
        let (dir, home) = routes::places(&config);
        local_chatgpt_route(dir.as_deref(), &home, &meta, &profile).is_some()
    }

    pub(super) async fn legacy_adopted_chatgpt_expiry(
        &self,
        session: &Session,
        pid: Option<u32>,
    ) -> Option<i64> {
        if session.credential.lock().unwrap_or_else(|e| e.into_inner()).as_ref().is_some_and(
            |credential| credential.family() == crate::agent_credentials::Family::Codex,
        ) {
            return None;
        }
        let meta = session.meta();
        let (dir, home, profile) = {
            let config = self.config.read().await;
            let Ok(profile) = super::resolve::session_profile(
                &config,
                &meta.harness,
                &meta.cwd,
                meta.remote_origin,
            ) else {
                return None;
            };
            let family = crate::config::derive_family(&meta.harness, &profile);
            if crate::agent_credentials::Family::of_harness(&family)
                != Some(crate::agent_credentials::Family::Codex)
            {
                return None;
            }
            let (dir, home) = routes::places(&config);
            (dir, home, profile)
        };
        tokio::task::spawn_blocking(move || {
            // The launch token still identifies an older local ChatGPT host when its route
            // and bindings are gone. A token without a readable deadline needs a restart.
            #[cfg(unix)]
            if let Some(vars) = pid.and_then(crate::agent_host::tree::environ)
                && let Some((_, token)) =
                    vars.iter().find(|(name, _)| name == crate::agent_credentials::CHATGPT_TOKEN)
            {
                return Some(crate::agent_credentials::chatgpt_token_expiry(token).unwrap_or(0));
            }
            #[cfg(not(unix))]
            let _ = pid;
            let id = local_chatgpt_route(dir.as_deref(), &home, &meta, &profile)?;
            let record = crate::chatgpt::store::read(&home, &id).ok()??;
            Some(record.expires_at)
        })
        .await
        .ok()
        .flatten()
    }

    /// Bind a chat to a route (None: back to the inherited one) and move its
    /// harness onto it: an idle chat restarts now and resumes; a running
    /// turn finishes first (`now`: is cancelled first).
    pub async fn set_chat_route(
        self: &Arc<Self>,
        session: &Arc<Session>,
        route: Option<String>,
        now: bool,
    ) -> Result<Value, RpcError> {
        let meta = session.meta();
        let (dir, state, profile) = {
            let config = self.config.read().await;
            let (dir, state) = routes::places(&config);
            let profile = super::resolve::session_profile(
                &config,
                &meta.harness,
                &meta.cwd,
                meta.remote_origin,
            )
            .ok();
            (dir, state, profile)
        };
        let found = route
            .as_deref()
            .map(|id| routes::find(dir.as_deref(), id))
            .transpose()
            .map_err(|e| route_error(&e))?;
        if let Some(found) = &found {
            found.check_local_harness(profile.as_ref()).map_err(|e| route_error(&e))?;
        }
        if let (Some(found), Some(profile)) = (&found, &profile) {
            // Checked before the binding changes: an unknown route, one of
            // another family or a local router that is down keeps the chat
            // where it is.
            let family = crate::config::derive_family(&meta.harness, profile);
            let state2 = state.clone();
            tokio::task::spawn_blocking(move || routes::env_for(&found, &family, &state2))
                .await
                .map_err(|e| RpcError::internal(e.to_string()))?
                .map_err(|e| route_error(&e))?;
        }
        if let (Some(found), Some(profile)) = (&found, &profile)
            && route_account::has_home(&meta)
        {
            // Its conversation stays in its folder: another account's route
            // would not move it there, so it is refused instead.
            let family = crate::config::derive_family(&meta.harness, profile);
            let (_, env) = self.harness_env(&meta).await;
            let current = route_account::current_home(&meta, &family, &env);
            route_account::switch_allowed(current.as_deref(), found)
                .map_err(|e| route_error(&e))?;
        }
        let turn = session.turn_lock.try_lock().ok();
        let running = {
            let _spawn = self.spawn_lease(session).await;
            let claude = profile
                .as_ref()
                .is_some_and(|p| crate::config::derive_family(&meta.harness, p) == "claude");
            if claude {
                self.check_claude_route_change(session)?;
            }
            let binding = format!("chat:{}", session.id);
            let from = routes::bindings(&state).chats.get(&session.id).cloned();
            routes::set_binding(&state, &binding, route.as_deref()).map_err(|e| route_error(&e))?;
            if claude && let Err(error) = self.save_claude_launch_auth(session, false) {
                routes::set_binding(&state, &binding, from.as_deref())
                    .map_err(|e| route_error(&e))?;
                return Err(error);
            }
            let running = session.turn().is_some();
            let wait = turn.is_none() || !self.route_child_is_idle(session);
            session.route_switch.store(true, Ordering::SeqCst);
            self.append(
                session,
                "mux",
                "route_changed",
                json!({"from": from, "to": route, "when": if wait && !(running && now) { "after-turn" } else { "now" }}),
            );
            running
        };
        if running {
            if now {
                drop(turn);
                self.cancel(session).await?;
            }
            return Ok(
                json!({"routeId": route, "applied": if now { "after-cancel" } else { "after-turn" }}),
            );
        }
        if turn.is_some() {
            self.restart_on_route(session).await?;
        }
        let applied =
            if session.route_switch.load(Ordering::SeqCst) { "after-turn" } else { "now" };
        Ok(json!({"routeId": route, "applied": applied}))
    }

    /// A new chat that started in an account home keeps it as its store
    /// from now on (route_account.rs `record`); a failed start records nothing.
    pub(super) fn keep_account_home<T>(
        &self,
        session: &Session,
        spawn: &super::spawn::Spawn,
        child: T,
    ) -> T {
        let recorded = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let restarted = super::credentials::claude_login_needs_restart(&m);
            if restarted {
                m.claude_login_restart_pending = Some(false);
            }
            route_account::record(&mut m, spawn.account_home.as_deref()) || restarted
        };
        if recorded {
            self.save_meta(session);
        }
        child
    }

    /// Restart the harness on its current binding and resume the same agent
    /// session; the new process starts now (prewarm), so the next prompt does
    /// not wait for it.
    pub(super) async fn restart_on_route(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<(), RpcError> {
        // A shutdown began: no agent starts here any more, and the one it left running is the
        // next daemon's to adopt (`shutdown.rs`). The binding is written; nothing moved yet.
        if self.shutting_down() {
            return Err(super::shutdown::shutting_down_error());
        }
        {
            let _spawn = self.spawn_lease(session).await;
            if session.read_meta(super::credentials::claude_login_needs_restart) {
                if !self.end_previous_claude_host(session).await? {
                    return Ok(());
                }
            } else {
                if session.route_switch.load(Ordering::SeqCst) && !self.route_child_is_idle(session)
                {
                    return Ok(());
                }
                session.route_switch.store(false, Ordering::SeqCst);
                if session.child.lock().await.is_none() {
                    return Ok(());
                }
                self.detach_child(session).await;
            }
        }
        self.child_for(session).await.map(|_| ())
    }

    /// A restart left for a turn's end (a route switch, an update's `restart_harnesses`, an
    /// unproven host's `restart_unproven`) when work runs below the chat as its turn ends
    /// (`idle.rs` `holds_work_below`: a background subagent or process, a sub-session at work),
    /// which the harness's exit would end: it waits. The agent restarts once nothing runs in it
    /// (`Session::respawn_when_quiet`), or at the end of a later turn that leaves nothing below;
    /// `route_switch` stays set for that turn. True when it waits.
    ///
    /// Before, the turn's end restarted it whatever ran below, though `restart_harnesses` says
    /// such a session keeps its agent: on cosmic-gray (2026-11-26) a coordinator's agent ended at
    /// 11:54, 12:19, 12:39 and 13:38Z, each at its first turn end after a cmux NIGHTLY install
    /// and the restart that followed, and about 15 background subagents with it each time.
    pub(super) fn restart_waits_for_work_below(self: &Arc<Self>, session: &Session) -> bool {
        if !self.holds_work_below(session) {
            return false;
        }
        tracing::info!(
            session = %session.id,
            "a restart left for the turn's end waits: work runs below it; it restarts once quiet"
        );
        self.respawn_when_quiet(session);
        true
    }

    /// `_acpmux/sessions/restart_harness {harnesses?, sessions?}` (Update
    /// Everything, cx-1mbnu; a chat's "Restart chat"): every live session of
    /// this daemon (none mirrored from a peer; none of the Home Chief's unless
    /// named in `sessions`), or those of the named harnesses and/or the named
    /// sessions, restarts its harness process and resumes the same agent
    /// session, as a route switch does but with no binding written: so it runs
    /// the version an update just installed. A session between turns restarts
    /// now; one in a turn when the turn ends (never cancelled), one with work
    /// below it and no turn before its next turn. Returns how
    /// many restarted now, how many restart after their turn, and each one
    /// whose harness could not start again.
    pub async fn restart_harnesses(
        self: &Arc<Self>,
        harnesses: Option<&std::collections::BTreeSet<String>>,
        sessions: Option<&std::collections::BTreeSet<String>>,
    ) -> HarnessRestarts {
        let live = self.sessions().into_iter().filter(|session| {
            let meta = session.meta();
            matches!(
                meta.status,
                SessionStatus::Ready | SessionStatus::Running | SessionStatus::Waiting
            ) && (sessions.is_some() || !is_chief(&meta))
                && harnesses.is_none_or(|ids| ids.contains(&meta.harness))
                && sessions.is_none_or(|ids| ids.contains(session.id.as_str()))
        });
        // Each restart waits for its new process (spawn, initialize, load):
        // all at once, so many chats take as long as the slowest one.
        let outcomes = futures::future::join_all(live.map(|session| async move {
            // The turn lock is held through a turn and its route-switch
            // restart (`turns.rs`, `hosts.rs`); holding it, no turn starts
            // meanwhile. An open permission prompt is never cut either (the
            // restart's `detach_child` would cancel it): that session restarts
            // after its next turn, as `restart_unproven` waits for one.
            // Nor is work below it with no turn open (a background subagent or process, a
            // sub-session at work: `holds_work_below`), which the harness's exit would end: an
            // app update now relaunches while agents work (Leo, 2026-11-22: "auto be de facto
            // able to click the restart button"), so its restart must drop nothing. Such a
            // session keeps its agent and moves before its next turn (`turns.rs`).
            let idle = || {
                if self.route_child_is_idle(&session) {
                    session.turn_lock.try_lock().ok()
                } else {
                    None
                }
            };
            let mut turn = idle();
            if turn.is_none() {
                session.route_switch.store(true, Ordering::SeqCst);
                // The turn may have ended before the flag was seen: then now.
                turn = idle().filter(|_| session.route_switch.load(Ordering::SeqCst));
            }
            let Some(_turn) = turn else { return Ok(false) };
            session.route_switch.store(true, Ordering::SeqCst);
            match self.restart_on_route(&session).await {
                Ok(()) => Ok(!session.route_switch.load(Ordering::SeqCst)),
                Err(e) => {
                    tracing::warn!(session = %session.id, error = %e.message, "harness restart");
                    Err((session.id.clone(), e.message))
                }
            }
        }))
        .await;
        let mut out = HarnessRestarts::default();
        for outcome in outcomes {
            match outcome {
                Ok(true) => out.now += 1,
                Ok(false) => out.after_turn += 1,
                Err(failed) => out.failed.push(failed),
            }
        }
        out
    }
}

impl Hub {
    /// An adopted agent whose host (an older build) recorded no caller token
    /// cannot prove its session, so its sub-session tools are refused. It
    /// restarts as `acpmux session restart` asks, in the same conversation
    /// and keeping its sub-sessions, once it is between turns: a recovered
    /// turn ends its process when it ends (`hosts.rs`), a later turn moves it
    /// before the next one (`turns.rs`), and an idle agent ends now and starts
    /// again at its next prompt. Never during a turn or an open permission
    /// prompt.
    pub(super) fn restart_unproven(self: &Arc<Self>, session: &Arc<Session>, proven: bool) {
        if proven {
            return;
        }
        tracing::info!(session = %session.id, "adopted agent has no caller token this daemon knows (an older host build): restarting it between turns for its sub-session tools");
        session.route_switch.store(true, Ordering::SeqCst);
        let hub = self.clone();
        let session = session.clone();
        tokio::spawn(async move {
            let _turn = session.turn_lock.lock().await;
            if hub.route_child_is_idle(&session)
                && !session.read_meta(super::credentials::claude_login_needs_restart)
                && !hub.restart_waits_for_work_below(&session)
                && session.route_switch.swap(false, Ordering::SeqCst)
            {
                hub.detach_child(&session).await;
            }
        });
    }
}

fn local_chatgpt_route(
    dir: Option<&Path>,
    home: &Path,
    meta: &SessionMeta,
    profile: &HarnessProfile,
) -> Option<String> {
    let family = crate::config::derive_family(&meta.harness, profile);
    if crate::agent_credentials::Family::of_harness(&family)
        != Some(crate::agent_credentials::Family::Codex)
    {
        return None;
    }
    let (id, _) = routes::spawn_route(
        dir,
        &routes::bindings(home),
        &meta.id,
        meta.session_env.get("CMUX_WORKSPACE_ID").map(String::as_str),
        &family,
        &profile.env,
    )?;
    crate::chatgpt::is_chatgpt_route(dir, &id).then_some(id)
}

/// What `restart_harnesses` did: how many sessions restarted now, how many
/// restart when their turn ends, and `(session, error)` for each whose
/// harness could not start again.
#[derive(Debug, Default)]
pub struct HarnessRestarts {
    pub now: usize,
    pub after_turn: usize,
    pub failed: Vec<(String, String)>,
}

/// A Home Chief session (its turn, compactor or subagent): tagged
/// `cmux.chief`, or named `optchat-…`, or of an `optchat-compact-…` preset
/// harness (the app's `AcpmuxSessionCensus.isChief`). Update Everything
/// never counts or restarts one; only a caller naming it in `sessions` does.
pub(crate) fn is_chief(meta: &SessionMeta) -> bool {
    live_tags(meta).get("cmux.chief").is_some()
        || meta.name.starts_with("optchat-")
        || meta.harness.starts_with("optchat-compact-")
}

/// Whether another route can solve a failed turn: auth, limits, an overloaded or full
/// provider (`is_capacity_error`, with or without its status code), server errors, an
/// unreachable proxy. A capacity error retries in place too (`auto_resume.rs`); the route's
/// diagnostics, probe and `autoFallback` still see it.
fn is_route_failure(message: &str) -> bool {
    let lower = message.to_lowercase();
    super::turn_errors::is_limit_error(message)
        || super::turn_errors::is_capacity_error(message)
        || ["500", "502", "connection refused", "unreachable", "timed out", "agent process closed"]
            .iter()
            .any(|w| lower.contains(w))
}

impl Hub {
    /// A failed turn on a bound route (ROUTES R3): name the route, offer its
    /// first fallback that serves this harness (`fallback: {routeId, name}`),
    /// move the chat onto it when the route says `autoFallback`, and probe the
    /// failed route once in the background (at most once per route per
    /// backoff window; never on a timer). Only for failures another route
    /// can solve: auth, limits, overload, server errors, an unreachable proxy.
    pub(super) async fn route_failure(
        self: &Arc<Self>,
        session: &Arc<Session>,
        message: &str,
    ) -> Option<Value> {
        if !is_route_failure(message) {
            return None;
        }
        let (dir, state) = routes::places(&*self.config.read().await);
        let meta = session.meta();
        let profile = self.config.read().await.harnesses.get(&meta.harness).cloned()?;
        let family = crate::config::derive_family(&meta.harness, &profile);
        let workspace = meta.session_env.get("CMUX_WORKSPACE_ID").map(String::as_str);
        // The route the spawn ran on (`routes::spawn_route`); a profile's own only for codex,
        // whose logins this moves between.
        let bound = routes::spawn_route(
            dir.as_deref(),
            &routes::bindings(&state),
            &session.id,
            workspace,
            &family,
            &profile.env,
        )
        .filter(|(_, scope)| *scope != "profile" || family == "codex");
        let unbound = bound.is_none();
        let own_endpoint = crate::byo_endpoint::Kind::of_env(&profile.env).is_some();
        let id = match bound {
            Some((id, _)) => id,
            // A codex chat on the CLI's own login (no route) is on the built-in one; a profile
            // with an endpoint of its own is not a login.
            None if family == "codex" && !own_endpoint => routes::CODEX_LOGIN_ROUTE_ID.to_owned(),
            None => return None,
        };
        let route = routes::find(dir.as_deref(), &id).ok()?;
        if !unbound && routes::auto_probe_allowed(&id) {
            let (hub, s, r, st) = (self.clone(), session.clone(), route.clone(), state.clone());
            tokio::spawn(async move {
                let probe = routes::probe(&r, &st).await;
                hub.append(&s, "mux", "route_probe", probe);
            });
        }
        if route.file.kind == routes::RouteKind::ChatgptPlan {
            return Some(json!({"route": {"routeId": id, "name": route.name()}}));
        }
        // A fallback never names another account: the chat keeps its folder.
        let (_, env) = self.harness_env(&meta).await;
        let home = route_account::current_home(&meta, &family, &env);
        let named = route.file.fallback.iter().filter(|f| **f != id).find_map(|f| {
            // A route turned off (`_acpmux/account/set`) is never moved onto.
            routes::find(dir.as_deref(), f).ok().filter(|r| {
                !r.file.disabled
                    && r.serves(&family)
                    && r.check_local_harness(Some(&profile)).is_ok()
                    && route_account::switch_allowed(home.as_deref(), r).is_ok()
            })
        });
        // A codex chat on a router, proxy or key with no fallback of its own may always go back to
        // the signed-in Codex login it would run on with no route at all, and does by itself.
        // A route that names fallbacks of its own keeps to them, even when none can take the chat
        // now: only one that names none moves by itself.
        let signed_in = route
            .file
            .fallback
            .is_empty()
            .then(|| account_fallback(&route, &family, home.as_deref(), dir.as_deref()))
            .flatten();
        if unbound && signed_in.is_none() {
            return None;
        }
        let auto = route.file.auto_fallback || signed_in.is_some();
        let mut out = json!({"route": {"routeId": id, "name": route.name()}});
        if let Some(next) = named.or(signed_in) {
            out.set("fallback", json!({"routeId": next.id, "name": next.name()}));
            if auto
                && routes::set_binding(&state, &format!("chat:{}", session.id), Some(&next.id))
                    .is_ok()
            {
                self.append(
                    session,
                    "mux",
                    "route_changed",
                    json!({"from": id, "to": next.id, "when": "after-turn", "reason": "fallback"}),
                );
                session.route_switch.store(true, Ordering::SeqCst);
                out.set_path(&["fallback", "applied"], json!(true));
            }
        }
        Some(out)
    }
}

/// The next signed-in, enabled Codex login a codex chat that failed on `failed` moves onto by
/// itself (Leo, 2026-11-05: "the codex signed account, like auto routing permission"): the CLI's
/// own login first, then each account route, by id. A failure on a login looks for another
/// account; a failure on a router, proxy or key may go back to the chat's own login. Only a login
/// the chat may move to: one with no folder of its own, its own folder, or one that shares its
/// conversations (a shadow home and its base, route_shadow.rs).
fn account_fallback(
    failed: &routes::Route,
    family: &str,
    home: Option<&std::path::Path>,
    dir: Option<&std::path::Path>,
) -> Option<routes::Route> {
    if family != "codex" {
        return None;
    }
    let current = home.map(std::path::Path::to_path_buf).or_else(crate::route_shadow::codex_base);
    let on_login = failed.file.kind == routes::RouteKind::DirectSubscription;
    let builtin = routes::find(dir, routes::CODEX_LOGIN_ROUTE_ID).ok();
    let accounts: Vec<_> = routes::load(dir)
        .0
        .into_iter()
        .filter(|r| {
            r.id != routes::CODEX_LOGIN_ROUTE_ID
                && r.file.kind == routes::RouteKind::DirectSubscription
                && r.file.account_home.is_some()
        })
        .collect();
    // A chat in another account's own folder (not a shadow) has no way onto the CLI's login: it
    // would keep running in that folder.
    let in_account = home.is_some_and(|h| {
        accounts.iter().any(|a| {
            a.file.shadow_of.is_none()
                && a.file.account_home.as_deref().map(std::path::Path::new) == Some(h)
        })
    });
    // The accounts after the one that failed come first, then the rest: with A and B both out of
    // their limits, a chat moves A -> B -> C, never back and forth between A and B.
    let mut candidates: Vec<_> = builtin.into_iter().chain(accounts).collect();
    if let Some(at) = candidates.iter().position(|r| r.id == failed.id) {
        candidates.rotate_left(at + 1);
    }
    candidates.into_iter().find(|r| {
        if r.id == failed.id || r.file.disabled || !r.serves(family) {
            return false;
        }
        if r.id == routes::CODEX_LOGIN_ROUTE_ID && in_account {
            return false;
        }
        let Some(target) = route_account::effective_home(r, home) else { return false };
        if on_login && Some(&target) == current.as_ref() {
            return false;
        }
        routes::codex_signed_in(Some(&target)) && route_account::switch_allowed(home, r).is_ok()
    })
}

pub(crate) fn route_error(e: &routes::RouteError) -> RpcError {
    let base = match e {
        routes::RouteError::NotFound(m) => RpcError::not_found(m.clone()),
        routes::RouteError::Failed(m) => RpcError::internal(m.clone()),
        other => RpcError::invalid_params(other.message().to_owned()),
    };
    match e.reason() {
        Some(reason) => base.with_data(json!({"reason": reason})),
        None => base,
    }
}

#[cfg(test)]
#[path = "route_switch_route_failure_tests.rs"]
mod route_failure_tests;

fn subscription_error(reason: &'static str) -> RpcError {
    connection_error(reason, "the subscription")
}

fn connection_error(reason: &str, provider: &str) -> RpcError {
    let message = match reason {
        "reauth_required" | "signed_out" => format!("Reconnect {provider} in Settings > Models."),
        "keychain_locked" => format!("Unlock your Mac's keychain to use {provider}."),
        "keychain_other_build" => {
            crate::subscription_store::Error::KeychainOtherBuild.message().into()
        }
        "network" => format!("{provider} is offline. Try again when you are connected."),
        _ => format!("{provider} is temporarily unavailable."),
    };
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}
