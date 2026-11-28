//! Part of `Hub`; see `hub/mod.rs`. `agent/credentials.update {sessionId, env}`: the owner's Mac
//! replaces the Cloud credential of one of this daemon's own sessions (`agent_credentials.rs`), a
//! refreshed ChatGPT access token about ten minutes before the last one expires. Its agent then
//! restarts on the new credential and resumes the same conversation (Codex `thread/resume`, Claude
//! `--resume`), as a route switch does (`route_switch.rs` `restart_harnesses`): between turns now,
//! in a turn when the turn ends, never cancelled.
//!
//! A withdrawal is recorded without the credential, so a guest restart cannot reopen the chat on
//! its old key.

use super::*;

use crate::agent_credentials::{AgentCredential, Family};
use crate::store::ClaudeTokenRecovery;

impl Hub {
    /// After a daemon restart, the credential the adopted agent `harness_pid` of `session` was
    /// launched on (`agent_credentials::recovered`), held again for its next start. A credential
    /// already held (one the Mac sent since) stays. Its family was checked when it was applied, and
    /// is again at the next spawn (`agent_credentials::apply`). Names only are logged. Whether one
    /// was taken.
    pub(crate) fn recover_credential(
        &self,
        session: &Session,
        identity: Option<(u32, u64)>,
    ) -> bool {
        let Some((pid, start)) = identity else { return false };
        if session.read_meta(|meta| meta.credential_withdrawn || uses_claude_machine_login(meta)) {
            return false;
        }
        let mut held = session.credential.lock().unwrap_or_else(|e| e.into_inner());
        if held.is_some() {
            return false;
        }
        let Some(credential) =
            crate::agent_credentials::recovered_from_pid(pid, start, &session.id)
        else {
            return false;
        };
        let names: Vec<&str> = credential.names().collect();
        tracing::info!(session = %session.id, ?names, "the adopted agent's launch credential is held again");
        *held = Some(credential);
        true
    }

    /// Refuses `credential` for a chat of `harness` when its variable serves another family.
    pub(crate) async fn credential_serves(
        &self,
        harness: &str,
        credential: &AgentCredential,
    ) -> Result<(), RpcError> {
        let family = self.credential_family(harness).await;
        if Family::of_harness(&family) != Some(credential.family()) {
            return Err(RpcError::invalid_params(
                "this credential does not serve this chat's agent",
            )
            .with_data(json!({"reason": "credentials.family"})));
        }
        Ok(())
    }

    async fn credential_family(&self, harness: &str) -> String {
        let cfg = self.config.read().await;
        cfg.harnesses
            .get(harness)
            .map(|p| crate::config::derive_family(harness, p))
            .or_else(|| cfg.family(harness))
            .unwrap_or_else(|| harness.to_owned())
    }

    /// After a daemon restart, the launch credential the adopted agent's host says it started the
    /// agent with (`agent_credentials::launched_with`), held again for its next start. A credential
    /// already held stays. Names only are logged. Whether one was taken.
    pub(crate) fn hold_launch_credential(
        &self,
        session: &Session,
        env: &[(String, String)],
    ) -> bool {
        if session.read_meta(|meta| meta.credential_withdrawn || uses_claude_machine_login(meta)) {
            return false;
        }
        // Older hosts report the secret variable but omit endpoint metadata. An Anthropic
        // endpoint key can look like a setup token. Recover it only from a complete report or
        // the verified process environment, which also carries the launch endpoint.
        if env.iter().any(|(name, _)| name == crate::byo_endpoint::ANTHROPIC_KEY_ENV)
            && !env.iter().any(|(name, _)| name == crate::agent_credentials::ENDPOINT_MARKER)
        {
            return false;
        }
        let Some(credential) = crate::agent_credentials::recovered_from_launch(env) else {
            return false;
        };
        let mut held = session.credential.lock().unwrap_or_else(|e| e.into_inner());
        if held.is_some() {
            return false;
        }
        let names: Vec<&str> = credential.names().collect();
        tracing::info!(session = %session.id, ?names, "the adopted agent's host said its launch credential; held again");
        *held = Some(credential);
        true
    }

    /// Whether `session` (meta `m`) holds a launch credential that this daemon's memory alone keeps
    /// (its summary's `credentialOnlyHere`): one is held and its agent is hibernated, so no running
    /// agent carries it in its env for the next daemon to read back ([`Self::recover_credential`]).
    /// A machine update wakes such a session before it restarts this daemon (cmux-host
    /// `updater/credential_wake.rs`); without that, the chat's next start after the restart runs
    /// on the machine's own route ("Claude is not signed in here"). False for a closed or watched
    /// chat, which `session wake` does not start: its credential is still lost with the daemon.
    pub(super) fn credential_only_here(&self, session: &Session, m: &SessionMeta) -> bool {
        self.waking(session)
            && m.status != SessionStatus::Closed
            && m.watching.is_none()
            && !m.credential_withdrawn
            && session.credential.lock().unwrap_or_else(|e| e.into_inner()).is_some()
    }

    /// Named connections remain assigned even while their token awaits redelivery.
    pub(crate) fn has_delivered_credential(&self, session: &Session) -> bool {
        session.read_meta(|meta| meta.credential_connection.is_some())
            || session.credential.lock().unwrap_or_else(|e| e.into_inner()).is_some()
    }

    /// After explicit sign-in, switch this exact chat to its machine's Claude account.
    /// A false result means the chat already switched.
    pub(crate) async fn use_claude_machine_login(
        &self,
        session: &Arc<Session>,
    ) -> Result<bool, RpcError> {
        let _spawn = session.spawn_lock.lock().await;
        let previous = session.meta();
        let (_, route) = self.login_profile(session, "claude").await?;
        self.check_claude_recovery(session, route.as_deref()).await?;
        if uses_claude_machine_login(&previous) {
            return Ok(false);
        }
        // Verify that this chat can use the isolated account before dropping its credential.
        let mut next = previous.clone();
        next.claude_token_recovery = Some(ClaudeTokenRecovery::MachineLogin);
        next.credential_connection = None;
        let (profile, defaults) = {
            let cfg = self.config.read().await;
            let profile = super::resolve::session_profile_checked(
                &cfg,
                &next.harness,
                &next.cwd,
                next.remote_origin,
            )?;
            (profile, cfg.defaults_for(&next.harness).env)
        };
        self.spawn_profile_for(&next, &profile, &defaults).await?;
        {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            meta.claude_token_recovery = Some(ClaudeTokenRecovery::MachineLogin);
            meta.claude_login_restart_pending = Some(true);
            meta.credential_connection = None;
            meta.credential_withdrawn = false;
            meta.credential_model = None;
        }
        if let Err(error) = self.save_meta_answered(session) {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            meta.credential_connection = previous.credential_connection;
            meta.credential_withdrawn = previous.credential_withdrawn;
            meta.credential_model = previous.credential_model;
            meta.claude_token_recovery = previous.claude_token_recovery;
            meta.claude_login_restart_pending = previous.claude_login_restart_pending;
            return Err(error);
        }
        session.credential.lock().unwrap_or_else(|e| e.into_inner()).take();
        Ok(true)
    }

    pub(crate) async fn check_claude_recovery(
        &self,
        session: &Session,
        route: Option<&str>,
    ) -> Result<(), RpcError> {
        if route.is_some() {
            return Err(RpcError::invalid_params(
                "this chat uses a provider route; sign in to that route",
            )
            .with_data(json!({"reason": crate::agent_login::reason::RECOVERY_MISMATCH})));
        }
        let meta = session.meta();
        if uses_claude_machine_login(&meta) || self.has_saved_claude_token(session, &meta).await {
            return Ok(());
        }
        Err(RpcError::invalid_params("this chat has no saved Claude token to replace")
            .with_data(json!({"reason": crate::agent_login::reason::RECOVERY_MISMATCH})))
    }

    pub(super) async fn has_saved_claude_token(
        &self,
        session: &Session,
        meta: &SessionMeta,
    ) -> bool {
        {
            let held = session.credential.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(credential) = held.as_ref() {
                return credential.uses_claude_subscription_token();
            }
        }
        if meta.claude_token_recovery == Some(ClaudeTokenRecovery::LegacyRejected)
            || meta.last_turn.as_ref().and_then(|turn| turn["errorCode"].as_str())
                == Some("claude_cloud_token_rejected")
        {
            return true;
        }
        let Some(connection) = meta.credential_connection.as_deref() else { return false };
        if is_saved_claude_token(connection) {
            return true;
        }
        let dir = crate::routes::places(&*self.config.read().await).0;
        let Some(dir) = dir else { return false };
        let id = connection.split_once(':').map_or(connection, |(id, _)| id).to_owned();
        tokio::task::spawn_blocking(move || {
            crate::routes::find(Some(&dir), &id)
                .is_ok_and(|route| route.file.kind == crate::routes::RouteKind::ClaudeToken)
        })
        .await
        .unwrap_or(false)
    }

    /// Under the turn and spawn locks, recover a missed host's work before deciding whether it can end.
    /// Returns whether the restart should prewarm a replacement.
    pub(super) async fn end_previous_claude_host(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<bool, RpcError> {
        let current = session.child.lock().await.clone();
        let retry = current.is_some();
        let child = match current {
            Some(child) if child.is_alive().await && !child.is_stopped() => Some(child),
            _ if Self::host_record_gone(&session.id) => None,
            _ => match Box::pin(self.readopt(session)).await {
                Some(child) => Some(child),
                None if Self::host_record_gone(&session.id) => None,
                None => return Err(claude_login_busy()),
            },
        };
        let _link = match &child {
            Some(child) => child.try_hold_host_link().map_err(|_| claude_login_busy())?,
            None => None,
        };
        if let Some(child) = &child {
            let verified = if child.recovery_replay_complete() {
                Self::drain_inbound(session).await
            } else {
                retry && self.verify_recovery_replay(session, child).await
            };
            if !verified || !child.is_alive().await || child.is_stopped() || child.is_retired() {
                return Err(claude_login_busy());
            }
        }
        if session.turn().is_some()
            || session.harness_turn.load(Ordering::SeqCst)
            || session.compacting.load(Ordering::SeqCst)
            || session.asks_in_flight.load(Ordering::SeqCst) != 0
            || !session.pending_permissions().is_empty()
            || self.holds_work_below(session)
        {
            return Err(claude_login_busy());
        }
        session.route_switch.store(false, Ordering::SeqCst);
        let Some(child) = &child else { return Ok(false) };
        // The old host's incarnation, read before it ends: its end is proven by its own live lock.
        let old_host = child.host_record();
        self.detach_claude_recovery_child(session).await;
        // A host that took its terminate releases its live lock as it exits, shortly after the
        // detach returns: wait for that end, bounded, before calling the host unreachable.
        let host_ended = match old_host {
            Some(record) => {
                crate::agent_host::wait_dead_async(
                    crate::agent_host::hosts_dir(),
                    session.id.clone(),
                    record.start_nonce,
                    std::time::Duration::from_secs(5),
                )
                .await
            }
            None => true,
        };
        if session.child.lock().await.is_some() || !host_ended {
            return Err(RpcError::internal(
                "this session's agent host is still running, cannot be reached and did not end; close the session to end it",
            ));
        }
        Ok(true)
    }

    /// Sets `credential` on session `id` (its exact id, a session of this daemon) and restarts its
    /// live agent on it. A credential of another family than the session's harness is refused.
    pub(crate) async fn update_credential(
        self: &Arc<Self>,
        id: &str,
        mut credential: AgentCredential,
        legacy_refresh: bool,
    ) -> Result<Value, RpcError> {
        let session = self.credential_session(id)?;
        self.credential_serves(&session.meta().harness, &credential).await?;
        let changed = {
            let _spawn = session.spawn_lock.lock().await;
            let meta = session.meta();
            if uses_claude_machine_login(&meta) {
                return Err(RpcError::invalid_params("this chat uses the machine's Claude login"));
            }
            if legacy_refresh && meta.credential_withdrawn {
                return Err(credential_needed());
            }
            if legacy_refresh
                && (!credential.is_chatgpt_plan()
                    || meta
                        .credential_connection
                        .as_ref()
                        .is_some_and(|binding| binding.contains(':'))
                    || session
                        .credential
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .as_ref()
                        .is_some_and(|current| !current.is_chatgpt_plan()))
            {
                return Err(RpcError::invalid_params(
                    "this credential does not serve this chat's agent",
                )
                .with_data(json!({"reason": "credentials.family"})));
            }
            credential.keep_connection(meta.credential_connection.as_deref());
            self.set_credential_withdrawn(&session, meta.credential_withdrawn, false)?;
            let mut held = session.credential.lock().unwrap_or_else(|e| e.into_inner());
            let changed = held.as_ref() != Some(&credential);
            #[cfg(unix)]
            if changed && credential.family() == Family::Copilot {
                crate::agent::copilot_auth::remove_session(&session.id);
            }
            *held = Some(credential);
            changed
        };
        // A start waiting for it goes on now (`owner_credential_ready`).
        session.credential_set.notify_waiters();
        if !session.read_meta(|m| m.owner_credential) {
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).owner_credential = true;
            self.save_meta(&session);
        }
        if !changed || session.child.lock().await.is_none() {
            // The next start runs on it.
            return Ok(json!({"sessionId": session.id, "restart": "none"}));
        }
        let only = std::collections::BTreeSet::from([session.id.clone()]);
        let out = self.restart_harnesses(None, Some(&only)).await;
        if let Some((_, error)) = out.failed.first() {
            return Err(RpcError::internal(format!("the agent did not start again: {error}")));
        }
        let restart = if out.now > 0 {
            "now"
        } else if out.after_turn > 0 {
            "afterTurn"
        } else {
            "none"
        };
        Ok(json!({"sessionId": session.id, "restart": restart}))
    }

    /// Before a start of `session`'s agent: a chat on the owner's credential
    /// (`SessionMeta::owner_credential`) that this daemon no longer holds (it restarted: a
    /// machine paused and resumed) waits up to [`OWNER_CREDENTIAL_WAIT`] for the owner's Mac to
    /// send it again (the Mac does when its link to the machine comes back), and is then refused
    /// with a named reason ([`needs_mac`]): never started on the machine's own route, whose
    /// harness would only say "Not logged in". A live agent (a host this daemon adopted keeps
    /// the env it started with) needs nothing.
    pub(super) async fn owner_credential_ready(&self, session: &Session) -> Result<(), RpcError> {
        if !session.read_meta(|m| m.owner_credential) {
            return Ok(());
        }
        let deadline = tokio::time::Instant::now() + OWNER_CREDENTIAL_WAIT;
        loop {
            // Made before the check: a send between the two still wakes it.
            let set = session.credential_set.notified();
            if session.credential.lock().unwrap_or_else(|e| e.into_inner()).is_some() {
                return Ok(());
            }
            if let Some(child) = session.child.lock().await.as_ref()
                && child.is_alive().await
            {
                return Ok(());
            }
            if tokio::time::timeout_at(deadline, set).await.is_err() {
                tracing::warn!(session = %session.id, "no owner's credential: the chat waits for the Mac");
                return Err(needs_mac(&session.meta().harness));
            }
        }
    }

    /// Name and presence of an owner's stored launch connection, for reattachment.
    pub(crate) async fn credential_status(&self, id: &str) -> Result<Value, RpcError> {
        let session = self.credential_session(id)?;
        let _spawn = session.spawn_lock.lock().await;
        let meta = session.meta();
        let held = session.credential.lock().unwrap_or_else(|e| e.into_inner()).is_some();
        let model =
            meta.credential_model.clone().or_else(|| super::model_options::current_model(&meta));
        Ok(json!({"connection": meta.credential_connection, "held": held,
            "model": model, "harness": meta.harness, "claudeTokenRecovery": uses_claude_machine_login(&meta).then_some("machineLogin")}))
    }

    /// Withdraw exact bindings delivered by the owner's Mac, including chats without a live tab.
    pub(crate) async fn withdraw_credential_bindings(
        self: &Arc<Self>,
        bindings: &std::collections::BTreeSet<&str>,
    ) -> Result<Value, RpcError> {
        self.wait_startup().await;
        let matching = self.session_handles().into_iter().filter_map(|session| {
            let binding = session.read_meta(|meta| {
                meta.credential_connection
                    .as_deref()
                    .filter(|binding| bindings.contains(binding))
                    .map(str::to_owned)
            })?;
            Some(async move { self.revoke_bound_credential(session, Some(&binding)).await })
        });
        let results = futures::future::join_all(matching).await;
        for result in results {
            result?;
        }
        Ok(json!({}))
    }

    /// The Cloud owner withdrew a delivered model credential.
    pub(crate) async fn revoke_credential(self: &Arc<Self>, id: &str) -> Result<Value, RpcError> {
        self.revoke_bound_credential(self.credential_session(id)?, None).await
    }

    async fn revoke_bound_credential(
        self: &Arc<Self>,
        session: Arc<Session>,
        binding: Option<&str>,
    ) -> Result<Value, RpcError> {
        #[cfg(unix)]
        let family = self.credential_family(&session.meta().harness).await;
        let _spawn = session.spawn_lock.lock().await;
        let meta = session.meta();
        if binding.is_some() && meta.credential_connection.as_deref() != binding {
            return Ok(json!({}));
        }
        if self.hands_off(&session) {
            return Err(withdrawal_pending());
        }
        let child = session.child.lock().await.clone();
        let held = session.credential.lock().unwrap_or_else(|e| e.into_inner()).is_some();
        let unverified_host = child.is_none() && !Self::host_record_gone(&session.id);
        if !held && meta.credential_connection.is_none() && !meta.credential_withdrawn {
            if unverified_host {
                return Err(withdrawal_pending());
            }
            return Ok(json!({"sessionId": session.id, "restart": "none"}));
        }
        // Record the withdrawal even if existing work prevents ending the host now. New starts
        // and live-child reuse read this under the same spawn lock. Try the other leases without
        // waiting because their holders may be waiting for the spawn lock.
        self.set_credential_withdrawn(&session, meta.credential_withdrawn, true)?;
        let _turn = session.turn_lock.try_lock().map_err(|_| withdrawal_pending())?;
        let _using = session.harness_use.try_write().map_err(|_| withdrawal_pending())?;
        if unverified_host {
            return Err(withdrawal_pending());
        }
        let host_nonce =
            child.as_ref().and_then(|child| child.host_record().map(|record| record.start_nonce));
        let _link = match &child {
            Some(child) => {
                let link = child.try_hold_host_link().map_err(|_| withdrawal_pending())?;
                let verified = if child.recovery_replay_complete() {
                    Self::drain_inbound(&session).await
                } else {
                    self.verify_recovery_replay(&session, child).await
                };
                if !verified
                    || child.is_stopped()
                    || child.is_retired()
                    || (host_nonce.is_some() && !child.is_alive().await)
                {
                    return Err(withdrawal_pending());
                }
                link
            }
            None => None,
        };
        if session.turn().is_some()
            || session.harness_turn.load(Ordering::SeqCst)
            || session.compacting.load(Ordering::SeqCst)
            || session.asks_in_flight.load(Ordering::SeqCst) != 0
            || session.agent_requests.load(Ordering::SeqCst) != 0
            || session.has_pending_permissions()
            || self.holds_work_below(&session)
        {
            return Err(withdrawal_pending());
        }
        if child.is_some() {
            // Use only the link whose work was checked. A lost link cannot justify killing a host.
            self.detach_claude_recovery_child(&session).await;
        }
        let host_ended = match host_nonce {
            Some(nonce) => {
                crate::agent_host::wait_dead_async(
                    crate::agent_host::hosts_dir(),
                    session.id.clone(),
                    nonce,
                    std::time::Duration::from_secs(5),
                )
                .await
            }
            None => Self::host_record_gone(&session.id),
        };
        if session.child.lock().await.is_some() || !host_ended {
            return Err(withdrawal_pending());
        }
        session.credential.lock().unwrap_or_else(|e| e.into_inner()).take();
        #[cfg(unix)]
        if Family::of_harness(&family) == Some(Family::Copilot) {
            crate::agent::copilot_auth::remove_session(&session.id);
        }
        Ok(json!({"sessionId": session.id, "restart": "none"}))
    }

    /// Called under the spawn lock, which orders withdrawal with redelivery and child admission.
    fn set_credential_withdrawn(
        &self,
        session: &Session,
        previous: bool,
        withdrawn: bool,
    ) -> Result<(), RpcError> {
        if previous == withdrawn {
            return Ok(());
        }
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).credential_withdrawn = withdrawn;
        if let Err(error) = self.save_meta_answered(session) {
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).credential_withdrawn = previous;
            return Err(error);
        }
        Ok(())
    }

    fn credential_session(&self, id: &str) -> Result<Arc<Session>, RpcError> {
        self.session_get(id).ok_or_else(|| {
            RpcError::not_found("no such session on this machine")
                .with_data(json!({"reason": "credentials.no_session"}))
        })
    }
}

/// How long a start waits for the owner's Mac to send the credential again: about one
/// reconnect's re-send, so a turn sent as the link comes back takes the credential.
#[cfg(not(test))]
pub(super) const OWNER_CREDENTIAL_WAIT: std::time::Duration = std::time::Duration::from_secs(5);
#[cfg(test)]
pub(super) const OWNER_CREDENTIAL_WAIT: std::time::Duration = std::time::Duration::from_secs(2);

/// The words the pane shows (`webviews/src/agent-session/acpmux/failureCopy.ts` `NEEDS_MAC`).
pub const NEEDS_MAC_TEXT: &str = "needs the Mac to sign in: open cmux";

/// The refusal of a start with no owner's credential: typed [`crate::recovery::kind::NEEDS_MAC`].
pub(super) fn needs_mac(harness: &str) -> RpcError {
    let name = if harness.starts_with("codex") { "Codex" } else { "Claude" };
    RpcError::new(-32001, format!("{name} {NEEDS_MAC_TEXT}")).with_data(json!({
        "reason": crate::recovery::kind::NEEDS_MAC,
        "errorKind": crate::recovery::kind::NEEDS_MAC,
        "recovery": "This chat signs in with the credential your Mac sends, and this machine has none \
                     since it resumed. Open cmux on your Mac: it sends the credential again when it \
                     reconnects to this machine. Then send the message again.",
    }))
}

fn withdrawal_pending() -> RpcError {
    RpcError::internal("the agent host is not ready for credential withdrawal")
        .with_data(json!({"reason": "credentials.host_pending"}))
}

pub(super) fn credential_needed() -> RpcError {
    RpcError::invalid_params("This chat needs its model connection from your Mac.")
        .with_data(json!({"reason": "credentials.needed"}))
}

fn is_saved_claude_token(id: &str) -> bool {
    let id = id.split_once(':').map_or(id, |(id, _)| id);
    id == "claude-token"
        || id.strip_prefix("claude-token-").is_some_and(|suffix| suffix.parse::<u64>().is_ok())
}

pub(super) fn uses_claude_machine_login(meta: &SessionMeta) -> bool {
    meta.claude_token_recovery == Some(ClaudeTokenRecovery::MachineLogin)
}

pub(super) fn claude_login_needs_restart(meta: &SessionMeta) -> bool {
    uses_claude_machine_login(meta) && meta.claude_login_restart_pending != Some(false)
}

pub(super) fn claude_login_busy() -> RpcError {
    RpcError::invalid_params(
        "This chat is moving to this machine's Claude sign-in. Send again when its background work ends.",
    )
    .with_data(json!({"reason": "credentials.claude_login_busy"}))
}

/// For tests outside the hub (a move's finish, `cli/run/session_move_snapshot_tests.rs`): the
/// credential chat `id` holds, and the env its agent was started with.
#[cfg(test)]
impl Hub {
    pub(crate) fn held_credential(&self, id: &str) -> Option<AgentCredential> {
        let session = self.resolve(id).ok()?;
        session.credential.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub(crate) async fn started_env(
        self: &Arc<Self>,
        id: &str,
    ) -> Option<std::collections::BTreeMap<String, String>> {
        let session = self.resolve(id).ok()?;
        self.child_for(&session).await.ok()?;
        session.launch_env.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

#[cfg(test)]
mod tests {
    use crate::agent_credentials::{AgentCredential, CHATGPT_TOKEN, CLAUDE_OAUTH};
    use crate::config::{Config, StoreMode};
    use crate::hub::{Hub, NewRequest};
    use serde_json::json;
    use std::path::Path;
    use std::sync::Arc;

    const FIRST: &str = "sk-ant-oat01-first-token-value";
    const SECOND: &str = "sk-ant-oat01-second-token-value";
    const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

    fn hub() -> Arc<Hub> {
        hub_for("claude", &["python3", FAKE])
    }

    fn hub_for(family: &str, argv: &[&str]) -> Arc<Hub> {
        let harness = format!("{family}-fake");
        let mut cfg = serde_json::from_value::<Config>(json!({
            "harnesses": {(&harness): {"argv": argv, "family": family}},
            "defaultHarness": harness
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        cfg.profile_sources = crate::config::ProfileSources::none();
        let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    }

    #[cfg(unix)]
    async fn recovery_hub() -> (tempfile::TempDir, Arc<Hub>) {
        use std::os::unix::fs::PermissionsExt as _;

        let root = tempfile::tempdir().unwrap();
        let launcher = root.path().join("claude");
        std::fs::copy(FAKE, &launcher).unwrap();
        std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o700)).unwrap();
        let hub = hub();
        {
            let mut cfg = hub.config.write().await;
            let profile = cfg.harnesses.get_mut("claude-fake").unwrap();
            profile.argv = vec![launcher.display().to_string()];
            let cli = serde_json::from_value(json!({"kind": "claude-stdio", "argv": [launcher]}))
                .unwrap();
            cfg.harnesses.insert("claude".into(), cli);
        }
        (root, hub)
    }

    fn credential(token: &str) -> AgentCredential {
        AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: token}})).unwrap()
    }

    /// Everything this daemon wrote down about the session: its meta and its whole log.
    fn written(hub: &Hub, id: &str) -> String {
        let session = hub.resolve(id).unwrap();
        let records = hub.events(id, 0, 100_000).unwrap();
        let log: Vec<_> = records.into_iter().map(|r| (r.kind, r.msg)).collect();
        format!("{}\n{}", serde_json::to_string(&session.meta()).unwrap(), json!(log))
    }

    fn launched(session: &crate::hub::Session) -> std::collections::BTreeMap<String, String> {
        session.launch_env.lock().unwrap().clone().unwrap_or_default()
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_credential_reaches_only_its_agent_and_is_never_written_down() {
        let hub = hub();
        let req = NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential(FIRST)),
            ..NewRequest::default()
        };
        let session = hub.new_session(req).await.unwrap();
        hub.child_for(&session).await.unwrap();
        let env = launched(&session);
        assert_eq!(env.get(CLAUDE_OAUTH).map(String::as_str), Some(FIRST));
        let unset = env.get(crate::routes::UNSET_KEY).cloned().unwrap_or_default();
        for key in crate::cloud_model_plane::KEYS {
            assert!(unset.split(',').any(|k| k == key), "{key} is removed for this agent");
        }
        // Another chat on the same daemon runs on the machine's own route.
        let other = hub
            .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
            .await
            .unwrap();
        hub.child_for(&other).await.unwrap();
        assert!(!launched(&other).contains_key(CLAUDE_OAUTH));
        assert!(!written(&hub, &session.id).contains(FIRST), "no meta or log record holds it");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_cloud_gemini_fork_refuses_to_replay_on_the_machine_account() {
        let hub = hub_for("gemini", &["python3", FAKE]);
        hub.config.write().await.cloud_host = true;
        hub.config.write().await.harnesses.get_mut("gemini-fake").unwrap().env.extend([
            ("FAKE_NO_FORK".into(), "1".into()),
            ("GEMINI_API_KEY".into(), "machine-fixture".into()),
        ]);
        let credential = AgentCredential::parse(&json!({
            "connection": "google-key",
            "env": {"GEMINI_API_KEY": "owner-fixture"}
        }))
        .unwrap();
        let session = hub
            .new_session(NewRequest {
                cwd: Some(std::env::temp_dir()),
                credential: Some(credential),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        assert_eq!(launched(&session)["GEMINI_API_KEY"], "owner-fixture");

        let prompt = || vec![json!({"type": "text", "text": "parent history"})];
        hub.prompt(&session, prompt(), "test", false).await.unwrap();
        let (shown, showing) = tokio::sync::oneshot::channel();
        let (release, released) = tokio::sync::oneshot::channel();
        *hub.family_write_seam.lock().unwrap() = Some((shown, released));
        let turn = tokio::spawn({
            let (hub, session) = (hub.clone(), session.clone());
            async move { hub.prompt(&session, prompt(), "test", false).await }
        });
        tokio::time::timeout(std::time::Duration::from_secs(10), showing).await.unwrap().unwrap();
        assert_eq!(session.status(), crate::store::SessionStatus::Running);
        let fork = hub.fork(&session, None, None, Default::default(), None, None, true).await;
        release.send(()).unwrap();
        turn.await.unwrap().unwrap();
        let error = fork.err().expect("a fork cannot use the machine's default key");
        assert_eq!(error.data.unwrap()["reason"], "credentials.needed");
        assert!(hub.sessions().iter().all(|s| s.meta().parent_id.is_none()));
        hub.shutdown_all().await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_update_restarts_the_agent_on_the_new_credential_in_the_same_chat() {
        let hub = hub();
        let req = NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential(FIRST)),
            ..NewRequest::default()
        };
        let session = hub.new_session(req).await.unwrap();
        let before = hub.child_for(&session).await.unwrap().generation;
        let reply = hub.update_credential(&session.id, credential(SECOND), false).await.unwrap();
        assert_eq!(reply["restart"], "now");
        let after = hub.child_for(&session).await.unwrap().generation;
        assert_ne!(before, after, "a new agent process");
        assert_eq!(launched(&session).get(CLAUDE_OAUTH).map(String::as_str), Some(SECOND));
        assert_eq!(hub.resolve(&session.id).unwrap().id, session.id, "the same chat");
        let text = format!("{reply}{}", written(&hub, &session.id));
        assert!(!text.contains(FIRST) && !text.contains(SECOND));
        // The same credential again restarts nothing.
        let again = hub.update_credential(&session.id, credential(SECOND), false).await.unwrap();
        assert_eq!(again["restart"], "none");
    }

    /// cmux#45776: a daemon restart forgets the credential (memory only), while the agent it adopts
    /// still runs on it. Read back from that agent's env, the agent's next start (a wake after the
    /// machine paused) runs on it again instead of the machine's route ("Claude is not signed in").
    #[cfg(target_os = "linux")]
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_adopted_agents_credential_is_held_again_for_its_next_start() {
        let hub = hub();
        let req = NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential(FIRST)),
            ..NewRequest::default()
        };
        let session = hub.new_session(req).await.unwrap();
        let child = hub.child_for(&session).await.unwrap();
        let pid = child.pid.expect("the agent's pid");
        let start = crate::owner_exit::process_start(pid).unwrap();
        let identity = Some((pid, start));
        let other = hub
            .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
            .await
            .unwrap();
        assert!(
            !hub.recover_credential(&other, identity),
            "same-family chat cannot take the credential"
        );
        // What a new daemon has of the session: no credential.
        *session.credential.lock().unwrap() = None;
        assert!(
            !hub.recover_credential(&session, Some((pid, start + 1))),
            "a reused PID is refused"
        );
        assert!(hub.recover_credential(&session, identity));
        assert_eq!(*session.credential.lock().unwrap(), Some(credential(FIRST)));
        // One the Mac sent since stays.
        *session.credential.lock().unwrap() = Some(credential(SECOND));
        assert!(!hub.recover_credential(&session, identity));
        assert_eq!(*session.credential.lock().unwrap(), Some(credential(SECOND)));
        // The next start runs on the held credential.
        *session.credential.lock().unwrap() = None;
        assert!(hub.recover_credential(&session, identity));
        let before = child.generation;
        let only = std::collections::BTreeSet::from([session.id.clone()]);
        hub.restart_harnesses(None, Some(&only)).await;
        let after = hub.child_for(&session).await.unwrap().generation;
        assert_ne!(before, after, "a new agent process");
        assert_eq!(launched(&session).get(CLAUDE_OAUTH).map(String::as_str), Some(FIRST));
        assert!(!written(&hub, &session.id).contains(FIRST), "still never written down");
    }

    #[cfg(target_os = "linux")]
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_agent_launched_without_a_credential_gives_none_back() {
        let hub = hub();
        let session = hub
            .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
            .await
            .unwrap();
        let pid = hub.child_for(&session).await.unwrap().pid.expect("the agent's pid");
        let identity = Some((pid, crate::owner_exit::process_start(pid).unwrap()));
        assert!(!hub.recover_credential(&session, identity));
        assert!(session.credential.lock().unwrap().is_none());
        assert!(!hub.recover_credential(&session, None));
    }

    #[tokio::test]
    async fn a_host_report_cannot_restore_a_withdrawn_or_replaced_credential() {
        let hub = hub();
        let session = hub
            .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
            .await
            .unwrap();
        let report = |name: &str| {
            vec![
                (crate::agent_credentials::MARKER.into(), name.into()),
                (name.into(), FIRST.into()),
            ]
        };
        assert!(
            !hub.hold_launch_credential(&session, &report(crate::byo_endpoint::ANTHROPIC_KEY_ENV))
        );
        let report = report(CLAUDE_OAUTH);
        assert!(hub.hold_launch_credential(&session, &report));
        assert_eq!(*session.credential.lock().unwrap(), Some(credential(FIRST)));
        *session.credential.lock().unwrap() = None;
        hub.edit_test_meta(&session, |meta| meta.credential_withdrawn = true);
        assert!(!hub.hold_launch_credential(&session, &report));
        hub.edit_test_meta(&session, |meta| {
            meta.credential_withdrawn = false;
            meta.claude_token_recovery = Some(crate::store::ClaudeTokenRecovery::MachineLogin);
        });
        assert!(!hub.hold_launch_credential(&session, &report));
        assert!(session.credential.lock().unwrap().is_none());
    }

    /// An idle chat's agent is hibernated while a machine update restarts the daemon: the
    /// credential was in the daemon's memory only, and the next message said "Claude is not signed
    /// in here". The session's summary says so while it lasts, and the wake a machine update asks
    /// for starts the agent on the credential, which then carries it in its env.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_hibernated_chats_credential_is_marked_until_a_wake_puts_it_on_an_agent() {
        let hub = hub();
        let only_here =
            |s: &crate::hub::Session| hub.session_summary(s)["credentialOnlyHere"] == json!(true);
        let req = NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential(FIRST)),
            ..NewRequest::default()
        };
        let session = hub.new_session(req).await.unwrap();
        hub.child_for(&session).await.unwrap();
        assert!(!only_here(&session), "its running agent carries it");
        let paused = hub.pause(&session).await.unwrap();
        assert_eq!(paused["paused"], true, "{paused}");
        assert!(only_here(&session), "hibernated: only this daemon's memory holds it");
        let summary = hub.session_summary(&session).to_string();
        assert!(!summary.contains(FIRST) && !summary.contains(CLAUDE_OAUTH), "{summary}");
        // Without a credential a hibernated chat has nothing to lose.
        let plain = hub
            .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
            .await
            .unwrap();
        hub.child_for(&plain).await.unwrap();
        assert_eq!(hub.pause(&plain).await.unwrap()["paused"], true);
        assert!(hub.session_summary(&plain).get("credentialOnlyHere").is_none());
        // The wake starts the agent on it.
        let woke = hub.wake(&session).await.unwrap();
        assert_eq!(woke["woke"], true, "{woke}");
        assert_eq!(launched(&session).get(CLAUDE_OAUTH).map(String::as_str), Some(FIRST));
        assert!(!only_here(&session));
        assert!(!written(&hub, &session.id).contains(FIRST), "still never written down");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn claude_recovery_keeps_the_active_turn_and_restarts_without_the_token() {
        let (_root, hub) = recovery_hub().await;
        let session = hub
            .new_session(NewRequest {
                cwd: Some(std::env::temp_dir()),
                credential: Some(credential(FIRST)),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        let before = hub.child_for(&session).await.unwrap().generation;
        let (shown, turn_shown) = tokio::sync::oneshot::channel();
        let (resume, wait) = tokio::sync::oneshot::channel();
        *hub.family_write_seam.lock().unwrap() = Some((shown, wait));
        let turn = tokio::spawn({
            let (hub, session) = (hub.clone(), session.clone());
            async move {
                hub.prompt(&session, vec![json!({"type": "text", "text": "first"})], "test", false)
                    .await
            }
        });
        turn_shown.await.unwrap();
        assert!(hub.use_claude_machine_login(&session).await.unwrap());
        let only = std::collections::BTreeSet::from([session.id.clone()]);
        let restarts = hub.restart_harnesses(None, Some(&only)).await;
        assert_eq!((restarts.now, restarts.after_turn), (0, 1));
        assert!(session.turn().is_some());
        assert_eq!(session.child.lock().await.as_ref().unwrap().generation, before);

        resume.send(()).unwrap();
        turn.await.unwrap().unwrap();
        hub.prompt(&session, vec![json!({"type": "text", "text": "next"})], "test", false)
            .await
            .unwrap();
        assert_ne!(hub.child_for(&session).await.unwrap().generation, before);
        assert!(!launched(&session).contains_key(CLAUDE_OAUTH));
        assert_eq!(launched(&session).get("CMUX_CLAUDE_AUTH").map(String::as_str), Some("own"));
        assert_eq!(session.meta().claude_login_restart_pending, Some(false));
        hub.shutdown_all().await;
    }

    #[tokio::test]
    async fn claude_recovery_keeps_the_token_if_the_launcher_cannot_use_the_machine_login() {
        let hub = hub();
        let session = hub
            .new_session(NewRequest {
                cwd: Some(std::env::temp_dir()),
                credential: Some(credential(FIRST)),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        let error = hub.use_claude_machine_login(&session).await.unwrap_err();
        assert_eq!(error.data.unwrap()["reason"], "route.unavailable");
        let status = hub.credential_status(&session.id).await.unwrap();
        assert_eq!(status["held"], true);
        assert!(status["claudeTokenRecovery"].is_null());
        hub.shutdown_all().await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn recovery_saved_after_prompt_preflight_refuses_the_old_child() {
        let (_root, hub) = recovery_hub().await;
        let session = hub
            .new_session(NewRequest {
                cwd: Some(std::env::temp_dir()),
                credential: Some(credential(FIRST)),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        let old = hub.child_for(&session).await.unwrap();
        let (shown, turn_shown) = tokio::sync::oneshot::channel();
        let (resume, wait) = tokio::sync::oneshot::channel();
        *hub.turn_shown_seam.lock().unwrap() = Some((shown, wait));
        let send = tokio::spawn({
            let (hub, session) = (hub.clone(), session.clone());
            async move {
                hub.prompt(
                    &session,
                    vec![json!({"type": "text", "text": "racing Claude recovery"})],
                    "test",
                    false,
                )
                .await
            }
        });
        turn_shown.await.unwrap();
        assert!(hub.use_claude_machine_login(&session).await.unwrap());
        let only = std::collections::BTreeSet::from([session.id.clone()]);
        assert_eq!(hub.restart_harnesses(None, Some(&only)).await.after_turn, 1);
        assert!(old.is_alive().await);

        resume.send(()).unwrap();
        let error = send.await.unwrap().unwrap_err();
        assert_eq!(error.data.unwrap()["reason"], "credentials.claude_login_busy");
        assert!(!written(&hub, &session.id).contains("echo: racing Claude recovery"));
        hub.prompt(&session, vec![json!({"type": "text", "text": "next"})], "test", false)
            .await
            .unwrap();
        assert_ne!(hub.child_for(&session).await.unwrap().generation, old.generation);
        assert!(!launched(&session).contains_key(CLAUDE_OAUTH));
        hub.shutdown_all().await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_prompt_waits_for_background_work_before_switching_to_claude_login() {
        use std::sync::atomic::Ordering;

        let (_root, hub) = recovery_hub().await;
        let session = hub
            .new_session(NewRequest {
                cwd: Some(std::env::temp_dir()),
                credential: Some(credential(FIRST)),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        let old = hub.child_for(&session).await.unwrap();
        *session.work_below_since.lock().unwrap() = 1;
        assert!(hub.use_claude_machine_login(&session).await.unwrap());
        let only = std::collections::BTreeSet::from([session.id.clone()]);
        let restarts = hub.restart_harnesses(None, Some(&only)).await;
        assert_eq!(restarts.after_turn, 1);
        assert!(session.route_switch.load(Ordering::SeqCst));

        let prompt = || vec![json!({"type": "text", "text": "hello"})];
        let refused = hub.prompt(&session, prompt(), "test", false).await.unwrap_err();
        assert!(!refused.message.contains(FIRST));
        let data = refused.data.unwrap();
        assert_eq!(data, json!({"reason": "credentials.claude_login_busy"}));
        assert!(hub.holds_work_below(&session));
        assert!(old.is_alive().await);
        assert_eq!(session.child.lock().await.as_ref().unwrap().generation, old.generation);

        *session.work_below_since.lock().unwrap() = 0;
        hub.prompt(&session, prompt(), "test", false).await.unwrap();
        assert_ne!(hub.child_for(&session).await.unwrap().generation, old.generation);
        assert!(!launched(&session).contains_key(CLAUDE_OAUTH));
        hub.shutdown_all().await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_prompt_after_the_recovery_save_uses_the_machine_login_before_restart_is_requested() {
        use std::sync::atomic::Ordering;

        let (_root, hub) = recovery_hub().await;
        let session = hub
            .new_session(NewRequest {
                cwd: Some(std::env::temp_dir()),
                credential: Some(credential(FIRST)),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        let old = hub.child_for(&session).await.unwrap();
        // The state between use_claude_machine_login and restart_harnesses in signed_in.
        assert!(hub.use_claude_machine_login(&session).await.unwrap());
        assert!(!session.route_switch.load(Ordering::SeqCst));
        assert_eq!(session.meta().claude_login_restart_pending, Some(true));

        hub.prompt(&session, vec![json!({"type": "text", "text": "hello"})], "test", false)
            .await
            .unwrap();
        assert_ne!(hub.child_for(&session).await.unwrap().generation, old.generation);
        assert!(!launched(&session).contains_key(CLAUDE_OAUTH));
        assert_eq!(session.meta().claude_login_restart_pending, Some(false));
        hub.shutdown_all().await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_cold_start_waiting_on_recovery_reads_the_new_credential() {
        use std::{future::Future as _, task::Poll};

        let (_root, hub) = recovery_hub().await;
        let session = hub
            .new_session(NewRequest {
                cwd: Some(std::env::temp_dir()),
                credential: Some(credential(FIRST)),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        assert_eq!(hub.pause(&session).await.unwrap()["paused"], true);
        let lock = session.spawn_lock.lock().await;
        let mut recovery = std::pin::pin!(hub.use_claude_machine_login(&session));
        assert!(futures::poll!(recovery.as_mut()).is_pending());
        let mut start = std::pin::pin!(hub.child_for(&session));
        use super::super::full_access_bound::AT_OPERATION_ENTRY;
        AT_OPERATION_ENTRY.with(|hook| hook.set(Some(|_| {})));
        std::future::poll_fn(|cx| {
            assert!(start.as_mut().poll(cx).is_pending());
            if AT_OPERATION_ENTRY.with(|hook| hook.get().is_none()) {
                Poll::Ready(())
            } else {
                Poll::Pending
            }
        })
        .await;

        drop(lock);
        assert!(recovery.await.unwrap());
        start.await.unwrap();
        assert!(!launched(&session).contains_key(CLAUDE_OAUTH));
        assert_eq!(launched(&session).get("CMUX_CLAUDE_AUTH").map(String::as_str), Some("own"));
        hub.shutdown_all().await;
    }

    #[tokio::test]
    async fn a_saved_claude_rejection_survives_grant_loss_and_later_turns() {
        let hub = hub();
        let session = hub
            .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
            .await
            .unwrap();
        session.meta.lock().unwrap().last_turn =
            Some(json!({"errorCode": "claude_cloud_token_rejected"}));
        hub.check_claude_recovery(&session, None).await.unwrap();
        for connection in [None, Some("custom-mac-only:0123456789abcdef")] {
            {
                let mut meta = session.meta.lock().unwrap();
                meta.credential_connection = connection.map(str::to_owned);
                meta.claude_token_recovery = None;
            }
            hub.record_last_turn(&session, &json!({"errorCode": "claude_cloud_token_rejected"}));
            hub.check_claude_recovery(&session, None).await.unwrap();

            hub.record_last_turn(&session, &json!({"errorCode": "model_not_found"}));
            assert_eq!(session.meta().last_turn.unwrap()["errorCode"], "model_not_found");
            hub.check_claude_recovery(&session, None).await.unwrap();
        }
        hub.shutdown_all().await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn withdrawal_waits_for_a_live_turn_permission_and_background_work() {
        use crate::hub::{Control, person::Answerer};

        let (_root, hub) = recovery_hub().await;
        let credential = AgentCredential::parse(&json!({
            "env": {"ANTHROPIC_API_KEY": "fixture-key"}, "connection": "personal-models"
        }))
        .unwrap();
        let session = hub
            .new_session(NewRequest {
                cwd: Some(std::env::temp_dir()),
                credential: Some(credential),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        let child = hub.child_for(&session).await.unwrap();
        let mut events = hub.subscribe();
        let turn = {
            let (hub, session) = (hub.clone(), session.clone());
            tokio::spawn(async move {
                hub.prompt(
                    &session,
                    vec![json!({"type": "text", "text": "ask: fixture permission"})],
                    "test",
                    false,
                )
                .await
            })
        };
        let timeout = std::time::Duration::from_secs(15);
        let permission = tokio::time::timeout(timeout, async {
            loop {
                let event = events.recv().await.unwrap();
                if event.record.kind == "permission_request" && event.session_id == session.id {
                    break event.record.msg["permissionId"].as_str().unwrap().to_owned();
                }
            }
        })
        .await
        .unwrap();
        let pending = hub.revoke_credential(&session.id).await.unwrap_err();
        assert_eq!(pending.data.unwrap()["reason"], "credentials.host_pending");
        assert!(child.is_alive().await);
        assert_eq!(hub.credential_status(&session.id).await.unwrap()["held"], true);
        hub.respond_permission(
            &session,
            &permission,
            Some("no".into()),
            None,
            None,
            Answerer { person: true, ..Default::default() },
            Control::Local,
        )
        .await
        .unwrap();
        assert_eq!(
            tokio::time::timeout(timeout, turn).await.unwrap().unwrap().unwrap()["stopReason"],
            "end_turn"
        );

        let follow_up = hub
            .prompt(
                &session,
                vec![json!({"type": "text", "text": "follow-up before the owner's retry"})],
                "test",
                false,
            )
            .await
            .unwrap_err();
        assert_eq!(follow_up.data.unwrap()["reason"], "credentials.needed");
        assert!(child.is_alive().await);

        *session.work_below_since.lock().unwrap() = 1;
        let pending = hub.revoke_credential(&session.id).await.unwrap_err();
        assert_eq!(pending.data.unwrap()["reason"], "credentials.host_pending");
        assert!(child.is_alive().await);

        *session.work_below_since.lock().unwrap() = 0;
        hub.revoke_credential(&session.id).await.unwrap();
        assert!(!child.is_alive().await);
        assert_eq!(hub.credential_status(&session.id).await.unwrap()["held"], false);
        let error = hub.child_for(&session).await.err().expect("withdrawn key cannot be used");
        assert_eq!(error.data.unwrap()["reason"], "credentials.needed");
        hub.update_credential(
            &session.id,
            AgentCredential::parse(&json!({"env": {"ANTHROPIC_API_KEY": "fixture-key"}})).unwrap(),
            false,
        )
        .await
        .unwrap();
        assert_eq!(
            hub.prompt(
                &session,
                vec![json!({"type": "text", "text": "after redelivery"})],
                "test",
                false,
            )
            .await
            .unwrap()["stopReason"],
            "end_turn"
        );
        hub.shutdown_all().await;
    }

    #[tokio::test]
    async fn a_named_cloud_connection_refuses_respawn_until_the_owner_redelivers() {
        let hub = hub();
        let credential = AgentCredential::parse(&json!({
            "env": {CLAUDE_OAUTH: FIRST}, "connection": "personal-models"
        }))
        .unwrap();
        let session = hub
            .new_session(NewRequest {
                cwd: Some(std::env::temp_dir()),
                credential: Some(credential.clone()),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        hub.child_for(&session).await.unwrap();
        let status = hub.credential_status(&session.id).await.unwrap();
        assert_eq!(status["connection"], "personal-models");
        assert_eq!(status["held"], true);
        assert!(!written(&hub, &session.id).contains(FIRST));

        hub.revoke_credential(&session.id).await.unwrap();
        let error = hub.child_for(&session).await.err().expect("missing grant blocks launch");
        assert_eq!(error.data.unwrap()["reason"], "credentials.needed");

        hub.update_credential(&session.id, credential, false).await.unwrap();
        hub.child_for(&session).await.unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn legacy_refresh_cannot_replace_a_bound_chatgpt_credential() {
        let hub = hub_for("codex", &["python3", FAKE, "app-server"]);
        let credential =
            AgentCredential::parse(&json!({"env": {CHATGPT_TOKEN: "old-fixture-token"}})).unwrap();
        let fresh =
            AgentCredential::parse(&json!({"env": {CHATGPT_TOKEN: "new-fixture-token"}})).unwrap();
        let binding = format!("chatgpt:{}", "a".repeat(64));
        for (connection, allowed) in [(None, true), (Some(binding.as_str()), false)] {
            let mut initial = credential.clone();
            initial.keep_connection(connection);
            let session = hub
                .new_session(NewRequest {
                    cwd: Some(std::env::temp_dir()),
                    credential: Some(initial.clone()),
                    ..NewRequest::default()
                })
                .await
                .unwrap();
            assert_eq!(
                hub.update_credential(&session.id, fresh.clone(), true).await.is_ok(),
                allowed
            );
            let held = session.credential.lock().unwrap();
            assert_eq!(held.as_ref(), Some(if allowed { &fresh } else { &initial }));
        }
        hub.shutdown_all().await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_update_of_another_family_or_an_unknown_session_is_refused() {
        let hub = hub();
        let session = hub
            .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
            .await
            .unwrap();
        let codex = AgentCredential::parse(
            &json!({"env": {crate::agent_credentials::OPENAI_KEY: "sk-proj-x"}}),
        )
        .unwrap();
        let e = hub.update_credential(&session.id, codex, false).await.unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "credentials.family");
        let e =
            hub.update_credential("no-such-session", credential(FIRST), false).await.unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "credentials.no_session");
    }
}
