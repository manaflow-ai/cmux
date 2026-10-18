//! Part of `Hub`; see `hub/mod.rs`. A route (`crate::routes`) at spawn, and
//! a chat's live route switch (ROUTES R1-R2): the chat's binding changes, the
//! harness process restarts with the new route's env and resumes the same
//! agent session (`claude --resume`, ACP `session/load`), the transcript
//! stays. Idle: now. A running turn: after it ends, or now after a cancel.

use super::*;

use crate::routes;

impl Hub {
    /// A new chat's named route exists and serves its harness family.
    pub(super) async fn check_new_route(
        &self,
        route_id: &str,
        family: &str,
    ) -> Result<(), RpcError> {
        let (dir, _) = crate::routes::places(&*self.config.read().await);
        let found = crate::routes::find(dir.as_deref(), route_id)
            .map_err(|e| RpcError::invalid_params(format!("route {route_id}: {}", e.message())))?;
        if !found.serves(family) {
            return Err(RpcError::invalid_params(format!(
                "route {route_id} does not serve the {family} harness"
            )));
        }
        Ok(())
    }

    /// The route env of a spawn, applied over `env`: the session's chat
    /// binding, else its workspace's, family's or the global one. No
    /// binding: `env` is unchanged. A binding to a route that is gone or
    /// that cannot start is the spawn's error, never a silent other route;
    /// a non-chat binding to a route of another family is skipped.
    pub(super) async fn apply_route(
        &self,
        meta: &SessionMeta,
        profile: &HarnessProfile,
        env: &mut std::collections::BTreeMap<String, String>,
    ) -> Result<Option<String>, RpcError> {
        let workspace = meta.session_env.get("CMUX_WORKSPACE_ID").map(String::as_str);
        self.apply_route_for(&meta.harness, Some(&meta.id), workspace, profile, env).await
    }

    /// [`Self::apply_route`] for a spawn of harness `harness` that may not
    /// be a chat: without a session (a one-shot `_acpmux/complete`) only the
    /// profile's, family's or global route applies.
    pub(super) async fn apply_route_for(
        &self,
        harness: &str,
        session: Option<&str>,
        workspace: Option<&str>,
        profile: &HarnessProfile,
        env: &mut std::collections::BTreeMap<String, String>,
    ) -> Result<Option<String>, RpcError> {
        let (dir, state) = routes::places(&*self.config.read().await);
        let family = crate::config::derive_family(harness, profile);
        let mut bindings = routes::bindings(&state);
        // No chat: no chat binding applies.
        if session.is_none() {
            bindings.chats.clear();
        }
        // A profile's own route (the `cmux` harness) replaces a family or
        // global binding; a chat or workspace binding still wins.
        let bound = routes::bound_route(&bindings, session.unwrap_or_default(), workspace, &family);
        let profile_route = profile.env.get(routes::PROFILE_ROUTE_KEY).cloned();
        let Some((id, scope)) = (match (bound, profile_route) {
            (Some((id, scope)), _) if matches!(scope, "chat" | "workspace") => Some((id, scope)),
            (_, Some(id)) => Some((id, "profile")),
            (bound, None) => bound,
        }) else {
            return Ok(None);
        };
        let route = routes::find(dir.as_deref(), &id).map_err(|e| {
            route_error(&routes::RouteError::NotFound(format!(
                "{e}: this {scope}'s route is gone; restore it or pick another (`cmux route use`)"
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
        let route_env =
            tokio::task::spawn_blocking(move || routes::env_for(&route, &family, &state))
                .await
                .map_err(|e| RpcError::internal(e.to_string()))?
                .map_err(|e| route_error(&e))?;
        routes::apply(env, &route_env);
        Ok(Some(id))
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
        let (dir, state) = routes::places(&*self.config.read().await);
        let meta = session.meta();
        let profile = self.config.read().await.harnesses.get(&meta.harness).cloned();
        if let (Some(id), Some(profile)) = (&route, &profile) {
            // Checked before the binding changes: an unknown route, one of
            // another family or a local router that is down keeps the chat
            // where it is.
            let found = routes::find(dir.as_deref(), id).map_err(|e| route_error(&e))?;
            let family = crate::config::derive_family(&meta.harness, profile);
            let state2 = state.clone();
            tokio::task::spawn_blocking(move || routes::env_for(&found, &family, &state2))
                .await
                .map_err(|e| RpcError::internal(e.to_string()))?
                .map_err(|e| route_error(&e))?;
        }
        let from = routes::bindings(&state).chats.get(&session.id).cloned();
        routes::set_binding(&state, &format!("chat:{}", session.id), route.as_deref())
            .map_err(|e| route_error(&e))?;
        let running = session.turn().is_some();
        self.append(
            session,
            "mux",
            "route_changed",
            json!({"from": from, "to": route, "when": if running && !now { "after-turn" } else { "now" }}),
        );
        if running {
            session.route_switch.store(true, Ordering::SeqCst);
            if now {
                self.cancel(session).await?;
            }
            return Ok(
                json!({"routeId": route, "applied": if now { "after-cancel" } else { "after-turn" }}),
            );
        }
        self.restart_on_route(session).await?;
        Ok(json!({"routeId": route, "applied": "now"}))
    }

    /// Restart the harness on its current binding and resume the same agent
    /// session; the new process starts now (prewarm), so the next prompt does
    /// not wait for it.
    pub(super) async fn restart_on_route(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<(), RpcError> {
        session.route_switch.store(false, Ordering::SeqCst);
        if session.child.lock().await.is_none() {
            return Ok(());
        }
        self.detach_child(session).await;
        self.child_for(session).await.map(|_| ())
    }

    /// `_acpmux/sessions/restart_harness {harnesses?, sessions?}` (Update
    /// Everything, cx-1mbnu; a chat's "Restart chat"): every live session of
    /// this daemon (none mirrored from a peer; none of the Home Chief's unless
    /// named in `sessions`), or those of the named harnesses and/or the named
    /// sessions, restarts its harness process and resumes the same agent
    /// session, as a route switch does but with no binding written: so it runs
    /// the version an update just installed. A session between turns restarts
    /// now; one in a turn when the turn ends (never cancelled). Returns how
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
            // meanwhile.
            let idle = || {
                if session.turn().is_none() { session.turn_lock.try_lock().ok() } else { None }
            };
            let mut turn = idle();
            if turn.is_none() {
                session.route_switch.store(true, Ordering::SeqCst);
                // The turn may have ended before the flag was seen: then now.
                turn = idle().filter(|_| session.route_switch.load(Ordering::SeqCst));
            }
            let Some(_turn) = turn else { return Ok(false) };
            match self.restart_on_route(&session).await {
                Ok(()) => Ok(true),
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
fn is_chief(meta: &SessionMeta) -> bool {
    live_tags(meta).get("cmux.chief").is_some()
        || meta.name.starts_with("optchat-")
        || meta.harness.starts_with("optchat-compact-")
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
        let lower = message.to_lowercase();
        let route_class = super::turns::is_limit_error(message)
            || [
                "500",
                "502",
                "503",
                "529",
                "connection refused",
                "unreachable",
                "timed out",
                "agent process closed",
            ]
            .iter()
            .any(|w| lower.contains(w));
        if !route_class {
            return None;
        }
        let (dir, state) = routes::places(&*self.config.read().await);
        let meta = session.meta();
        let profile = self.config.read().await.harnesses.get(&meta.harness).cloned()?;
        let family = crate::config::derive_family(&meta.harness, &profile);
        let workspace = meta.session_env.get("CMUX_WORKSPACE_ID").map(String::as_str);
        let (id, _) =
            routes::bound_route(&routes::bindings(&state), &session.id, workspace, &family)?;
        let route = routes::find(dir.as_deref(), &id).ok()?;
        if routes::auto_probe_allowed(&id) {
            let (hub, s, r, st) = (self.clone(), session.clone(), route.clone(), state.clone());
            tokio::spawn(async move {
                let probe = routes::probe(&r, &st).await;
                hub.append(&s, "mux", "route_probe", probe);
            });
        }
        let next = route
            .file
            .fallback
            .iter()
            .filter(|f| **f != id)
            .find_map(|f| routes::find(dir.as_deref(), f).ok().filter(|r| r.serves(&family)));
        let mut out = json!({"route": {"routeId": id, "name": route.name()}});
        if let Some(next) = next {
            out["fallback"] = json!({"routeId": next.id, "name": next.name()});
            if route.file.auto_fallback
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
                out["fallback"]["applied"] = json!(true);
            }
        }
        Some(out)
    }
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
