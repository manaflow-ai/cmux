//! Fuzz row g, g1: a prompt that comes while another prompt holds the chat's turn lock and has
//! not shown its turn yet (`start_turn` runs after awaits) is accepted at once, queued next, not
//! after that whole turn (`queue.rs` `queue_slot`, `Session::turn_claimed`).

use super::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub with one open chat on the stand-in agent, its store in memory.
async fn chat() -> (Arc<Hub>, Arc<Session>) {
    chat_with_store(None).await
}

async fn chat_with_store(store: Option<Box<dyn crate::store::Store>>) -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = store.unwrap_or_else(|| {
        crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap()
    });
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

/// The person's prompt `text` under `prompt_id`; its acceptance goes to `accepted`.
fn prompt(
    hub: &Arc<Hub>,
    s: &Arc<Session>,
    prompt_id: &str,
    text: &str,
    accepted: tokio::sync::oneshot::Sender<Value>,
) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let opts = PromptOptions {
        prompt_id: Some(prompt_id.to_owned()),
        on_accepted: Some(Box::new(move |v| {
            let _ = accepted.send(v);
        })),
        ..PromptOptions::default()
    };
    let blocks = vec![json!({"type": "text", "text": text})];
    let (hub, s) = (hub.clone(), s.clone());
    tokio::spawn(async move { hub.prompt_with(&s, blocks, "test", false, opts).await })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_behind_one_about_to_start_its_turn_is_accepted_queued_at_once() {
    let (hub, s) = chat().await;
    // The first prompt holds the turn lock, stopped before its turn shows.
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel::<()>();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let (first_tx, first_accepted) = tokio::sync::oneshot::channel();
    let first = prompt(&hub, &s, "g1-a", "first", first_tx);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    assert!(s.turn().is_none(), "the first prompt has not shown its turn");

    // The second is accepted while the first still holds the chat: queued, next.
    let (second_tx, second_accepted) = tokio::sync::oneshot::channel();
    let second = prompt(&hub, &s, "g1-b", "second", second_tx);
    let accepted = tokio::time::timeout(WAIT, second_accepted)
        .await
        .expect("the second prompt is accepted before the first turn ends")
        .unwrap();
    assert!(s.turn().is_none(), "accepted while the first prompt still waits to start");
    assert_eq!(
        (&accepted["queued"], &accepted["state"], &accepted["position"]),
        (&json!(true), &json!("queued"), &json!(1)),
        "{accepted}"
    );
    let queued = hub.events(&s.id, 0, 10_000).unwrap();
    assert!(
        queued.iter().any(|r| r.kind == "queued" && r.msg["promptId"] == "g1-b"),
        "its queued record is in the journal when it is accepted"
    );

    // Both run, in order.
    release.send(()).unwrap();
    let started = tokio::time::timeout(WAIT, first_accepted).await.unwrap().unwrap();
    assert_eq!((&started["queued"], &started["state"]), (&json!(false), &json!("started")));
    for done in [first, second] {
        let r = tokio::time::timeout(WAIT, done).await.unwrap().unwrap().unwrap();
        assert_eq!(r["stopReason"], "end_turn", "{r}");
    }
    let order: Vec<Value> = hub
        .events(&s.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|r| r.kind == "user_message")
        .map(|r| r.msg["promptId"].clone())
        .collect();
    assert_eq!(order, [json!("g1-a"), json!("g1-b")]);
}

/// Two prompts sent while a turn is ahead of them both queue. The first of them waits in
/// `queue_slot` for that whole turn; it must not keep the admission order's lock while it
/// waits, or the second is never accepted (ten live moves: "q-2 never queued").
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_second_queued_prompt_is_accepted_while_the_first_still_waits() {
    let (hub, s) = chat().await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel::<()>();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let (first_tx, _first_accepted) = tokio::sync::oneshot::channel();
    let first = prompt(&hub, &s, "q-0", "first", first_tx);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();

    let mut waiting = vec![first];
    for (position, id) in [(1, "q-1"), (2, "q-2")] {
        let (tx, accepted) = tokio::sync::oneshot::channel();
        waiting.push(prompt(&hub, &s, id, id, tx));
        let accepted = tokio::time::timeout(Duration::from_secs(5), accepted)
            .await
            .unwrap_or_else(|_| panic!("{id} is accepted while the prompts ahead still wait"))
            .unwrap();
        assert_eq!(
            (&accepted["queued"], &accepted["position"]),
            (&json!(true), &json!(position)),
            "{accepted}"
        );
    }

    release.send(()).unwrap();
    for done in waiting {
        let r = tokio::time::timeout(WAIT, done).await.unwrap().unwrap().unwrap();
        assert_eq!(r["stopReason"], "end_turn", "{r}");
    }
    let order: Vec<Value> = hub
        .events(&s.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|r| r.kind == "user_message")
        .map(|r| r.msg["promptId"].clone())
        .collect();
    assert_eq!(order, [json!("q-0"), json!("q-1"), json!("q-2")]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_slow_attachment_cannot_be_overtaken_before_queue_admission() {
    let (hub, s) = chat().await;
    let path =
        std::env::temp_dir().join(format!("acpmux-queued-upload-{}.txt", uuid::Uuid::now_v7()));
    std::fs::write(&path, "attachment").unwrap();
    let first_blocks = vec![json!({
        "type": "resource_link",
        "uri": "file:///slow-attachment.txt",
        "name": "slow-attachment.txt",
        "_meta": {"acpmux": {"uploadPath": path.to_string_lossy()}}
    })];
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.prompt_admission_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let (first_tx, first_accepted) = tokio::sync::oneshot::channel();
    let first_hub = hub.clone();
    let first_session = s.clone();
    let first = tokio::spawn(async move {
        first_hub
            .prompt_with(
                &first_session,
                first_blocks,
                "test",
                false,
                PromptOptions {
                    prompt_id: Some("slow-attachment".into()),
                    on_accepted: Some(Box::new(move |v| {
                        let _ = first_tx.send(v);
                    })),
                    ..PromptOptions::default()
                },
            )
            .await
    });
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();

    let (second_tx, mut second_accepted) = tokio::sync::oneshot::channel();
    let second = prompt(&hub, &s, "after-attachment", "second", second_tx);
    assert!(
        tokio::time::timeout(Duration::from_millis(100), &mut second_accepted).await.is_err(),
        "the second prompt reached the queue while the first was still resolving its attachment"
    );

    release.send(()).unwrap();
    let first_notice = tokio::time::timeout(WAIT, first_accepted).await.unwrap().unwrap();
    assert_eq!(first_notice["promptId"], "slow-attachment");
    for done in [first, second] {
        tokio::time::timeout(WAIT, done).await.unwrap().unwrap().unwrap();
    }
    let order: Vec<Value> = hub
        .events(&s.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|r| r.kind == "user_message")
        .map(|r| r.msg["promptId"].clone())
        .collect();
    assert_eq!(order, [json!("slow-attachment"), json!("after-attachment")]);
    let _ = std::fs::remove_file(path);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn exact_prompt_stop_fences_admission_before_turn_without_stopping_next_person() {
    let (hub, session) = chat().await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let (accepted_tx, _accepted) = tokio::sync::oneshot::channel();
    let stopped = prompt(&hub, &session, "workflow-dequeued", "must not reach agent", accepted_tx);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    assert!(session.turn().is_none());
    hub.cancel_prompt(&session, "workflow-dequeued").await.unwrap();
    release.send(()).unwrap();
    let result = tokio::time::timeout(WAIT, stopped).await.unwrap().unwrap();
    assert!(result.is_err() || result.unwrap()["stopReason"] == "cancelled");
    assert!(
        !hub.events(&session.id, 0, 10000)
            .unwrap()
            .iter()
            .any(|event| event.kind == "user_message"
                && event.msg["promptId"] == "workflow-dequeued")
    );
    let (accepted_tx, _accepted) = tokio::sync::oneshot::channel();
    let next = prompt(&hub, &session, "person-after-pause", "person next", accepted_tx);
    assert_eq!(
        tokio::time::timeout(WAIT, next).await.unwrap().unwrap().unwrap()["stopReason"],
        "end_turn"
    );
    // Reconstruct the lazy cache as after a daemon restart: the fence is durable.
    hub.clear_prompt_stop_cache_for_test(&session);
    let turn = TurnInfo::prompted(
        "workflow",
        "replay",
        "new-turn",
        "workflow-dequeued~resume-1",
        Control::Local,
    );
    assert!(hub.start_turn(&session, None, None, false, false, turn).is_err());
    hub.shutdown_all().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn race_guard_refuses_prompt_cancelled_at_final_acceptance_fence() {
    let (hub, session) = chat().await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let active = std::sync::Arc::new(AtomicBool::new(true));
    let guard_active = active.clone();
    let opts = PromptOptions {
        prompt_id: Some("race-cancel-fence".into()),
        race_guard: Some(std::sync::Arc::new(move || {
            if guard_active.load(Ordering::SeqCst) {
                Ok(())
            } else {
                Err(RpcError::invalid_params("race cancelled")
                    .with_data(json!({"reason": "race.cancelled"})))
            }
        })),
        ..PromptOptions::default()
    };
    let pending = {
        let hub = hub.clone();
        let session = session.clone();
        tokio::spawn(async move {
            hub.prompt_with(
                &session,
                vec![json!({"type":"text","text":"must not reach agent"})],
                "race-test",
                false,
                opts,
            )
            .await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    active.store(false, Ordering::SeqCst);
    release.send(()).unwrap();
    let result = tokio::time::timeout(WAIT, pending).await.unwrap().unwrap();
    assert!(result.is_err(), "cancelled race prompt was accepted: {result:?}");
    assert!(!hub.events(&session.id, 0, 10_000).unwrap().iter().any(|event| {
        event.kind == "user_message" && event.msg["promptId"] == "race-cancel-fence"
    }));
    hub.shutdown_all().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn exact_prompt_stop_survives_malformed_lines_and_an_unterminated_log_tail() {
    use std::io::Write;
    let directory = cmux_unix_socket::short_test_dir("prompt-stop-corrupt");
    let store = crate::store::LocalStore::new(directory.path().to_owned(), 1 << 20).unwrap();
    let (hub, session) = chat_with_store(Some(Box::new(store))).await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let (accepted_tx, _accepted) = tokio::sync::oneshot::channel();
    let stopped = prompt(&hub, &session, "workflow-torn", "must not reach agent", accepted_tx);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    hub.store.flush_session(&session.id).unwrap();
    hub.store.close_log(&session.id);
    let path = directory.path().join(&session.id).join("events").join("000001.ndjson");
    let mut log = std::fs::OpenOptions::new().append(true).open(path).unwrap();
    // Existing malformed history must not freeze the chat. A real truncated final line
    // also joins the next append: acknowledgement must prove the stop can be read back.
    log.write_all(b"{malformed history}\n{\"seq\":999").unwrap();
    log.sync_all().unwrap();
    drop(log);
    hub.cancel_prompt(&session, "workflow-torn").await.unwrap();
    release.send(()).unwrap();
    let result = tokio::time::timeout(WAIT, stopped).await.unwrap().unwrap();
    assert!(result.is_err() || result.unwrap()["stopReason"] == "cancelled");

    let (accepted_tx, _accepted) = tokio::sync::oneshot::channel();
    let next = prompt(&hub, &session, "person-after-torn", "person next", accepted_tx);
    assert_eq!(
        tokio::time::timeout(WAIT, next).await.unwrap().unwrap().unwrap()["stopReason"],
        "end_turn"
    );
    hub.clear_prompt_stop_cache_for_test(&session);
    let turn = TurnInfo::prompted(
        "workflow",
        "late retry",
        "retry-turn",
        "workflow-torn~resume-1",
        Control::Local,
    );
    assert!(
        hub.start_turn(&session, None, None, false, false, turn).is_err(),
        "acknowledged stop was lost inside the malformed tail"
    );
    hub.shutdown_all().await;
}

/// #40347 F1: a turn that shows is not yet an accepted prompt. Its last check (a Cloud turn's
/// claim) may still refuse it, so a second copy of the prompt that comes then hears no turn.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_second_copy_hears_no_turn_before_the_first_is_accepted() {
    let (hub, s) = chat().await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel::<()>();
    *hub.turn_shown_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let (first_tx, mut first_accepted) = tokio::sync::oneshot::channel();
    let first = prompt(&hub, &s, "f1", "first", first_tx);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    assert!(s.turn().is_some(), "the first copy's turn shows");
    assert!(first_accepted.try_recv().is_err(), "the first copy is not accepted yet");

    let (second_tx, mut second_notice) = tokio::sync::oneshot::channel();
    let second = prompt(&hub, &s, "f1", "first", second_tx);
    assert!(second_notice.try_recv().is_err(), "duplicate callback fired before first acceptance");

    // The duplicate waits for the first attempt's acceptance before it can hear the receipt.
    release.send(()).unwrap();
    let started = tokio::time::timeout(WAIT, first_accepted).await.unwrap().unwrap();
    let notice = tokio::time::timeout(WAIT, second_notice).await.unwrap().unwrap();
    assert_eq!(
        (&notice["duplicate"], &notice["turnId"], &notice["queued"]),
        (&json!(true), &started["turnId"], &json!(false)),
        "{notice}"
    );

    // Once the first copy is accepted, a third copy hears its turn.
    let (third_tx, third_notice) = tokio::sync::oneshot::channel();
    let third = prompt(&hub, &s, "f1", "first", third_tx);
    let notice = tokio::time::timeout(WAIT, third_notice).await.unwrap().unwrap();
    assert!(
        notice["turnId"] == started["turnId"] || s.turn().is_none(),
        "a copy that comes while the accepted turn runs hears its turn: {notice}"
    );
    for done in [first, second, third] {
        let r = tokio::time::timeout(WAIT, done).await.unwrap().unwrap().unwrap();
        assert_eq!(r["stopReason"], "end_turn", "{r}");
    }
    hub.shutdown_all().await;
}

/// Leo, 2026-11-25: "no prompt holds `prompt_admission` across an unbounded await ... A delivery
/// always gets an answer within seconds". Every prompt here sticks in its setup on the agent's
/// lock (held by the test, as a call that never came back holds it): each is still answered,
/// queued, within seconds, and the queue runs them all once the lock comes back
/// (`prompt_admission.rs`). Before, the first held the chat's admission across that await and every
/// later prompt waited for it unanswered (one chat: 66 restored notices, none answered).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn prompts_stuck_in_setup_are_answered_queued_within_seconds_and_the_queue_drains() {
    let (hub, s) = chat().await;
    let stuck = s.child.lock().await;
    let bound = super::prompt_admission::ANSWER_BOUND + Duration::from_secs(4);
    let mut accepted = Vec::new();
    let mut runs = Vec::new();
    for i in 0..8 {
        let (tx, rx) = tokio::sync::oneshot::channel();
        runs.push(prompt(&hub, &s, &format!("stuck-{i}"), &format!("prompt {i}"), tx));
        accepted.push(rx);
    }
    let started = std::time::Instant::now();
    for (i, rx) in accepted.into_iter().enumerate() {
        let left = bound.saturating_sub(started.elapsed());
        let notice = tokio::time::timeout(left, rx)
            .await
            .unwrap_or_else(|_| panic!("prompt {i} got no answer within {bound:?}"))
            .unwrap();
        assert_eq!(
            (&notice["queued"], &notice["state"], &notice["deferred"]),
            (&json!(true), &json!("queued"), &json!(true)),
            "{notice}"
        );
    }
    let journal = hub.events(&s.id, 0, 10_000).unwrap();
    for i in 0..8 {
        assert!(
            journal.iter().any(|r| r.kind == "queued" && r.msg["promptId"] == format!("stuck-{i}")),
            "stuck-{i} is queued durably when it is answered"
        );
    }
    assert!(s.turn().is_none(), "nothing ran while the agent's lock was held");

    // The lock comes back: every prompt runs from the queue, each with its own answer.
    drop(stuck);
    for run in runs {
        let answer = tokio::time::timeout(WAIT * 3, run).await.unwrap().unwrap().unwrap();
        assert!(answer.get("stopReason").is_some(), "{answer}");
    }
    let ran = hub
        .events(&s.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|r| r.kind == "user_message")
        .count();
    assert_eq!(ran, 8, "every queued prompt ran once");
    assert_eq!(s.queue().len(), 0, "the queue drained");
}

/// The holder side: a prompt held in its setup keeps the chat's admission no longer than its
/// lease, so a later prompt is answered while the first is still held, and the first, once
/// past its own due time, is queued and runs after (`prompt_admission.rs`).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_held_past_its_lease_does_not_hold_up_the_next() {
    let (hub, s) = chat().await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (_release, release_rx) = tokio::sync::oneshot::channel::<()>();
    *hub.prompt_admission_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let (first_tx, first_accepted) = tokio::sync::oneshot::channel();
    let first = prompt(&hub, &s, "held", "held in setup", first_tx);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();

    let (second_tx, second_accepted) = tokio::sync::oneshot::channel();
    let second = prompt(&hub, &s, "next", "after the held one", second_tx);
    let bound = super::prompt_admission::ANSWER_BOUND + Duration::from_secs(4);
    let next =
        tokio::time::timeout(bound, second_accepted).await.expect("the next is answered").unwrap();
    assert_eq!(next["promptId"], "next", "{next}");
    let held = tokio::time::timeout(bound, first_accepted)
        .await
        .expect("the held one is answered")
        .unwrap();
    assert_eq!((&held["promptId"], &held["deferred"]), (&json!("held"), &json!(true)), "{held}");
    for run in [first, second] {
        tokio::time::timeout(WAIT * 3, run).await.unwrap().unwrap().unwrap();
    }
    let ran: Vec<Value> = hub
        .events(&s.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|r| r.kind == "user_message")
        .map(|r| r.msg["promptId"].clone())
        .collect();
    assert_eq!(ran, [json!("next"), json!("held")]);
}

/// The turn lock side: a prompt that reached the queue while another holds the turn lock (a turn
/// that never showed, a call that never came back) is answered queued by its due time, not when
/// the lock is let go, and runs once it is (`queue.rs`, `answer_due`).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_waiting_on_a_held_turn_lock_is_answered_queued_by_its_due_time() {
    let (hub, s) = chat().await;
    let held = s.turn_lock.lock().await;
    let (tx, accepted) = tokio::sync::oneshot::channel();
    let run = prompt(&hub, &s, "behind-lock", "waits on the turn lock", tx);
    let bound = super::prompt_admission::ANSWER_BOUND + Duration::from_secs(4);
    let notice = tokio::time::timeout(bound, accepted)
        .await
        .expect("answered while the turn lock is held")
        .unwrap();
    assert_eq!((&notice["queued"], &notice["state"]), (&json!(true), &json!("queued")), "{notice}");
    assert!(
        hub.events(&s.id, 0, 10_000)
            .unwrap()
            .iter()
            .any(|r| r.kind == "queued" && r.msg["promptId"] == "behind-lock"),
        "queued durably when answered"
    );
    drop(held);
    let answer = tokio::time::timeout(WAIT * 3, run).await.unwrap().unwrap().unwrap();
    assert!(answer.get("stopReason").is_some(), "{answer}");
    assert_eq!(s.queue().len(), 0, "the queue drained");
}

/// An owner still importing its journal has reserved the next sequence numbers. If its
/// next page is late, the same delivery can be retried without losing those numbers.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn admission_deadline_during_journal_restore_allows_same_id_after_restore() {
    check_admission_while_restoring(false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn admission_deadline_during_deferred_setup_cannot_queue_into_a_parked_journal() {
    check_admission_while_restoring(true).await;
}

async fn check_admission_while_restoring(hold_setup: bool) {
    let (hub, s) = chat().await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (_release, release_rx) = tokio::sync::oneshot::channel();
    if hold_setup {
        *hub.prompt_admission_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    }
    s.restoring.store(true, Ordering::SeqCst);
    hub.park_writes(&s, 17);
    let (tx, accepted) = tokio::sync::oneshot::channel();
    let run = prompt(&hub, &s, "recover", "after the restore", tx);
    if hold_setup {
        tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    }
    let bound = super::prompt_admission::ANSWER_BOUND + Duration::from_secs(2);
    let refusal =
        tokio::time::timeout(bound, run).await.expect("bounded restore wait").unwrap().unwrap_err();
    let data = refusal.data.unwrap();
    assert_eq!(data["wait"], "prompt waiting for journal restore");
    assert_eq!(data["retryable"], true);
    assert!(accepted.await.is_err(), "nothing accepted or queued during the restore");
    assert!(s.queue().is_empty());
    s.restoring.store(false, Ordering::SeqCst);
    hub.unpark_writes(&s);
    s.restore_done.notify_waiters();

    let (tx, accepted) = tokio::sync::oneshot::channel();
    let retry = prompt(&hub, &s, "recover", "after the restore", tx);
    let ack = tokio::time::timeout(WAIT, accepted).await.unwrap().unwrap();
    assert_eq!(ack["promptId"], "recover");
    assert_ne!(ack["duplicate"], true);
    tokio::time::timeout(WAIT, retry).await.unwrap().unwrap().unwrap();
    let events = hub.events(&s.id, 0, 10000).unwrap();
    assert_eq!(
        events
            .iter()
            .filter(|e| e.kind == "user_message" && e.msg["promptId"] == "recover")
            .count(),
        1
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_deferred_prompt_is_registered_at_insertion_and_settles_on_immediate_withdrawal() {
    let (hub, session) = chat().await;
    let stuck = session.child.lock().await;
    let inspected = session.clone();
    let (tx, registered) = tokio::sync::oneshot::channel();
    *hub.queued_log_seam.lock().unwrap() = Some(Box::new(move || {
        // The same queue lock still protects insertion and its durable record.
        let restored = inspected.restored.lock().unwrap().clone();
        tx.send(restored).unwrap();
    }));
    let remover = hub.clone();
    let target = session.clone();
    let opts = PromptOptions {
        prompt_id: Some("withdraw-deferred".into()),
        on_accepted: Some(Box::new(move |notice| {
            assert_eq!(notice["deferred"], true);
            assert!(remover.remove_queued(&target, "withdraw-deferred"));
        })),
        ..PromptOptions::default()
    };
    let answer = tokio::time::timeout(
        WAIT,
        hub.prompt_with(
            &session,
            vec![json!({"type":"text","text":"withdraw"})],
            "test",
            false,
            opts,
        ),
    )
    .await
    .unwrap()
    .unwrap();
    let meta = &answer["_meta"]["acpmux"];
    assert_eq!(meta["withdrawn"], true);
    assert_eq!(
        registered.await.unwrap(),
        vec![("withdraw-deferred".to_owned(), meta["turnId"].as_str().unwrap().to_owned())]
    );
    assert!(session.queue().is_empty());
    assert!(session.restored.lock().unwrap().is_empty());
    drop(stuck);
    assert!(!hub.events(&session.id, 0, 1000).unwrap().iter().any(|r| r.kind == "user_message"));
    hub.shutdown_all().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_unanswered_race_guarded_prompt_refuses_without_a_durable_queue_entry() {
    let (hub, session) = chat().await;
    let mut runs = Vec::new();
    for (id, cancelled) in [("race-active", false), ("race-cancelled", true)] {
        let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
        let (hold, release) = tokio::sync::oneshot::channel();
        *hub.prompt_admission_seam.lock().unwrap() = Some((arrived_tx, release));
        let active = Arc::new(AtomicBool::new(true));
        let guard = active.clone();
        let opts = PromptOptions {
            prompt_id: Some(id.to_owned()),
            on_accepted: Some(Box::new(|_| panic!("an unanswered race prompt was accepted"))),
            race_guard: Some(Arc::new(move || {
                if guard.load(Ordering::SeqCst) {
                    Ok(())
                } else {
                    Err(RpcError::invalid_params("race cancelled")
                        .with_data(json!({"reason":"race.cancelled"})))
                }
            })),
            ..PromptOptions::default()
        };
        let (hub, target) = (hub.clone(), session.clone());
        let run = tokio::spawn(async move {
            hub.prompt_with(
                &target,
                vec![json!({"type":"text","text":"guarded"})],
                "test",
                false,
                opts,
            )
            .await
        });
        tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
        active.store(!cancelled, Ordering::SeqCst);
        runs.push((cancelled, hold, run));
    }
    for (cancelled, _hold, run) in runs {
        let err = tokio::time::timeout(WAIT, run).await.unwrap().unwrap().unwrap_err();
        assert_eq!(
            err.data.unwrap()["reason"],
            if cancelled { "race.cancelled" } else { "retry.busy" }
        );
    }
    assert!(session.queue().is_empty());
    assert!(
        !hub.events(&session.id, 0, 1000)
            .unwrap()
            .iter()
            .any(|r| matches!(r.kind.as_str(), "user_message" | "queued"))
    );
    hub.shutdown_all().await;
}
