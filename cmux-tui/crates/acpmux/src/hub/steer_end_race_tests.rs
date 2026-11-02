//! A steer still in setup when another steer finishes the turn must not lose its text.

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

async fn unsent_steer_after_completion(steer_only: bool) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        // At normal CPU class (`cpu_class.rs`), as in the hermetic integration tests: at
        // background class a loaded fleet Mac did not end the stand-in's steer turn in 20 s.
        "harnesses": {"fake": {
            "argv": ["/usr/bin/env", "FAKE_CODEX_STEER=1", "python3", fake],
            "env": {"ACPMUX_SESSION_CPU_CLASS": "normal"},
        }},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    let mut events = hub.subscribe();
    let running = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            hub.prompt(&session, vec![json!({"type": "text", "text": "original"})], "test", false)
                .await
        })
    };
    tokio::time::timeout(WAIT, async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.msg["params"]["update"]["content"]["text"] == "turn: original" {
                break;
            }
        }
    })
    .await
    .unwrap();
    let old_turn = session.turn().unwrap().turn_id;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.copy_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let unsent = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            hub.prompt_with(
                &session,
                vec![json!({"type": "text", "text": "deliver this later"})],
                "test",
                true,
                PromptOptions { steer_only, ..Default::default() },
            )
            .await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    // The fake Codex harness answers only the final steer, which settles the original
    // request through steer_end. The other steer is deterministically still making copies.
    let finishing = hub.prompt(
        &session,
        vec![json!({"type": "text", "text": "finish the original turn"})],
        "test",
        true,
    );
    let finished = tokio::time::timeout(WAIT, finishing).await.unwrap().unwrap();
    assert_eq!(finished["stopReason"], "end_turn");
    let original = tokio::time::timeout(WAIT, running).await.unwrap().unwrap().unwrap();
    assert_eq!(original["stopReason"], "end_turn");
    assert!(session.turn().is_none());
    release.send(()).unwrap();
    let answer = tokio::time::timeout(WAIT, unsent).await.unwrap().unwrap();
    if steer_only {
        let error = answer.expect_err("an unsent steer-only request cannot claim the old answer");
        assert!(error.message.starts_with(crate::claude_stdio::STEER_NO_TURN));
    } else {
        let answer = answer.unwrap();
        assert_eq!(answer["stopReason"], "end_turn");
        assert_ne!(answer["_meta"]["acpmux"]["turnId"], old_turn);
    }
    let records = hub.events(&session.id, 0, 100_000).unwrap();
    let delivered = records
        .iter()
        .filter(|r| {
            r.dir == "out"
                && r.kind == "session/prompt"
                && r.msg["params"]["prompt"].to_string().contains("deliver this later")
        })
        .count();
    assert_eq!(delivered, usize::from(!steer_only));
    let starts = records.iter().filter(|r| r.kind == "turn_started").count();
    assert_eq!(starts, if steer_only { 1 } else { 2 });
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_unsent_steer_gets_its_own_turn_after_another_steer_finishes() {
    unsent_steer_after_completion(false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_unsent_steer_only_refuses_the_completed_turns_answer() {
    unsent_steer_after_completion(true).await;
}
