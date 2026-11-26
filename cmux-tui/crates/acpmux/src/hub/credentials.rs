//! Part of `Hub`; see `hub/mod.rs`. `agent/credentials.update {sessionId, env}`: the owner's Mac
//! replaces the Cloud credential of one of this daemon's own sessions (`agent_credentials.rs`), a
//! refreshed ChatGPT access token about ten minutes before the last one expires. Its agent then
//! restarts on the new credential and resumes the same conversation (Codex `thread/resume`, Claude
//! `--resume`), after the idle gates and process census find it quiet. A refresh never cuts work; the next
//! prompt after hibernation starts with the new credential.
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

    /// Refuses `credential` for a chat of `harness` when its variable serves another family.
    pub(crate) async fn credential_serves(
        &self,
        harness: &str,
        credential: &AgentCredential,
    ) -> Result<(), RpcError> {
        let family = {
            let cfg = self.config.read().await;
            cfg.harnesses
                .get(harness)
                .map(|p| crate::config::derive_family(harness, p))
                .or_else(|| cfg.family(harness))
                .unwrap_or_else(|| harness.to_owned())
        };
        if Family::of_harness(&family) != Some(credential.family()) {
            return Err(RpcError::invalid_params(
                "this credential does not serve this chat's agent",
            )
            .with_data(json!({"reason": "credentials.family"})));
        }
        Ok(())
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
        self.credential_serves(&session.meta().harness, &credential).await?;
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
        self.respawn_when_quiet(&session);
        Ok(json!({"sessionId": session.id, "restart": "whenQuiet"}))
    }
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
    use crate::agent_credentials::{AgentCredential, CLAUDE_OAUTH};
    use crate::config::{Config, StoreMode};
    use crate::hub::{Hub, NewRequest};
    use serde_json::json;
    use std::path::Path;
    use std::sync::Arc;

    const FIRST: &str = "sk-ant-oat01-first-token-value";
    const SECOND: &str = "sk-ant-oat01-second-token-value";

    fn hub() -> Arc<Hub> {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg = serde_json::from_value::<Config>(json!({
            "harnesses": {"claude-fake": {"argv": ["python3", fake], "family": "claude"}},
            "defaultHarness": "claude-fake"
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        cfg.profile_sources = crate::config::ProfileSources::none();
        let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
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
    async fn automatic_restart_refresh_keeps_work_then_uses_the_new_credential() {
        let hub = hub();
        let req = NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential(FIRST)),
            ..NewRequest::default()
        };
        let session = hub.new_session(req).await.unwrap();
        let before = hub.child_for(&session).await.unwrap().generation;
        *session.work_below_since.lock().unwrap() = 1;
        let reply = hub.update_credential(&session.id, credential(SECOND)).await.unwrap();
        assert_eq!(reply["restart"], "whenQuiet");
        assert_eq!(hub.child_for(&session).await.unwrap().generation, before);
        assert!(session.respawn_when_quiet.load(std::sync::atomic::Ordering::SeqCst));
        assert!(!hub.idle_eligible(&session), "background work holds the refresh");
        *session.work_below_since.lock().unwrap() = 0;
        // Exercise the shared quiet exit without waiting thirty wall-clock seconds.
        assert!(hub.end_quiet_stale(&session, "credential-test", false).await);
        let after = hub.child_for(&session).await.unwrap().generation;
        assert_ne!(before, after, "a new agent process");
        assert_eq!(launched(&session).get(CLAUDE_OAUTH).map(String::as_str), Some(SECOND));
        assert_eq!(hub.resolve(&session.id).unwrap().id, session.id, "the same chat");
        let text = format!("{reply}{}", written(&hub, &session.id));
        assert!(!text.contains(FIRST) && !text.contains(SECOND));
        // The same credential again restarts nothing.
        let again = hub.update_credential(&session.id, credential(SECOND)).await.unwrap();
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
        // What a new daemon has of the session: no credential.
        *session.credential.lock().unwrap() = None;
        assert!(hub.recover_credential(&session, Some(pid)));
        assert_eq!(*session.credential.lock().unwrap(), Some(credential(FIRST)));
        // One the Mac sent since stays.
        *session.credential.lock().unwrap() = Some(credential(SECOND));
        assert!(!hub.recover_credential(&session, Some(pid)));
        assert_eq!(*session.credential.lock().unwrap(), Some(credential(SECOND)));
        // The next start runs on the held credential.
        *session.credential.lock().unwrap() = None;
        assert!(hub.recover_credential(&session, Some(pid)));
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
        assert!(!hub.recover_credential(&session, Some(pid)));
        assert!(session.credential.lock().unwrap().is_none());
        assert!(!hub.recover_credential(&session, None));
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
        let e = hub.update_credential(&session.id, codex).await.unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "credentials.family");
        let e = hub.update_credential("no-such-session", credential(FIRST)).await.unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "credentials.no_session");
    }
}
