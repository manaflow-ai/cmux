//! Automatic messages stop extending an aged turn; its tools finish and its queue drains.

use super::*;
use crate::config::{Config, StoreMode};
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

fn blocks(text: &str) -> Vec<Value> {
    vec![json!({"type": "text", "text": text})]
}

async fn admitted(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    text: &'static str,
    steer: bool,
    mut opts: PromptOptions,
) -> (tokio::task::JoinHandle<Result<Value, RpcError>>, Value) {
    let (tx, rx) = tokio::sync::oneshot::channel();
    opts.prompt_id = Some(text.to_owned());
    opts.on_accepted = Some(Box::new(move |v| {
        let _ = tx.send(v);
    }));
    let (hub, session) = (hub.clone(), session.clone());
    let task =
        tokio::spawn(
            async move { hub.prompt_with(&session, blocks(text), "test", steer, opts).await },
        );
    let accepted = tokio::time::timeout(WAIT, rx).await.unwrap().unwrap();
    (task, accepted)
}

fn agent() -> PromptOptions {
    PromptOptions { agent: Some("worker".to_owned()), ..Default::default() }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn agent_steer_window_drains_mixed_queue_without_cancelling_work() {
    let temp = tempfile::tempdir().unwrap();
    let fifo = temp.path().join("work-gate");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["/usr/bin/env", "FAKE_CLAUDE_STEER=1", "python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, temp.path()).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub
        .new_session(NewRequest { cwd: Some(temp.path().to_owned()), ..Default::default() })
        .await
        .unwrap();
    let mut events = hub.subscribe();
    let original = {
        let (hub, session) = (hub.clone(), session.clone());
        let text = format!("work-gate: {}", fifo.display());
        tokio::spawn(async move { hub.prompt(&session, blocks(&text), "test", false).await })
    };
    tokio::time::timeout(WAIT, async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.msg["params"]["update"]["toolCallId"] == "wg-1" {
                break;
            }
        }
    })
    .await
    .unwrap();
    // Closing this writer lets the fixture's tool finish, even if an assertion unwinds.
    let gate = tokio::task::spawn_blocking(move || {
        std::fs::OpenOptions::new().write(true).open(fifo).unwrap()
    })
    .await
    .unwrap();
    let original_turn = session.turn().unwrap().turn_id;
    let (fresh, accepted) = admitted(&hub, &session, "fresh-agent", true, agent()).await;
    assert_eq!(accepted["steer"], true);
    assert_eq!(
        tokio::time::timeout(WAIT, fresh).await.unwrap().unwrap().unwrap()["stopReason"],
        "steered"
    );

    // No sleep: age the original turn while its tool remains blocked. Activity and steers
    // must not renew the window, including on an adopted turn with an old started_at.
    session.turn.lock().unwrap().as_mut().unwrap().started_at = now_ms() - 60 * 60 * 1000;
    let (human, human_accepted) =
        admitted(&hub, &session, "human-steer", true, Default::default()).await;
    let human_answer = tokio::time::timeout(WAIT, human).await.unwrap().unwrap().unwrap();
    let (explicit, explicit_accepted) = admitted(
        &hub,
        &session,
        "explicit-send-now",
        true,
        PromptOptions { steer_now: true, ..agent() },
    )
    .await;
    let explicit_answer = tokio::time::timeout(WAIT, explicit).await.unwrap().unwrap().unwrap();
    let refused = hub
        .prompt_with(
            &session,
            blocks("steer-only-refused"),
            "test",
            true,
            PromptOptions { steer_only: true, ..agent() },
        )
        .await;
    let (older, accepted) =
        admitted(&hub, &session, "older-unsteered", false, Default::default()).await;
    assert_eq!(accepted["queued"], true);
    let (late, late_accepted) =
        admitted(&hub, &session, "late-agent", true, PromptOptions { interrupt: true, ..agent() })
            .await;
    let (later, later_accepted) = admitted(&hub, &session, "later-agent", true, agent()).await;
    // Release before checking the regression so a red run cleans up its fixture too.
    let pending = session.queue();
    let still_running = session.turn().map(|t| t.turn_id);
    drop(gate);
    let original_answer = tokio::time::timeout(WAIT, original).await.unwrap().unwrap().unwrap();
    let older_answer = tokio::time::timeout(WAIT, older).await.unwrap().unwrap().unwrap();
    let late_answer = tokio::time::timeout(WAIT, late).await.unwrap().unwrap().unwrap();
    let later_answer = tokio::time::timeout(WAIT, later).await.unwrap().unwrap().unwrap();
    assert_eq!(late_accepted["queued"], true, "aged agent steer must enter the durable queue");
    assert_eq!(later_accepted["queued"], true, "a newer delivery cannot renew the turn");
    assert_eq!(human_accepted["steer"], true);
    assert_eq!(human_answer["stopReason"], "steered");
    assert_eq!(explicit_accepted["steer"], true);
    assert_eq!(explicit_answer["stopReason"], "steered");
    assert!(refused.is_err_and(|e| e.message.starts_with("steer.unavailable")));
    assert_eq!(still_running.as_deref(), Some(original_turn.as_str()));
    assert_eq!(
        pending.iter().map(|q| q.prompt_id.as_str()).collect::<Vec<_>>(),
        ["older-unsteered", "late-agent", "later-agent"]
    );
    assert_eq!(original_answer["stopReason"], "end_turn", "admission must not cancel the tool");
    for (id, answer) in [
        ("older-unsteered", older_answer),
        ("late-agent", late_answer),
        ("later-agent", later_answer),
    ] {
        assert_eq!(answer["stopReason"], "end_turn");
        assert_eq!(answer["_meta"]["acpmux"]["promptId"], id);
        assert_ne!(answer["_meta"]["acpmux"]["turnId"], original_turn);
    }
    assert!(session.turn().is_none());
    assert!(session.queue().is_empty());
    let records = hub.events(&session.id, 0, 100_000).unwrap();
    let sent: Vec<_> =
        records.iter().filter(|r| r.dir == "out" && r.kind == "session/prompt").collect();
    for text in ["fresh-agent", "older-unsteered", "late-agent", "later-agent"] {
        assert_eq!(
            sent.iter().filter(|r| r.msg["params"]["prompt"].to_string().contains(text)).count(),
            1,
            "{text} must be delivered once"
        );
    }
    assert!(!records.iter().any(|r| r.dir == "out" && r.kind == "session/cancel"));
    let starts = records.iter().filter(|r| r.kind == "turn_started").count();
    let ends = records.iter().filter(|r| r.kind == "turn_result").count();
    assert_eq!(starts, ends, "each actual turn has exactly one final outcome");
}
