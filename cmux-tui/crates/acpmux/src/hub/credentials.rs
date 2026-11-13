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
    /// Why session's agent may not start or take a prompt now (`agent_credentials::blocked`):
    /// with `live`, an agent the daemon adopted still runs on the env it started with, so only an
    /// expired ChatGPT token stops it.
    pub(crate) fn credential_blocked(&self, session: &Session, live: bool) -> Option<RpcError> {
        let credential = session.credential.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let reference = session.meta().credential_ref;
        if live && credential.is_none() {
            return None;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        crate::agent_credentials::blocked(credential.as_ref(), reference.as_ref(), now)
    }

    /// `agent/credentials.list`: this daemon's sessions that run on an owner's credential, each
    /// with its connection, expiry and whether the daemon lost it (`lost`: the Mac sends it again).
    /// No value.
    pub(crate) fn credential_holders(&self) -> Value {
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        let holders: Vec<Value> = sessions
            .iter()
            .filter_map(|session| {
                let reference = session.meta().credential_ref?;
                let held = session.credential.lock().unwrap_or_else(|e| e.into_inner()).clone();
                let current = held.as_ref().map(AgentCredential::reference).unwrap_or(reference);
                Some(json!({
                    "sessionId": session.id,
                    "connection": current.connection,
                    "expires_at": current.expires_at,
                    "chatgpt": current.chatgpt,
                    "lost": held.is_none(),
                }))
            })
            .collect();
        json!({"holders": holders})
    }

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
        // The meta keeps what the chat runs on (no value), so a daemon restart knows it.
        let reference = credential.reference();
        let changed = {
            let mut held = session.credential.lock().unwrap_or_else(|e| e.into_inner());
            let changed = !held.as_ref().is_some_and(|h| h.same_secret(&credential));
            *held = Some(credential);
            changed
        };
        let kept = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let differs = m.credential_ref.as_ref() != Some(&reference);
            m.credential_ref = Some(reference);
            differs
        };
        if kept {
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

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_chat_whose_credential_the_daemon_lost_waits_for_the_mac_never_the_route() {
        let hub = hub();
        let launch = AgentCredential::parse(
            &json!({"env": {CLAUDE_OAUTH: FIRST}, "connection": "claude-token", "expires_at": null}),
        )
        .unwrap();
        let req = NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(launch),
            ..NewRequest::default()
        };
        let session = hub.new_session(req).await.unwrap();
        hub.child_for(&session).await.unwrap();
        assert_eq!(
            session.meta().credential_ref.and_then(|r| r.connection).as_deref(),
            Some("claude-token"),
            "the meta knows the chat runs on the owner's credential"
        );
        let holders = hub.credential_holders();
        assert_eq!(holders["holders"][0]["lost"], json!(false));
        // A daemon restart loses what was in memory; the meta stays.
        *session.credential.lock().unwrap() = None;
        assert!(hub.credential_blocked(&session, true).is_none(), "an adopted agent keeps its env");
        let refused = hub.credential_blocked(&session, false).expect("no start on another route");
        assert_eq!(refused.data.unwrap()["reason"], crate::agent_credentials::RECONNECT_REASON);
        let only = std::collections::BTreeSet::from([session.id.clone()]);
        let out = hub.restart_harnesses(None, Some(&only)).await;
        assert_eq!(out.failed.len(), 1, "the agent does not start without it");
        let holders = hub.credential_holders();
        assert_eq!(holders["holders"][0]["sessionId"], json!(session.id));
        assert_eq!(holders["holders"][0]["lost"], json!(true));
        assert!(!holders.to_string().contains(FIRST));
        // The owner's Mac sends it again: the chat goes on.
        hub.update_credential(&session.id, credential(SECOND)).await.unwrap();
        assert!(hub.credential_blocked(&session, false).is_none());
        hub.child_for(&session).await.unwrap();
        assert_eq!(launched(&session).get(CLAUDE_OAUTH).map(String::as_str), Some(SECOND));
        assert_eq!(hub.credential_holders()["holders"][0]["lost"], json!(false));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_prompt_to_a_chat_that_lost_its_credential_is_accepted_then_says_why() {
        let hub = hub();
        let launch = AgentCredential::parse(
            &json!({"env": {CLAUDE_OAUTH: FIRST}, "connection": "claude-token", "expires_at": null}),
        )
        .unwrap();
        let req = NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(launch),
            ..NewRequest::default()
        };
        let session = hub.new_session(req).await.unwrap();
        hub.child_for(&session).await.unwrap();
        *session.credential.lock().unwrap() = None;
        let only = std::collections::BTreeSet::from([session.id.clone()]);
        hub.restart_harnesses(None, Some(&only)).await;
        assert!(session.child.lock().await.is_none(), "no agent runs without it");
        // The prompt is accepted first (a page that relays it hears prompt_accepted at once, never
        // a timeout), then its turn fails with the reason the card words as "needs your Mac".
        let accepted = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let heard = accepted.clone();
        let opts = crate::hub::PromptOptions {
            on_accepted: Some(Box::new(move |_| {
                heard.store(true, std::sync::atomic::Ordering::SeqCst)
            })),
            ..crate::hub::PromptOptions::default()
        };
        let e = hub
            .prompt_with(
                &session,
                vec![json!({"type": "text", "text": "go on"})],
                "test",
                false,
                opts,
            )
            .await
            .unwrap_err();
        assert!(accepted.load(std::sync::atomic::Ordering::SeqCst), "accepted before it failed");
        assert_eq!(e.data.unwrap()["reason"], crate::agent_credentials::RECONNECT_REASON);
        assert!(session.child.lock().await.is_none(), "nothing started on the machine's own route");
        assert!(!written(&hub, &session.id).contains(FIRST));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_new_expiry_for_the_same_token_restarts_nothing() {
        let hub = hub();
        let with = |at: u64| {
            AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: FIRST}, "expires_at": at}))
                .unwrap()
        };
        let req = NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(with(100)),
            ..NewRequest::default()
        };
        let session = hub.new_session(req).await.unwrap();
        hub.child_for(&session).await.unwrap();
        let reply = hub.update_credential(&session.id, with(200)).await.unwrap();
        assert_eq!(reply["restart"], "none");
        assert_eq!(session.meta().credential_ref.and_then(|r| r.expires_at), Some(200));
    }
}
