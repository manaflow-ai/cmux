//! A session request the daemon forwards to a live agent (`Hub::forward_as`: `session/set_mode`,
//! `session/set_config_option`, `session/set_model`) as a `cmux_bounded` machine. Its one waiting
//! state declares its bound and what ends it, so an agent that stays alive and never answers ends
//! the request with a named error instead of holding its caller, and the session's
//! `harness_use` read lock (which a fork's cancel writes), forever.
//!
//! The bound is the agent's start budget (`agentStartTimeoutMs`, 90 s by default): an agent that
//! has not answered a settings switch in the time it is given to start is not going to.

use cmux_bounded::{BoundedMachine, Wait};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Phase {
    /// Written to the agent; its answer has not come.
    Asked { bound: Duration },
    /// The agent answered (a result or an error).
    Answered,
    /// The bound passed with no answer: the caller gets [`no_answer`].
    GaveUp,
}

#[derive(Debug)]
pub(crate) enum Event {
    Answered,
    GaveUp,
}

#[derive(Debug)]
pub(crate) struct ForwardWait(Phase);

impl ForwardWait {
    pub(crate) fn asked(bound: Duration) -> Self {
        Self(Phase::Asked { bound })
    }
}

impl BoundedMachine for ForwardWait {
    type State = Phase;
    type Event = Event;
    const NAME: &'static str = "acpmux.forward";

    fn wait(state: &Phase) -> Wait<Event> {
        match state {
            Phase::Asked { bound } => {
                Wait::bounded(*bound, Event::GaveUp, "the agent answers a session settings request")
            }
            Phase::Answered | Phase::GaveUp => Wait::Settled,
        }
    }

    fn step(&mut self, event: Event) {
        self.0 = match (&self.0, event) {
            (Phase::Asked { .. }, Event::Answered) => Phase::Answered,
            (Phase::Asked { .. }, Event::GaveUp) => Phase::GaveUp,
            (done @ (Phase::Answered | Phase::GaveUp), _) => done.clone(),
        };
    }

    fn state(&self) -> &Phase {
        &self.0
    }
}

/// The error a request the agent never answered ends with.
pub(crate) fn no_answer(m: &str, bound: Duration) -> crate::rpc::RpcError {
    crate::rpc::RpcError::internal(format!(
        "the agent did not answer {m} within {} s (agentStartTimeoutMs); the request was cancelled",
        bound.as_secs()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::{Hub, NewRequest};
    use crate::rpc::method;
    use serde_json::json;
    use std::sync::Arc;

    #[test]
    fn every_forward_wait_recovers() {
        let bound = Duration::from_secs(90);
        let walks = cmux_bounded::testing::assert_every_wait_recovers::<ForwardWait>(
            |s: &Phase| ForwardWait(s.clone()),
            &[Phase::Asked { bound }, Phase::Answered, Phase::GaveUp],
            Duration::from_secs(91),
        );
        assert_eq!(walks.len(), 1, "Asked is the one waiting state");
    }

    fn hub_on(env: &[&str], start_timeout_ms: u64) -> Arc<Hub> {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut argv = vec!["/usr/bin/env"];
        argv.extend(env);
        argv.extend(["python3", fake]);
        let mut cfg: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": argv}},
            "defaultHarness": "fake",
            "agentStartTimeoutMs": start_timeout_ms,
        }))
        .unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    }

    /// Before: an agent alive that never answers `session/set_mode` held `forward_as` (and the
    /// session's `harness_use` read lock) forever. After: it fails within the start budget with a
    /// named error, the overrun is counted, and the lock is free again.
    #[tokio::test]
    async fn a_mode_switch_the_agent_never_answers_fails_within_its_bound() {
        let hub = hub_on(&["FAKE_SET_MODE_SILENT=1"], 2_000);
        let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let session = hub.new_session(req).await.unwrap();
        let before = cmux_bounded::overrun_count(ForwardWait::NAME);
        let switched = tokio::time::timeout(
            Duration::from_secs(20),
            hub.forward_as(&session, method::SESSION_SET_MODE, json!({"modeId": "plan"}), false),
        )
        .await
        .expect("a mode switch the agent never answers held its caller past its bound");
        let err = switched.expect_err("a switch with no answer succeeded");
        assert!(err.message.contains("did not answer session/set_mode within 2 s"), "{err:?}");
        assert!(cmux_bounded::overrun_count(ForwardWait::NAME) > before);
        assert!(session.harness_use.try_write().is_ok(), "harness_use stayed held");
    }
}
