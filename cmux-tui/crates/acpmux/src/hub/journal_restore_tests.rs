//! `journal_restore.rs` against a purge that races it (review of #37284 at df095c5d, F2).

use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;
use std::time::Duration;

/// A purge that has deleted the chat's records but not yet left the session map (its cleanup,
/// `purge_seam`) holds the close lock: a restore that comes then waits for it, and is refused,
/// so no record of the restore goes back into the purged chat.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restore_during_a_purge_writes_nothing_back() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    let last = hub.events(&session.id, 0, 10_000).unwrap().last().map_or(0, |e| e.seq);
    let params = json!({
        "sessionId": session.id,
        "createdAt": session.meta().created_at,
        "afterSeq": last,
        "records": [{"seq": last + 1, "at": 1, "dir": "mux", "kind": "status",
                     "msg": {"status": "idle", "detail": "kept"}}],
    });

    let (arrived, at_cleanup) = tokio::sync::oneshot::channel();
    let (release, released) = tokio::sync::oneshot::channel();
    *hub.purge_seam.lock().unwrap() = Some((arrived, released));
    let purge = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move { hub.kill(&session, true).await })
    };
    tokio::time::timeout(Duration::from_secs(20), at_cleanup).await.unwrap().unwrap();
    let restore = {
        let hub = hub.clone();
        tokio::spawn(async move { hub.journal_restore(&params).await })
    };
    tokio::time::sleep(Duration::from_millis(300)).await;
    release.send(()).unwrap();
    purge.await.unwrap().unwrap();
    let restored = tokio::time::timeout(Duration::from_secs(20), restore).await.unwrap().unwrap();
    assert!(restored.is_err(), "a restore went into a purged chat: {restored:?}");
    let left = hub.events(&session.id, 0, 10_000).unwrap_or_default();
    assert!(left.is_empty(), "the purged chat has records again: {left:#?}");
}

/// A hub on a memory store, with one chat; `at_91b`: under the rules of 91b1343d.
async fn hub_with_chat(at_91b: bool) -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.rules_of_91b.store(at_91b, Ordering::SeqCst);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

fn restore_params(session: &Session, records: Value) -> Value {
    json!({
        "sessionId": session.id,
        "createdAt": session.meta().created_at,
        "afterSeq": session.seq.load(Ordering::SeqCst),
        "records": records,
    })
}

fn words(text: &str) -> Value {
    json!([{"type": "text", "text": text}])
}

/// What a chat's waiting prompt reads after a restore whose records edited it: its preview, and
/// whether it kept its entry's withdraw handle (the task that runs it waits on that one).
async fn edited_by_a_restore(at_91b: bool) -> (String, bool) {
    let (hub, session) = hub_with_chat(at_91b).await;
    hub.append(
        &session,
        "mux",
        "queued",
        json!({"promptId": "p1", "turnId": "t1", "text": "old words", "prompt": words("old words")}),
    );
    hub.restore_queue(&session);
    let withdraw = session.queue.lock().unwrap()[0].withdraw.clone();
    let last = session.seq.load(Ordering::SeqCst);
    let edit = json!([{"seq": last + 1, "at": 1, "dir": "mux", "kind": "queue_updated",
                       "msg": {"promptId": "p1", "turnId": "t1", "text": "new words",
                               "prompt": words("new words"), "revision": 1}}]);
    hub.journal_restore(&restore_params(&session, edit)).await.unwrap();
    let queue = session.queue.lock().unwrap();
    assert_eq!(queue.len(), 1);
    (queue[0].preview.clone(), Arc::ptr_eq(&queue[0].withdraw, &withdraw))
}

/// Review of #37284 at 91b1343d, F3: a prompt that waited on the machine and that the restored
/// records edited keeps its entry's handles (its task stays its only runner) and takes the
/// rebuilt content. Under 91b1343d's rules the old entry came back whole, with the old words.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restore_that_edits_a_waiting_prompt_keeps_the_edit_and_the_task() {
    assert_eq!(edited_by_a_restore(true).await, ("old words".to_owned(), true));
    assert_eq!(edited_by_a_restore(false).await, ("new words".to_owned(), true));
}

/// A chat whose log a deferred start has not read, cut mid-turn (its `turn_started` with no
/// result), restored with the rest of that turn: the restore's answer, and whether the log then
/// holds an unknown outcome.
async fn mid_turn_restore(at_91b: bool) -> (Result<Value, RpcError>, bool) {
    let (hub, session) = hub_with_chat(at_91b).await;
    hub.append(&session, "mux", "turn_started", json!({"turnId": "t1", "promptId": "p1"}));
    *session.log_load.lock().unwrap() = false;
    session.log_loaded.store(false, Ordering::SeqCst);
    let last = session.seq.load(Ordering::SeqCst);
    let rest = json!([
        {"seq": last + 1, "at": 1, "dir": "in", "kind": "agent_message_chunk", "msg": {"text": "done"}},
        {"seq": last + 2, "at": 2, "dir": "mux", "kind": "turn_result",
         "msg": {"turnId": "t1", "promptId": "p1", "status": "ok"}},
    ]);
    let answer = hub.journal_restore(&restore_params(&session, rest)).await;
    let unknown = hub
        .events(&session.id, 0, 10_000)
        .unwrap()
        .iter()
        .any(|e| e.msg.get("detail").and_then(Value::as_str) == Some("outcome_unknown"));
    (answer, unknown)
}

/// Review of #37284 at 91b1343d, F4: a restore that reads a deferred chat's log reads it without
/// its recovery writes, puts its records in, then recovers on the result: the turn the records
/// end is not marked cut. Under 91b1343d's rules the load wrote the cut turn's continuation and
/// unknown outcome in the seqs the records needed, and the restore was refused as another
/// history (the owner then dropped its copy).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restore_into_a_deferred_log_cut_mid_turn_goes_in_before_its_recovery() {
    let (answer, _) = mid_turn_restore(true).await;
    let reason = answer.unwrap_err().data.and_then(|d| d.get("reason").cloned());
    assert_eq!(reason, Some(json!("diverged")), "91b1343d diverged on its own recovery");
    let (answer, unknown) = mid_turn_restore(false).await;
    assert!(answer.is_ok(), "{answer:?}");
    assert!(!unknown, "the restored turn was marked cut");
}

/// Whether a prompt that waited in the queue before a restore began takes the turn while the
/// restore holds the chat between tries (`restoring` set, the turn lock free).
async fn runs_during_a_hold(at_91b: bool) -> bool {
    let (hub, session) = hub_with_chat(at_91b).await;
    session.restoring.store(true, Ordering::SeqCst);
    let withdraw = tokio::sync::Notify::new();
    let ran = matches!(
        tokio::time::timeout(Duration::from_millis(300), hub.queue_turn(&session, "t1", &withdraw))
            .await,
        Ok(super::queue::Wait::Turn(_))
    );
    if !ran {
        // The hold ends (`release`): it goes on.
        let waited = {
            let (hub, session) = (hub.clone(), session.clone());
            tokio::spawn(async move {
                let withdraw = tokio::sync::Notify::new();
                matches!(
                    hub.queue_turn(&session, "t1", &withdraw).await,
                    super::queue::Wait::Turn(_)
                )
            })
        };
        tokio::time::sleep(Duration::from_millis(100)).await;
        session.restoring.store(false, Ordering::SeqCst);
        session.restore_done.notify_waiters();
        let after =
            tokio::time::timeout(Duration::from_secs(5), waited).await.expect("it never went on");
        assert!(after.unwrap(), "it did not take the turn once the hold ended");
    }
    ran
}

/// Review of #37284 at 91b1343d, F2: a prompt that already waited takes no turn while a restore
/// holds the chat, between its tries too, and goes on once the hold ends. Under 91b1343d's
/// rules it took the turn lock the hold left free and wrote into the seqs the restore needed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_waiting_prompt_takes_no_turn_while_a_restore_holds_the_chat() {
    assert!(runs_during_a_hold(true).await, "91b1343d ran it");
    assert!(!runs_during_a_hold(false).await);
}
