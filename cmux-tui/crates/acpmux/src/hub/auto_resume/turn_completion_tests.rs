//! Concurrency regression for Stop racing a completed turn.
//!
//! `finish_turn` and `stop_auto_resume` must acquire the retry and append state in
//! one direction. The test deliberately holds the live-turn lock so the old
//! append -> auto-resume -> turn and auto-resume -> turn -> append cycle is
//! observable without timing assumptions.

use crate::config::{Config, StoreMode};
use crate::hub::{Control, Hub, NewRequest, TurnInfo};
use serde_json::json;
use std::path::Path;
use std::sync::{Arc, mpsc};
use std::time::Duration;

fn fake_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = serde_json::from_value::<Config>(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake"
    }))
    .expect("synthetic fake harness config");
    let mut cfg = cfg;
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// Force Stop to hold the retry lock before completion reaches take_turn. Both must
/// finish within the bounded receives; a deadlocked worker is never joined on failure.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stop_and_completion_share_one_lock_order() {
    let hub = fake_hub();
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .expect("create synthetic session");
    let child = hub.child_for(&session).await.expect("start synthetic child");
    let mut turn =
        TurnInfo::prompted("test", "work", "turn-lock-order", "prompt-lock-order", Control::Local);
    turn.turn_seq =
        hub.append(&session, "mux", "turn_started", json!({"turnId": turn.turn_id})).seq;
    *session.turn.lock().unwrap_or_else(|e| e.into_inner()) = Some(turn.clone());
    // Keep the live-turn lock held until both contenders have reached their lock boundary.
    let turn_guard = session.turn.lock().unwrap_or_else(|e| e.into_inner());

    // The stop thread takes auto_resume and then waits for the live-turn lock.
    let (stop_locked_tx, stop_locked_rx) = mpsc::channel();
    *session.auto_resume.stop_locked.lock().unwrap() = Some(stop_locked_tx);
    let (stop_done_tx, stop_done_rx) = mpsc::channel();
    let stop_hub = hub.clone();
    let stop_session = session.clone();
    let stop = std::thread::spawn(move || {
        stop_hub.stop_auto_resume(&stop_session);
        let _ = stop_done_tx.send(());
    });
    stop_locked_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("Stop did not enter auto_resume state");

    // Completion enters the real finish_turn path. On the old head it owns append_lock
    // before take_turn waits for auto_resume, completing the cycle above.
    let (take_entered_tx, take_entered_rx) = mpsc::channel();
    *session.auto_resume.take_entered.lock().unwrap() = Some(take_entered_tx);
    let complete_hub = hub.clone();
    let complete_session = session.clone();
    let complete_child = child.clone();
    let (completion_done_tx, completion_done_rx) = mpsc::channel();
    let completion = std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let result = runtime.block_on(async move {
            complete_hub
                .finish_turn(
                    &complete_session,
                    &complete_child,
                    Ok(json!({"stopReason":"end_turn"})),
                    &turn.prompt_id,
                    &turn.turn_id,
                    turn.turn_seq,
                    None,
                    None,
                )
                .await
        });
        let _ = completion_done_tx.send(result.is_ok());
        result
    });

    // The hook is before take_turn's retry-lock acquisition. If finish_turn still takes
    // append_lock first, Stop and completion are now on opposite sides of the cycle.
    take_entered_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("completion did not enter take_turn");
    drop(turn_guard);

    // A fixed order drains both operations promptly. The bounded receives make the old
    // append -> retry -> turn cycle a test failure instead of an unbounded harness hang.
    assert!(
        stop_done_rx.recv_timeout(Duration::from_secs(5)).is_ok(),
        "Stop/completion lock inversion left Stop blocked"
    );
    assert!(
        completion_done_rx.recv_timeout(Duration::from_secs(5)).is_ok_and(|ok| ok),
        "Stop/completion lock inversion left completion blocked"
    );
    stop.join().expect("Stop thread panicked");
    let finished = completion.join().expect("completion thread panicked");
    assert!(finished.is_ok(), "completion returned a synthetic error");
    assert!(session.turn().is_none(), "completion left a live turn");
    assert!(
        hub.stopped_for_test(&session, "turn-lock-order"),
        "completion lost Stop's retry fence"
    );
    let events = hub.events(&session.id, 0, 100).unwrap();
    let stopped = events.iter().position(|event| event.kind == "turn_stop_requested").unwrap();
    let finished = events.iter().position(|event| event.kind == "turn_result").unwrap();
    assert!(stopped < finished, "completion overtook Stop's durable boundary");
}
