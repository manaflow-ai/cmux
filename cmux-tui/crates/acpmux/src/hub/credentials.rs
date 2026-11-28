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
#[path = "credentials_tests.rs"]
mod tests;
