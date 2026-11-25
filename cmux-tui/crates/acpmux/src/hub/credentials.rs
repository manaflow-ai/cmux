//! Part of `Hub`; see `hub/mod.rs`. `agent/credentials.update {sessionId, env}`: the owner's Mac
//! replaces the Cloud credential of one of this daemon's own sessions (`agent_credentials.rs`), a
//! refreshed ChatGPT access token about ten minutes before the last one expires. Its agent then
//! restarts on the new credential and resumes the same conversation (Codex `thread/resume`, Claude
//! `--resume`), as a route switch does (`route_switch.rs` `restart_harnesses`): between turns now,
//! in a turn when the turn ends, never cancelled.
//!
//! Nothing of it is recorded: no log record, meta field or event names the change, and the reply
//! carries no value.

use super::*;

use crate::agent_credentials::{AgentCredential, Family};

impl Hub {
    /// After a daemon restart, the credential the adopted agent `harness_pid` of `session` was
    /// launched on (`agent_credentials::recovered`), held again for its next start. A credential
    /// already held (one the Mac sent since) stays. Its family was checked when it was applied, and
    /// is again at the next spawn (`agent_credentials::apply`). Names only are logged. Whether one
    /// was taken.
    pub(crate) fn recover_credential(&self, session: &Session, harness_pid: Option<u32>) -> bool {
        let Some(pid) = harness_pid else { return false };
        let mut held = session.credential.lock().unwrap_or_else(|e| e.into_inner());
        if held.is_some() {
            return false;
        }
        let Some(credential) = crate::agent_credentials::recovered_from_pid(pid) else {
            return false;
        };
        let names: Vec<&str> = credential.names().collect();
        tracing::info!(session = %session.id, ?names, "the adopted agent's launch credential is held again");
        *held = Some(credential);
        true
    }

    /// After a daemon restart, the launch credential the adopted agent's host says it started the
    /// agent with (`agent_credentials::launched_with`), held again for its next start. A credential
    /// already held stays. Names only are logged. Whether one was taken.
    pub(crate) fn hold_launch_credential(
        &self,
        session: &Session,
        env: &[(String, String)],
    ) -> bool {
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
            && session.credential.lock().unwrap_or_else(|e| e.into_inner()).is_some()
    }

    /// Sets `credential` on session `id` (its exact id, a session of this daemon) and restarts its
    /// live agent on it. A credential of another family than the session's harness is refused.
    pub(crate) async fn update_credential(
        self: &Arc<Self>,
        id: &str,
        credential: AgentCredential,
    ) -> Result<Value, RpcError> {
        let session = self.session_get(id).ok_or_else(|| {
            RpcError::not_found("no such session on this machine")
                .with_data(json!({"reason": "credentials.no_session"}))
        })?;
        let meta = session.meta();
        let family = {
            let cfg = self.config.read().await;
            cfg.harnesses
                .get(&meta.harness)
                .map(|p| crate::config::derive_family(&meta.harness, p))
                .or_else(|| cfg.family(&meta.harness))
                .unwrap_or_else(|| meta.harness.clone())
        };
        if Family::of_harness(&family) != Some(credential.family()) {
            return Err(RpcError::invalid_params(
                "this credential does not serve this chat's agent",
            )
            .with_data(json!({"reason": "credentials.family"})));
        }
        let changed = {
            let mut held = session.credential.lock().unwrap_or_else(|e| e.into_inner());
            let changed = held.as_ref() != Some(&credential);
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
}

#[cfg(test)]
#[path = "credentials_tests.rs"]
mod tests;
