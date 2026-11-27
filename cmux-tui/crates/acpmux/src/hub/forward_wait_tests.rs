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

/// Before: an agent alive that never answers `session/fork` held the fork (and the parent's
/// `harness_use` read lock) forever. After: an idle chat's fork fails within the start budget
/// with a named error, and the lock is free again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_fork_the_agent_never_answers_fails_within_its_bound() {
    let hub = hub_on(&["FAKE_FORK_SILENT=1"], 2_000);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(req).await.unwrap();
    hub.prompt(&parent, vec![json!({"type": "text", "text": "first"})], "test", false)
        .await
        .unwrap();
    let before = cmux_bounded::overrun_count(ForwardWait::NAME);
    let forked = tokio::time::timeout(
        Duration::from_secs(20),
        hub.fork(&parent, None, None, Default::default(), None, None, true),
    )
    .await
    .expect("a fork the agent never answers held its caller past its bound");
    let Err(err) = forked else {
        panic!("a fork with no answer succeeded");
    };
    assert!(err.message.contains("did not answer session/fork within 2 s"), "{err:?}");
    assert!(cmux_bounded::overrun_count(ForwardWait::NAME) > before);
    assert!(parent.harness_use.try_write().is_ok(), "harness_use stayed held");
}
