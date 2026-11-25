//! A chat whose live agent keeps background subagents running, restored with many queued
//! agent notices (Leo, 2026-11-25: 66 `bg-done-…` notices sat in claude-sr2-coord-old's queue
//! after a restart, none ran, and every new delivery to it waited unanswered). After the
//! restore, a new prompt is accepted (or queued) within seconds, and the queue drains.

use super::*;
use std::time::Duration;

/// How long an answer may take: "within seconds".
const ANSWER: Duration = Duration::from_secs(5);
/// How long the whole restored queue may take to drain on the stand-in agent.
const DRAIN: Duration = Duration::from_secs(90);
/// As many as Leo's chat restored.
const RESTORED: usize = 66;

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

fn text(t: &str) -> Vec<Value> {
    vec![json!({"type": "text", "text": t})]
}

/// The queued record of a background command's end notice, as `bg_notify.rs` sends it.
fn queued_notice(hub: &Arc<Hub>, s: &Arc<Session>, i: usize) {
    let notice = json!({"sender": "acpmux", "severity": "info",
        "title": format!("Background command finished: job {i} (exit 0)")});
    let mut provenance = crate::prompt_provenance::notice(&notice, &s.id);
    provenance.set("bgTaskId", json!(format!("bg-{i}")));
    hub.append(
        s,
        "mux",
        "queued",
        json!({
            "promptId": format!("bg-done-bg-{i}"),
            "turnId": format!("t-restored-{i}"),
            "text": format!("[notice from acpmux] Background command finished: job {i} (exit 0)"),
            "client": "acpmux",
            "agent": "acpmux",
            "provenance": provenance,
        }),
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restored_queue_of_notices_beside_background_subagents_answers_and_drains() {
    let (hub, s) = chat().await;
    // A live agent whose background subagent outlives its turn.
    let first =
        hub.prompt_with(&s, text("background-subagent"), "test", false, PromptOptions::default());
    tokio::time::timeout(Duration::from_secs(30), first).await.expect("first turn").unwrap();
    assert!(s.child.lock().await.is_some(), "the agent is live");

    // The daemon restarted with many of its notices queued.
    for i in 0..RESTORED {
        queued_notice(&hub, &s, i);
    }
    hub.restore_queue(&s);
    assert_eq!(s.queue().len(), RESTORED, "the restored queue");
    hub.resume_restored(std::slice::from_ref(&s));

    // A new delivery is answered within seconds: accepted, or queued.
    let (tx, accepted) = tokio::sync::oneshot::channel();
    let opts = PromptOptions {
        prompt_id: Some("after-restore".into()),
        on_accepted: Some(Box::new(move |v| {
            let _ = tx.send(v);
        })),
        ..PromptOptions::default()
    };
    let (h, ss) = (hub.clone(), s.clone());
    let late =
        tokio::spawn(async move { h.prompt_with(&ss, text("hello"), "test", false, opts).await });
    let started = std::time::Instant::now();
    let answer = tokio::time::timeout(ANSWER, accepted).await;
    assert!(
        answer.is_ok(),
        "a new prompt after the restore had no answer in {ANSWER:?}; queue {} turn {:?}",
        s.queue().len(),
        s.turn().map(|t| t.turn_id)
    );
    eprintln!("accepted after {:?}: {}", started.elapsed(), answer.unwrap().unwrap());

    // And the queue drains.
    let deadline = tokio::time::Instant::now() + DRAIN;
    while !s.queue().is_empty() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the restored queue did not drain: {} left, turn {:?}",
            s.queue().len(),
            s.turn().map(|t| t.turn_id)
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    tokio::time::timeout(DRAIN, late).await.expect("the late prompt's turn ends").unwrap().unwrap();
}

/// The stall itself: the restored notices are held (a failed turn's hold, `pause_queue`, logged
/// as `queue_paused`), so a new prompt finds the chat free and goes for the turn lock; and the
/// turn lock is held with no turn shown, as a turn recovered from the agent host holds it until
/// its answer comes (`hosts.rs`). The new prompt waited for that lock still holding the chat's
/// prompt admission, before it was accepted, and every later delivery waited for the admission.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_to_a_chat_whose_turn_lock_is_held_with_no_turn_is_queued_within_seconds() {
    let (hub, s) = chat().await;
    let first =
        hub.prompt_with(&s, text("background-subagent"), "test", false, PromptOptions::default());
    tokio::time::timeout(Duration::from_secs(30), first).await.expect("first turn").unwrap();
    let held: Vec<String> = (0..RESTORED).map(|i| format!("bg-done-bg-{i}")).collect();
    for i in 0..RESTORED {
        queued_notice(&hub, &s, i);
    }
    hub.append(&s, "mux", "queue_paused", json!({"held": held}));
    hub.restore_queue(&s);
    assert_eq!(s.queue().len(), RESTORED);
    assert!(s.queue().iter().all(|q| q.held), "the restored notices are held");

    // A turn recovered from the agent host holds the turn lock; no acpmux turn shows.
    let (release, released) = tokio::sync::oneshot::channel::<()>();
    let (locked_tx, locked) = tokio::sync::oneshot::channel();
    let holder = {
        let s = s.clone();
        tokio::spawn(async move {
            let _guard = s.turn_lock.lock().await;
            let _ = locked_tx.send(());
            let _ = released.await;
        })
    };
    locked.await.unwrap();
    assert!(s.turn().is_none());

    // Two deliveries, one after the other: each is answered within seconds.
    let mut late = Vec::new();
    for id in ["after-restore-1", "after-restore-2"] {
        let (tx, accepted) = tokio::sync::oneshot::channel();
        let opts = PromptOptions {
            prompt_id: Some(id.into()),
            on_accepted: Some(Box::new(move |v| {
                let _ = tx.send(v);
            })),
            ..PromptOptions::default()
        };
        let (h, ss) = (hub.clone(), s.clone());
        late.push(tokio::spawn(
            async move { h.prompt_with(&ss, text(id), "test", false, opts).await },
        ));
        let started = std::time::Instant::now();
        let answer = tokio::time::timeout(ANSWER, accepted).await;
        assert!(answer.is_ok(), "{id} had no answer in {ANSWER:?} while the turn lock was held");
        let answer = answer.unwrap().unwrap();
        eprintln!("{id} answered after {:?}: {answer}", started.elapsed());
        assert_eq!(answer["queued"], true, "{answer}");
    }

    // The lock comes free: both run.
    release.send(()).unwrap();
    holder.await.unwrap();
    for task in late {
        tokio::time::timeout(DRAIN, task).await.expect("its turn ends").unwrap().unwrap();
    }
}
