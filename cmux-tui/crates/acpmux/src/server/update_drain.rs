//! Updates fence new waiting sends before shutdown, and defer if accepted sends cannot finish.
//! Durable inbox submissions remain admissible while the next daemon is being prepared.
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::Notify;

use crate::no_panic::LockExt;
use crate::rpc::RpcError;

// timeout: an unfinished turn defers the update; it never authorizes cutting that turn.
pub(crate) const WITHIN: Duration = Duration::from_secs(30);

#[derive(Default)]
struct State {
    active: usize,
    drainers: usize,
    committed: bool,
    owner: Option<String>,
}

#[derive(Default)]
pub(crate) struct Admission {
    state: Mutex<State>,
    changed: Notify,
}

pub(crate) struct SendPermit(Arc<Admission>);

impl Drop for SendPermit {
    fn drop(&mut self) {
        self.0.state.lock_or_recover().active -= 1;
        self.0.changed.notify_waiters();
    }
}

pub(crate) struct Drain(Arc<Admission>);

impl Drain {
    /// Only this owner's detached successor may join its already-fenced handoff.
    pub(crate) fn owner(&self) -> String {
        self.0.state.lock_or_recover().owner.clone().expect("drain owns update")
    }

    pub(crate) fn commit(self) {
        self.0.state.lock_or_recover().committed = true;
    }
}

impl Drop for Drain {
    fn drop(&mut self) {
        let mut state = self.0.state.lock_or_recover();
        state.drainers -= 1;
        if state.drainers == 0 {
            state.owner = None;
        }
        drop(state);
        self.0.changed.notify_waiters();
    }
}

impl Admission {
    pub(crate) fn admit(self: &Arc<Self>) -> Result<SendPermit, RpcError> {
        let mut state = self.state.lock_or_recover();
        if state.drainers > 0 || state.committed {
            return Err(super::shutdown_drain::restarting_error());
        }
        state.active += 1;
        Ok(SendPermit(self.clone()))
    }

    #[cfg(test)]
    async fn drain(self: &Arc<Self>, within: Duration) -> Result<Drain, RpcError> {
        self.drain_owned(within, None).await
    }

    async fn drain_owned(
        self: &Arc<Self>,
        within: Duration,
        owner: Option<&str>,
    ) -> Result<Drain, RpcError> {
        {
            let mut state = self.state.lock_or_recover();
            // A matching token joins one handoff; independent callers never become another
            // restart owner, including after the first owner committed and dropped its guard.
            if state.committed || (state.drainers > 0 && owner != state.owner.as_deref()) {
                return Err(RpcError::new(
                    -32000,
                    "daemon update deferred: another updater owns the handoff",
                )
                .with_data(serde_json::json!({"reason":"update.deferred", "retryable":true})));
            }
            if state.drainers == 0 {
                state.owner = Some(uuid::Uuid::now_v7().to_string());
            }
            state.drainers += 1;
        }
        let guard = Drain(self.clone());
        let ready = async {
            loop {
                let changed = self.changed.notified();
                tokio::pin!(changed);
                changed.as_mut().enable();
                if self.state.lock_or_recover().active == 0 {
                    return;
                }
                changed.await;
            }
        };
        if tokio::time::timeout(within, ready).await.is_err() {
            return Err(deferred());
        }
        Ok(guard)
    }
}

pub(crate) fn deferred() -> RpcError {
    RpcError::new(
        -32000,
        "daemon update deferred: accepted sends are still finishing; the daemon is still serving",
    )
    .with_data(serde_json::json!({"reason": "update.deferred", "retryable": true}))
}

/// Before handing listeners away or asking a supervisor to stop. The guard reopens admission
/// on every failure/cancellation; commit it only once shutdown has actually been requested.
pub(crate) async fn prepare(hub: &crate::hub::Hub) -> Result<Drain, RpcError> {
    prepare_owned(hub, None).await
}

pub(crate) async fn prepare_owned(
    hub: &crate::hub::Hub,
    owner: Option<&str>,
) -> Result<Drain, RpcError> {
    let until = tokio::time::Instant::now() + WITHIN;
    let guard = hub.update_admission.drain_owned(WITHIN, owner).await?;
    if !super::shutdown_drain::flush_before_update(hub, until).await {
        return Err(deferred());
    }
    Ok(guard)
}

/// A `steered` acknowledgement ends the prompt RPC before the original turn ends. The
/// waiting CLI then alternates info reads and bounded wait RPCs; neither those gaps nor a
/// completed acknowledgement release the accepted send's drain permit.
pub(super) fn steered_end(
    session: Option<&str>,
    answer: Option<&serde_json::Value>,
) -> Option<serde_json::Value> {
    let answer = answer?;
    if answer.get("stopReason")?.as_str()? != "steered" {
        return None;
    }
    let turn = answer.pointer("/_meta/acpmux/turnId")?.as_str().filter(|s| !s.is_empty())?;
    Some(serde_json::json!({
        "sessions": [session?],
        "until": ["closed"],
        "turnEnded": {"turnId": turn},
    }))
}

pub(super) async fn hold_steered_end(
    hub: &Arc<crate::hub::Hub>,
    conn: &super::Conn,
    params: Option<serde_json::Value>,
) {
    let Some(params) = params else { return };
    tokio::select! {
        _ = super::wait::wait(hub, &params, None) => {},
        () = conn.closed() => {},
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn only_one_updater_owns_a_handoff_and_its_successor_can_join() {
        let gate = Arc::new(Admission::default());
        let held = gate.admit().unwrap();
        let first = gate.drain(Duration::from_secs(1));
        tokio::pin!(first);
        tokio::select! {
            biased;
            _ = &mut first => panic!("held send has not drained"),
            () = tokio::task::yield_now() => {},
        }
        // Concurrent machine update/watcher cannot both pass the fence and restart the unit.
        assert!(gate.drain(Duration::from_secs(1)).await.is_err());
        drop(held);
        let first = first.await.unwrap();
        let owner = first.owner();
        assert!(gate.drain(Duration::from_secs(1)).await.is_err());
        assert!(gate.drain_owned(Duration::from_secs(1), Some("another-owner")).await.is_err());
        let successor = gate.drain_owned(Duration::from_secs(1), Some(&owner)).await.unwrap();
        drop(first);
        assert!(gate.admit().is_err(), "successor still owns the admission fence");
        successor.commit();
        assert!(
            gate.drain(Duration::from_secs(1)).await.is_err(),
            "committed owner cannot restart twice"
        );
        assert!(gate.admit().is_err());

        let retry = Arc::new(Admission::default());
        let failed = retry.drain(Duration::from_secs(1)).await.unwrap();
        drop(failed);
        assert!(
            retry.drain(Duration::from_secs(1)).await.is_ok(),
            "failed handoff releases ownership"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn update_drain_defers_without_losing_accepted_sends() {
        let gate = Arc::new(Admission::default());
        let accepted: Vec<_> = (0..20).map(|_| gate.admit().unwrap()).collect();
        for _ in 0..5 {
            let drain = gate.drain(Duration::from_secs(1));
            tokio::pin!(drain);
            tokio::select! {
                biased;
                _ = &mut drain => panic!("active sends must defer the update"),
                () = tokio::task::yield_now() => {}
            }
            assert!(gate.admit().is_err());
            assert!(drain.await.is_err());
            assert_eq!(gate.state.lock_or_recover().active, 20);
            assert!(gate.admit().is_ok(), "a deferred update reopens admission");
        }
        drop(accepted);
        gate.drain(Duration::from_secs(1)).await.unwrap().commit();
        assert!(gate.admit().is_err());
    }

    #[tokio::test]
    async fn update_drain_finishes_only_after_last_send_and_reopens_on_cancel() {
        let gate = Arc::new(Admission::default());
        let send = gate.admit().unwrap();
        let drain = gate.drain(Duration::from_secs(1));
        tokio::pin!(drain);
        tokio::select! {
            biased;
            _ = &mut drain => panic!("send still owns its response"),
            () = tokio::task::yield_now() => {}
        }
        assert!(gate.admit().is_err());
        drop(send);
        let guard = drain.await.unwrap();
        assert!(gate.admit().is_err());
        drop(guard);
        assert!(gate.admit().is_ok());
    }

    /// Exercise the real prompt RPC: its steered acknowledgement is already delivered while
    /// its original turn and the caller's subsequent wait are still running.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn accepted_steered_sends_hold_drain_through_five_update_attempts() {
        use crate::config::{Config, StoreMode};
        use crate::hub::{Hub, NewRequest, PromptOptions};
        use crate::rpc::{Message, method};
        use crate::server::cancel_prompt_tests::Client;
        use serde_json::json;
        const WAIT: Duration = Duration::from_secs(20);
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {
                "argv": ["/usr/bin/env", "FAKE_CLAUDE_STEER=1", "python3", fake],
                "env": {"ACPMUX_SESSION_CPU_CLASS": "normal"},
            }},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let session = hub
            .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
            .await
            .unwrap();
        let (tx, accepted) = tokio::sync::oneshot::channel();
        let opts = PromptOptions {
            prompt_id: Some("drain-original".to_owned()),
            on_accepted: Some(Box::new(move |v| {
                let _ = tx.send(v);
            })),
            ..PromptOptions::default()
        };
        let original = {
            let (hub, session) = (hub.clone(), session.clone());
            tokio::spawn(async move {
                hub.prompt_with(
                    &session,
                    vec![json!({"type":"text", "text":"until-cancel"})],
                    "test",
                    false,
                    opts,
                )
                .await
            })
        };
        tokio::time::timeout(WAIT, accepted).await.unwrap().unwrap();
        let mut client = Client::connect(&hub);
        for id in 1..=20 {
            client
                .send(Message::request(
                    id,
                    method::SESSION_PROMPT,
                    json!({
                        "sessionId": session.id,
                        "prompt": [{"type":"text", "text":format!("steer {id}")}],
                        "_meta": {"acpmux": {"steer":true, "promptId":format!("drain-steer-{id}")}},
                    }),
                ))
                .await;
        }
        for id in 1..=20 {
            let answer = client.answer(id, WAIT).await.expect("steer acknowledged");
            assert_eq!(answer["result"]["stopReason"], "steered", "{answer}");
        }
        let turn = session.turn().expect("original turn still runs");
        assert_eq!(hub.update_admission.state.lock_or_recover().active, 20);
        for attempt in 0..5 {
            // Already acknowledged sends remain protected between each CLI wait RPC.
            let info = client
                .call(100 + attempt * 2, method::MUX_INFO, json!({"sessionId":session.id}))
                .await;
            assert!(info.get("result").is_some(), "connection stays usable: {info}");
            let answer = client
                .call(
                    101 + attempt * 2,
                    method::MUX_WAIT,
                    json!({
                        "sessions":[session.id], "until":["closed"],
                        "turnEnded":{"turnId":turn.turn_id}, "timeoutMs":1,
                    }),
                )
                .await;
            assert!(answer.get("result").is_some(), "wait answers: {answer}");
            assert!(hub.update_admission.drain(Duration::from_millis(1)).await.is_err());
            assert_eq!(hub.update_admission.state.lock_or_recover().active, 20);
        }
        hub.cancel(&session).await.unwrap();
        tokio::time::timeout(WAIT, original).await.unwrap().unwrap().unwrap();
        let drained = hub.update_admission.drain(WAIT).await.expect("turn end releases all sends");
        let records = hub.events(&session.id, 0, 100_000).unwrap();
        for id in 1..=20 {
            let prompt_id = format!("drain-steer-{id}");
            assert_eq!(
                records
                    .iter()
                    .filter(|r| r.kind == "user_message"
                        && r.msg["promptId"] == prompt_id
                        && r.msg["steer"] == true)
                    .count(),
                1
            );
        }
        drop(drained);
        drop(client);
        hub.shutdown_all().await;
        hub.close_owned_tasks().await;
    }
}
