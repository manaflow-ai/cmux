//! The source's side of a parked circuit (`hub/transfer_park.rs`): a body reaches a waiter or
//! falls back to the hub, and a hand-off with no answer is never retried over the hub.

use super::*;
use crate::config::{Config, StoreMode};
use std::time::Duration;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PEER: &str = "peer-daemon";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A prepare going to `PEER`, and the `await_move` params for its stage.
fn prepared() -> (Value, std::path::PathBuf) {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let prepare_id = format!("pre-parktest{}x{n}", std::process::id());
    let dir = transfers_dir().join(&prepare_id);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(TO_HUB), PEER).unwrap();
    let stage_id = format!("st{}", &prepare_id[4..]);
    (json!({"transferId": prepare_id, "stageId": stage_id}), dir)
}

#[tokio::test]
async fn only_the_prepares_target_parks() {
    let hub = hub();
    let (params, dir) = prepared();
    assert!(hub.park_move("someone-else", &params).is_err());
    assert!(hub.park_move("", &params).is_err());
    let parking = hub.park_move(PEER, &params).unwrap();
    assert!(hub.has_parked_move(&parking.stage_id));
    hub.unpark_move(&parking.stage_id, parking.id);
    assert!(!hub.has_parked_move(&parking.stage_id));
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn a_circuit_closed_before_the_hand_off_leaves_the_move_to_the_hub() {
    let hub = hub();
    let (params, dir) = prepared();
    let body = json!({"transferId": "t-1"});
    let wait = Duration::from_secs(5);

    // Unparked and closed (`await_move`'s timeout or close path).
    let parking = hub.park_move(PEER, &params).unwrap();
    let stage = parking.stage_id.clone();
    hub.unpark_move(&stage, parking.id);
    drop(parking);
    assert!(hub.move_over_circuit(PEER, &stage, body.clone(), wait).await.is_none());

    // Closed while still registered: the send fails and the body comes back.
    let parking = hub.park_move(PEER, &params).unwrap();
    drop(parking.hand);
    assert!(hub.move_over_circuit(PEER, &stage, body.clone(), wait).await.is_none());

    // Handed over, then given back unsent (a close racing the hand-off).
    let mut parking = hub.park_move(PEER, &params).unwrap();
    let waiter = tokio::spawn(async move {
        let handoff = (&mut parking.hand).await.unwrap();
        let _ = handoff.answer.send(Err(Unmoved::NotSent));
    });
    assert!(hub.move_over_circuit(PEER, &stage, body.clone(), wait).await.is_none());
    waiter.await.unwrap();

    // A waiter parked by another machine never takes the body.
    let _parking = hub.park_move(PEER, &params).unwrap();
    assert!(hub.move_over_circuit("someone-else", &stage, body, wait).await.is_none());
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn a_hand_off_with_no_answer_is_unknown_never_the_hub() {
    let hub = hub();
    let (params, dir) = prepared();
    let wait = Duration::from_secs(5);

    // The circuit drops after it took the body: its answer sender goes with it.
    let mut parking = hub.park_move(PEER, &params).unwrap();
    let stage = parking.stage_id.clone();
    let waiter = tokio::spawn(async move { drop((&mut parking.hand).await.unwrap()) });
    let answered = hub.move_over_circuit(PEER, &stage, json!({}), wait).await;
    let error = answered.expect("a body handed over is never left to the hub").unwrap_err();
    assert!(error.message.contains("transfer.unanswered"), "{}", error.message);
    assert_eq!(error.data.as_ref().unwrap()["unknown"], true);
    waiter.await.unwrap();

    // Taken and never answered within the wait: the same.
    let mut parking = hub.park_move(PEER, &params).unwrap();
    let (held_tx, held_rx) = tokio::sync::oneshot::channel();
    let waiter = tokio::spawn(async move {
        let _ = held_tx.send((&mut parking.hand).await.unwrap());
    });
    let answered = hub.move_over_circuit(PEER, &stage, json!({}), Duration::from_millis(200)).await;
    let error = answered.expect("a body handed over is never left to the hub").unwrap_err();
    assert!(error.message.contains("transfer.unanswered"), "{}", error.message);
    waiter.await.unwrap();
    drop(held_rx);

    // A refusal comes back as the hub path's.
    let mut parking = hub.park_move(PEER, &params).unwrap();
    let waiter = tokio::spawn(async move {
        let handoff = (&mut parking.hand).await.unwrap();
        let mut answering = Some(("t-2".to_owned(), handoff.answer));
        take_moved(&mut answering, &json!({"transferId": "t-2", "error": {"message": "no"}}))
            .unwrap();
    });
    let error = hub.move_over_circuit(PEER, &stage, json!({}), wait).await.unwrap().unwrap_err();
    assert_eq!(error.data.as_ref().unwrap()["refused"], true);
    waiter.await.unwrap();

    // And a result as the hub's answer.
    let mut parking = hub.park_move(PEER, &params).unwrap();
    let waiter = tokio::spawn(async move {
        let handoff = (&mut parking.hand).await.unwrap();
        let mut answering = Some(("t-3".to_owned(), handoff.answer));
        take_moved(&mut answering, &json!({"transferId": "t-3", "result": {"sessionId": "s"}}))
            .unwrap();
    });
    let moved = hub.move_over_circuit(PEER, &stage, json!({}), wait).await.unwrap().unwrap();
    assert_eq!(moved["moved"]["sessionId"], "s");
    assert_eq!(moved["daemonId"], PEER);
    waiter.await.unwrap();
    let _ = std::fs::remove_dir_all(dir);
}
