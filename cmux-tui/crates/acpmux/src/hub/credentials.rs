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
    /// Sets `credential` on session `id` (its exact id, a session of this daemon) and restarts its
    /// live agent on it. A credential of another family than the session's harness is refused.
    pub(crate) async fn update_credential(
        self: &Arc<Self>,
        id: &str,
        credential: AgentCredential,
    ) -> Result<Value, RpcError> {
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
        // A start waiting for it goes on now (`owner_credential_ready`).
        session.credential_set.notify_waiters();
        if !meta.owner_credential {
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
