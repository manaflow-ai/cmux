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
    pub(crate) fn recover_credential(
        &self,
        session: &Session,
        identity: Option<(u32, u64)>,
    ) -> bool {
        let Some((pid, start)) = identity else { return false };
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

    /// Move an existing Cloud chat off a delivered Claude token after its own account is ready.
    pub(crate) async fn retire_claude_credential(&self, session: &Session) {
        let _spawn = session.spawn_lock.lock().await;
        let mut held = session.credential.lock().unwrap_or_else(|e| e.into_inner());
        if held.as_ref().is_some_and(AgentCredential::has_legacy_claude_token) {
            *held = None;
        }
    }

    /// Sets `credential` on session `id` (its exact id, a session of this daemon) and restarts its
    /// live agent on it. A credential of another family than the session's harness is refused.
    pub(crate) async fn update_credential(
        self: &Arc<Self>,
        id: &str,
        mut credential: AgentCredential,
    ) -> Result<Value, RpcError> {
        let (session, family) = self.credential_session(id).await?;
        if Family::of_harness(&family) != Some(credential.family()) {
            return Err(RpcError::invalid_params(
                "this credential does not serve this chat's agent",
            )
            .with_data(json!({"reason": "credentials.family"})));
        }
        let connection = session.meta().credential_connection;
        credential.keep_connection(connection.as_deref());
        let changed = {
            let _spawn = session.spawn_lock.lock().await;
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
        let (session, _) = self.credential_session(id).await?;
        let meta = session.meta();
        let held = session.credential.lock().unwrap_or_else(|e| e.into_inner()).is_some();
        let model =
            meta.credential_model.clone().or_else(|| super::model_options::current_model(&meta));
        Ok(json!({"connection": meta.credential_connection, "held": held,
            "model": model, "harness": meta.harness}))
    }

    /// The Cloud owner withdrew a delivered model credential.
    pub(crate) async fn revoke_credential(self: &Arc<Self>, id: &str) -> Result<Value, RpcError> {
        let (session, _family) = self.credential_session(id).await?;
        let _spawn = session.spawn_lock.lock().await;
        let removed = session.credential.lock().unwrap_or_else(|e| e.into_inner()).take();
        if removed.is_none() && session.meta().credential_connection.is_none() {
            return Ok(json!({"sessionId": session.id, "restart": "none"}));
        }
        #[cfg(unix)]
        if Family::of_harness(&_family) == Some(Family::Copilot) {
            crate::agent::copilot_auth::remove_session(&session.id);
        }
        self.detach_child(&session).await;
        Ok(json!({"sessionId": session.id, "restart": "none"}))
    }

    async fn credential_session(&self, id: &str) -> Result<(Arc<Session>, String), RpcError> {
        let session =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned().ok_or_else(
                || {
                    RpcError::not_found("no such session on this machine")
                        .with_data(json!({"reason": "credentials.no_session"}))
                },
            )?;
        let meta = session.meta();
        let family = {
            let cfg = self.config.read().await;
            cfg.harnesses
                .get(&meta.harness)
                .map(|p| crate::config::derive_family(&meta.harness, p))
                .or_else(|| cfg.family(&meta.harness))
                .unwrap_or_else(|| meta.harness.clone())
        };
        Ok((session, family))
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
    async fn an_update_restarts_the_agent_on_the_new_credential_in_the_same_chat() {
        let hub = hub();
        let req = NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential(FIRST)),
            ..NewRequest::default()
        };
        let session = hub.new_session(req).await.unwrap();
        let before = hub.child_for(&session).await.unwrap().generation;
        let reply = hub.update_credential(&session.id, credential(SECOND)).await.unwrap();
        assert_eq!(reply["restart"], "now");
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

        hub.update_credential(&session.id, credential).await.unwrap();
        hub.child_for(&session).await.unwrap();
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
