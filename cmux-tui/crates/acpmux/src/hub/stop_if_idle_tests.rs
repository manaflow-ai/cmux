//! `session stop --if-idle [--expect-revision REV]` (`stop_if_idle.rs`): a turn admitted just
//! before the stop is refused and runs on, a stale revision is refused, an idle session at the
//! expected revision stops, and a stop without `--if-idle` stops as before.

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub with one open chat on the stand-in agent.
async fn chat() -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

fn prompt(
    hub: &Arc<Hub>,
    s: &Arc<Session>,
    text: &str,
) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let (hub, s) = (hub.clone(), s.clone());
    let blocks = vec![json!({"type": "text", "text": text})];
    tokio::spawn(async move { hub.prompt(&s, blocks, "test", false).await })
}

fn reason(e: &RpcError) -> (Value, Value) {
    let data = e.data.clone().unwrap_or_default();
    (data["reason"].clone(), data["busyWith"].clone())
}

fn closed(s: &Session) -> bool {
    s.status() == SessionStatus::Closed
}

/// A prompt that took the turn lock (admitted) but has no turn showing yet: the conditional stop
/// is refused as busy, and the prompt's turn runs to its end on a session that stays open.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_turn_admitted_just_before_the_stop_is_refused_and_runs_on() {
    let (hub, s) = chat().await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let run = prompt(&hub, &s, "admitted before the stop");
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    assert!(s.turn().is_none(), "the stop must come before the turn is installed");
    let before = Hub::revision(&s);
    let e = hub
        .stop(&s, false, StopCondition { if_idle: true, expect_revision: Some(before) })
        .await
        .expect_err("an admitted prompt's session was stopped");
    assert_eq!(e.code, NOT_IDLE_CODE, "{e:?}");
    assert_eq!(reason(&e), (json!(BUSY), json!("turn")), "{e:?}");
    assert_eq!(e.data.as_ref().unwrap()["revision"], json!(before), "{e:?}");
    assert!(!closed(&s), "a refused stop closed the session");
    release.send(()).unwrap();
    let answer = tokio::time::timeout(WAIT, run).await.unwrap().unwrap().unwrap();
    assert_eq!(answer["stopReason"], "end_turn", "the admitted turn was cut: {answer}");
    // Once the turn ended the session is idle, and a stop at its new revision closes it.
    let now = Hub::revision(&s);
    assert!(now > before, "the turn moved no revision ({before} -> {now})");
    hub.stop(&s, false, StopCondition { if_idle: true, expect_revision: Some(now) }).await.unwrap();
    assert!(closed(&s));
}

/// A running turn makes the conditional stop refuse too, and is not cancelled by it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_running_turn_is_refused_as_busy() {
    let (hub, s) = chat().await;
    let run = prompt(&hub, &s, "slow");
    let opened = async {
        while s.turn().is_none() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    };
    tokio::time::timeout(WAIT, opened).await.expect("the turn opens");
    let e = hub
        .stop(&s, false, StopCondition { if_idle: true, expect_revision: None })
        .await
        .expect_err("a running turn's session was stopped");
    assert_eq!(reason(&e), (json!(BUSY), json!("turn")), "{e:?}");
    let answer = tokio::time::timeout(WAIT, run).await.unwrap().unwrap().unwrap();
    assert_eq!(answer["stopReason"], "end_turn", "the running turn was cut: {answer}");
    assert!(!closed(&s));
}

/// A revision read before a turn ran is stale: the stop is refused as `revision_moved` with the
/// current revision, and the session stays open.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stale_revision_is_refused() {
    let (hub, s) = chat().await;
    let read = Hub::revision(&s);
    let answer = tokio::time::timeout(WAIT, prompt(&hub, &s, "hello")).await.unwrap().unwrap();
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    let now = Hub::revision(&s);
    assert!(now > read);
    let e = hub
        .stop(&s, false, StopCondition { if_idle: true, expect_revision: Some(read) })
        .await
        .expect_err("a stale revision stopped the session");
    assert_eq!(e.code, NOT_IDLE_CODE, "{e:?}");
    assert_eq!(reason(&e), (json!(REVISION_MOVED), Value::Null), "{e:?}");
    assert_eq!(e.data.as_ref().unwrap()["revision"], json!(now), "{e:?}");
    assert!(!closed(&s), "a refused stop closed the session");
}

/// An idle session at the expected revision stops, with or without a revision to check.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_idle_session_at_the_expected_revision_stops() {
    let (hub, s) = chat().await;
    let answer = tokio::time::timeout(WAIT, prompt(&hub, &s, "hello")).await.unwrap().unwrap();
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    let rev = Hub::revision(&s);
    hub.stop(&s, false, StopCondition { if_idle: true, expect_revision: Some(rev) }).await.unwrap();
    assert!(closed(&s));
    assert!(s.child.lock().await.is_none(), "the agent outlived the stop");

    let (hub, s) = chat().await;
    hub.stop(&s, false, StopCondition { if_idle: true, expect_revision: None }).await.unwrap();
    assert!(closed(&s));
}

/// Without `ifIdle` the stop is the plain one: it ends a running turn, as before.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_without_if_idle_stops_a_busy_session_as_before() {
    let (hub, s) = chat().await;
    let run = prompt(&hub, &s, "until-cancel");
    let opened = async {
        while s.turn().is_none() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    };
    tokio::time::timeout(WAIT, opened).await.expect("the turn opens");
    hub.stop(&s, false, StopCondition::default()).await.unwrap();
    assert!(closed(&s));
    let _ = tokio::time::timeout(WAIT, run).await.expect("the stopped turn answers");
}

/// Work the daemon sees outside a turn of its own makes the session busy too: a turn the harness
/// started itself, a background process its harness runs, and a Claude conversation with turns
/// but none stored. Each is refused and the session stays open; once it is gone the stop runs.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn work_outside_an_acpmux_turn_is_refused_as_busy() {
    let if_idle = StopCondition { if_idle: true, expect_revision: None };
    let refused = |e: RpcError| reason(&e).1;

    let (hub, s) = chat().await;
    // Claude Code's own turn, from its `system/init` to its `result` (`tap.rs`).
    s.harness_turn.store(true, Ordering::SeqCst);
    let e = hub.stop(&s, false, if_idle).await.expect_err("a harness turn's session was stopped");
    assert_eq!(refused(e), json!("turn"));
    assert!(!closed(&s));
    s.harness_turn.store(false, Ordering::SeqCst);

    // A shell the harness runs in the background (`processes.rs`).
    let update = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "own", "update": {"sessionUpdate": "background_task_update", "toolCallId": "bg", "taskId": "bg", "state": "running", "command": "serve"}}});
    let rec = hub.append(&s, "in", "background_task_update", update);
    hub.note_process(&s, &rec, None);
    assert!(hub.any_process_running(&s), "the stand-in process does not run");
    let e = hub.stop(&s, false, if_idle).await.expect_err("a running process was ended");
    assert_eq!(refused(e), json!("process"));
    assert!(!closed(&s));

    let (hub, s) = chat().await;
    {
        let mut m = s.meta.lock().unwrap();
        m.claude_unstored = true;
        m.turn_count = 1;
    }
    let e = hub.stop(&s, false, if_idle).await.expect_err("an unstored conversation was stopped");
    assert_eq!(refused(e), json!("unstored"));
    assert!(!closed(&s));
    s.meta.lock().unwrap().claude_unstored = false;
    hub.stop(&s, false, if_idle).await.unwrap();
    assert!(closed(&s));
}

#[test]
fn the_condition_reads_from_the_request() {
    let read = |v: Value| StopCondition::from_params(&v);
    assert_eq!(read(json!({"sessionId": "s"})).unwrap(), StopCondition::default());
    assert_eq!(
        read(json!({"ifIdle": true, "expectRevision": 7})).unwrap(),
        StopCondition { if_idle: true, expect_revision: Some(7) }
    );
    assert_eq!(
        read(json!({"ifIdle": true})).unwrap(),
        StopCondition { if_idle: true, expect_revision: None }
    );
    assert!(read(json!({"expectRevision": 7})).is_err(), "a revision without ifIdle");
    assert!(read(json!({"ifIdle": true, "expectRevision": -1})).is_err());
    assert!(read(json!({"ifIdle": "yes"})).is_err());
    assert!(StopCondition::asked(&json!({"ifIdle": true})));
    assert!(StopCondition::asked(&json!({"expectRevision": 3})));
    assert!(!StopCondition::asked(&json!({"ifIdle": false, "purge": true})));
    assert!(!StopCondition::asked(&json!({"ifIdle": null, "expectRevision": null})));
    // A malformed condition is never forwarded to a peer as a plain stop.
    assert!(StopCondition::asked(&json!({"ifIdle": "yes"})));
    assert!(StopCondition::asked(&json!({"ifIdle": 1})));
    assert!(StopCondition::asked(&json!({"expectRevision": "7"})));
}
