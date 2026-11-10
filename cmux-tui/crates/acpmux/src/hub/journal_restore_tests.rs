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
    hub_at(if at_91b { super::journal_restore::AT_91B } else { 0 }).await
}

/// A hub on a memory store, with one chat, replaying the rules `rules` (0: now).
async fn hub_at(rules: u8) -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.old_rules.store(rules, Ordering::SeqCst);
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

use super::journal_restore::AT_4DCB;

fn chunk(seq: u64, at: u64) -> Value {
    json!({"seq": seq, "at": at, "dir": "in", "kind": "agent_message_chunk", "msg": {"text": format!("line {seq}")}})
}

/// A restore of three records that stops after its second, a status appended during its hold,
/// then the owner's next try: its answer, and the journal's kinds past where it began.
async fn a_write_during_a_hold(rules: u8) -> (Result<Value, RpcError>, Vec<String>) {
    let (hub, session) = hub_at(rules).await;
    let last = session.seq.load(Ordering::SeqCst);
    let records = json!([chunk(last + 1, 1), chunk(last + 2, 2), chunk(last + 3, 3)]);
    let params = restore_params(&session, records);
    super::journal_restore::fail_once_after_first_record(&session.id);
    let first = hub.journal_restore(&params).await;
    let reason = first.unwrap_err().data.and_then(|d| d.get("reason").cloned());
    assert_eq!(reason, Some(json!("append_failed")));
    // Something of the chat's own while the restore holds it: an agent's update between turns.
    hub.append(&session, "mux", "status", json!({"status": "idle", "detail": "between tries"}));
    let again = hub.journal_restore(&params).await;
    let kinds =
        hub.events(&session.id, last, 100).unwrap().iter().map(|e| e.kind.clone()).collect();
    (again, kinds)
}

/// Review of #37284 at 4dcbe192, F1 to F3 (the class): a record appended while a restore owns the
/// chat, between its tries too, takes no seq until the restore ends: the next try goes in and the
/// record follows it. Under 4dcbe192's rules it took the seq the next try needed, which then
/// diverged (and the owner dropped its copy).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_record_written_while_a_restore_holds_the_chat_waits_for_it() {
    let (again, _) = a_write_during_a_hold(AT_4DCB).await;
    let reason = again.unwrap_err().data.and_then(|d| d.get("reason").cloned());
    assert_eq!(reason, Some(json!("diverged")), "4dcbe192 let the status take the restore's seq");
    let (again, kinds) = a_write_during_a_hold(0).await;
    assert!(again.is_ok(), "{again:?}");
    let chunks = kinds.iter().take(3).all(|k| k == "agent_message_chunk");
    assert!(chunks && kinds.get(3).map(String::as_str) == Some("status"), "{kinds:?}");
}

/// A chat cut mid-turn whose log a restart reads before its owner reconnects: the recovery writes
/// the turn's unknown outcome (and its continuation). Then the owner gives back the rest of that
/// turn after `afterSeq` (where the turn was cut, or where the journal ends now). The answers, and
/// whether the log holds an unknown outcome at the end.
async fn recovered_then_restored(rules: u8, after_end: bool) -> (Result<Value, RpcError>, bool) {
    let (hub, session) = hub_at(rules).await;
    hub.append(&session, "mux", "turn_started", json!({"turnId": "t1", "promptId": "p1"}));
    let cut = session.seq.load(Ordering::SeqCst);
    *session.log_load.lock().unwrap() = false;
    session.log_loaded.store(false, Ordering::SeqCst);
    hub.load_session_log(&session);
    let end = session.seq.load(Ordering::SeqCst);
    assert!(end > cut, "the restart's recovery wrote nothing");
    let rest = json!([
        {"seq": cut + 1, "at": 1, "dir": "in", "kind": "agent_message_chunk", "msg": {"text": "done"}},
        {"seq": cut + 2, "at": 2, "dir": "mux", "kind": "turn_result",
         "msg": {"turnId": "t1", "promptId": "p1", "status": "ok"}},
        {"seq": end + 3, "at": 3, "dir": "in", "kind": "agent_message_chunk", "msg": {"text": "after"}},
    ]);
    let mut params = restore_params(&session, rest.clone());
    params["afterSeq"] = json!(if after_end { end } else { cut });
    if after_end {
        // The owner sends only what is past the journal's end, as the row reads it.
        params["records"] = json!([rest[2].clone()]);
    }
    let mut answer = hub.journal_restore(&params).await;
    // Refused as recovered: the owner sends the copy again from where the recovery began.
    if let Err(e) = &answer
        && let Some(from) = e.data.as_ref().and_then(|d| d.get("afterSeq")).and_then(Value::as_u64)
        && e.data.as_ref().and_then(|d| d.get("reason")) == Some(&json!("recovered"))
    {
        assert_eq!(from, cut);
        params["afterSeq"] = json!(from);
        params["records"] = rest;
        answer = hub.journal_restore(&params).await;
    }
    let events = hub.events(&session.id, 0, 10_000).unwrap();
    let unknown = events
        .iter()
        .any(|e| e.msg.get("detail").and_then(Value::as_str) == Some("outcome_unknown"));
    if answer.is_ok() && rules == 0 {
        let at = |seq: u64| events.iter().find(|e| e.seq == seq).map(|e| e.kind.clone());
        assert_eq!(
            at(cut + 2).as_deref(),
            Some("turn_result"),
            "the original seqs hold the copy's records"
        );
    }
    (answer, unknown)
}

/// Review of #37284 at 4dcbe192, F1: a mid-turn snapshot whose log loads before its owner
/// reconnects. The recovery's records go, the copy's go in at their own seqs, and the recovery
/// is made again on the restored log (the turn ended: no unknown outcome). The owner that names
/// where the journal ends now is told where the recovery began. Under 4dcbe192's rules the
/// restore diverged on the recovery's records, or (after the journal's end) went in behind them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restore_after_a_restarts_recovery_takes_its_seqs_back() {
    let (answer, _) = recovered_then_restored(AT_4DCB, false).await;
    let reason = answer.unwrap_err().data.and_then(|d| d.get("reason").cloned());
    assert_eq!(reason, Some(json!("diverged")), "4dcbe192 diverged on its own recovery");
    let (answer, unknown) = recovered_then_restored(AT_4DCB, true).await;
    assert!(answer.is_ok() && unknown, "4dcbe192 kept the recovery in the original seqs");
    for after_end in [false, true] {
        let (answer, unknown) = recovered_then_restored(0, after_end).await;
        assert!(answer.is_ok(), "{answer:?}");
        assert!(!unknown, "the recovery was not made again on the restored log");
    }
}

/// Whether a prompt admitted before a restore took the turn lock runs while the restore holds
/// the chat between tries.
async fn admitted_before_the_lock_runs(rules: u8) -> bool {
    let (hub, session) = hub_at(rules).await;
    let lock = session.turn_lock.lock().await;
    let prompt = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            hub.prompt(&session, vec![json!({"type": "text", "text": "x"})], "test", false).await
        })
    };
    tokio::time::sleep(Duration::from_millis(300)).await;
    // The restore: it holds the chat, then stops short, leaving its hold.
    session.restoring.store(true, Ordering::SeqCst);
    hub.park_writes(&session, 77);
    drop(lock);
    tokio::time::sleep(Duration::from_millis(500)).await;
    let ran = hub.events(&session.id, 0, 10_000).unwrap().iter().any(|e| e.kind == "user_message");
    // The hold ends: it goes on.
    session.restoring.store(false, Ordering::SeqCst);
    hub.unpark_writes(&session);
    session.restore_done.notify_waiters();
    let answer = tokio::time::timeout(Duration::from_secs(30), prompt).await.unwrap().unwrap();
    assert!(answer.is_ok(), "{answer:?}");
    ran
}

/// Review of #37284 at 4dcbe192, F3: a prompt admitted before the restore, waiting for the turn
/// lock, takes no turn while the restore holds the chat, and runs once it ends. Under 4dcbe192's
/// rules it ran into the seqs the restore's next try needed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_prompt_admitted_before_a_restore_waits_for_its_hold() {
    assert!(admitted_before_the_lock_runs(AT_4DCB).await, "4dcbe192 ran it");
    assert!(!admitted_before_the_lock_runs(0).await);
}

/// A `queued` record at `seq` of a prompt saved with the file at `path`, held, so it waits.
fn queued_with_file(seq: u64, path: &Path) -> Value {
    let link = json!({"type": "resource_link", "uri": format!("file://{}", path.display()), "name": "notes.txt"});
    json!({"seq": seq, "at": 1, "dir": "mux", "kind": "queued",
           "msg": {"promptId": "pf", "turnId": "tf", "text": "see the notes", "held": true,
                   "prompt": [link]}})
}

/// Review of #37284 at 4dcbe192, F4: a restore brings back the files its prompts were saved as,
/// in the chat's own uploads, and the owner's check reads them held; a path outside them is
/// refused.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restore_writes_its_prompts_files_back() {
    use base64::Engine as _;
    let (hub, session) = hub_at(0).await;
    let dir = super::file_uploads::session_dir(&session.id).unwrap().join("019a-upload");
    let path = dir.join("notes.txt");
    let bytes = b"the notes".to_vec();
    let held =
        |hash: String| json!({"sessionId": session.id, "files": [{"path": path, "sha256": hash}]});
    let answer = hub.attachments_held(&held(crate::attach::sha256(&bytes))).await.unwrap();
    assert_eq!(answer["held"], json!(false));
    let last = session.seq.load(Ordering::SeqCst);
    let mut params = restore_params(&session, json!([queued_with_file(last + 1, &path)]));
    params["files"] =
        json!([{"path": path, "data": base64::engine::general_purpose::STANDARD.encode(&bytes)}]);
    hub.journal_restore(&params).await.unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    let answer = hub.attachments_held(&held(crate::attach::sha256(&bytes))).await.unwrap();
    assert_eq!(answer["held"], json!(true));
    let answer = hub.attachments_held(&held(crate::attach::sha256(b"other"))).await.unwrap();
    assert_eq!(answer["held"], json!(false));
    let mut outside = restore_params(&session, json!([]));
    outside["files"] = json!([{"path": "/tmp/../etc/x", "data": ""}]);
    assert!(hub.journal_restore(&outside).await.is_err());
    let _ = std::fs::remove_dir_all(dir);
}

/// A memory store whose append refuses the records naming `detail` "kept" while `fail` is set.
struct RefusingStore {
    inner: Box<dyn crate::store::Store>,
    fail: Arc<std::sync::atomic::AtomicBool>,
}

impl crate::store::Store for RefusingStore {
    fn list(&self) -> anyhow::Result<Vec<crate::store::SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<crate::store::SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &crate::store::SessionMeta) -> anyhow::Result<()> {
        self.inner.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
        // And a queue's edit or removal (`edits_the_disk_refuses`).
        let kept = record.msg.get("detail") == Some(&json!("kept"))
            || matches!(record.kind.as_str(), "queue_updated" | "queue_removed");
        anyhow::ensure!(!(kept && self.fail.load(Ordering::SeqCst)), "test: the disk refuses it");
        self.inner.append(id, record)
    }
    fn flush_session(&self, id: &str) -> anyhow::Result<()> {
        self.inner.flush_session(id)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
        self.inner.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
}

/// A record kept while a restore owns the chat, refused by the disk when the restore ends, then
/// the chat's next record: whether its caller heard the kept one stored, and the `detail` of
/// each `status` past where it began, in order.
async fn a_kept_record_the_disk_refuses(rules: u8) -> (bool, Vec<String>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let inner = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let fail = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let hub = Hub::new(cfg, Box::new(RefusingStore { inner, fail: fail.clone() }));
    hub.replay_rules(rules);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    let last = session.seq.load(Ordering::SeqCst);
    hub.park_writes(&session, 7);
    let kept = json!({"status": "idle", "detail": "kept"});
    let (_, stored) = hub.append_logged(&session, "mux", "status", kept, None);
    fail.store(true, Ordering::SeqCst);
    hub.unpark_writes(&session);
    fail.store(false, Ordering::SeqCst);
    hub.append(&session, "mux", "status", json!({"status": "idle", "detail": "after"}));
    let details = hub
        .events(&session.id, last, 100)
        .unwrap()
        .iter()
        .filter_map(|e| e.msg.get("detail").and_then(Value::as_str).map(str::to_owned))
        .filter(|d| d == "kept" || d == "after")
        .collect();
    (stored, details)
}

/// Review of #37284 at c4a6f4e7, F1: a record kept while a restore owns the chat is not stored
/// until it is in, and its caller hears so; the disk refusing it when the restore ends keeps it,
/// and it goes in first at the chat's next append. Under c4a6f4e7's rules its caller heard it
/// stored, and it was lost.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_record_kept_during_a_restore_is_stored_before_it_is_told_stored() {
    let (stored, details) = a_kept_record_the_disk_refuses(super::journal_restore::AT_C4A6).await;
    assert!(stored, "c4a6f4e7 told it stored");
    assert_eq!(details, vec!["after"], "c4a6f4e7 lost it");
    let (stored, details) = a_kept_record_the_disk_refuses(0).await;
    assert!(!stored, "told stored before it was in");
    assert_eq!(details, vec!["kept", "after"]);
}

/// A chat whose journal ends with 300 records of its own recovery (one per open subagent, say),
/// past `last`, then the owner's restore of two records after `last`: its answer, and the kinds
/// of the journal's first two records past `last`.
async fn a_restore_past_a_long_recovery(rules: u8) -> (Result<Value, RpcError>, Vec<String>) {
    let (hub, session) = hub_at(rules).await;
    let last = session.seq.load(Ordering::SeqCst);
    {
        let _recovering = super::restore_writer::Recovering::start();
        for n in 0..300 {
            hub.append(&session, "mux", "status", json!({"status": "idle", "recovered": n}));
        }
    }
    let params = json!({
        "sessionId": session.id,
        "createdAt": session.meta().created_at,
        "afterSeq": last,
        "records": [chunk(last + 1, 1), chunk(last + 2, 2)],
    });
    let answer = hub.journal_restore(&params).await;
    let kinds = hub.events(&session.id, last, 2).unwrap().iter().map(|e| e.kind.clone()).collect();
    (answer, kinds)
}

/// Review of #37284 at c4a6f4e7, F2: the machine's own recovery at its journal's end is read
/// whole, however long: a restore takes all of it back and its records go in at their seqs.
/// Under c4a6f4e7's rules only the last 256 records were read: the restore found the recovery
/// beginning past the copy's records and diverged on the rest of it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restore_takes_back_a_recovery_longer_than_a_page() {
    let (answer, _) = a_restore_past_a_long_recovery(super::journal_restore::AT_C4A6).await;
    let reason = answer.unwrap_err().data.and_then(|d| d.get("reason").cloned());
    assert_eq!(reason, Some(json!("diverged")), "c4a6f4e7 read 256 records of it");
    let (answer, kinds) = a_restore_past_a_long_recovery(0).await;
    assert!(answer.is_ok(), "{answer:?}");
    assert_eq!(kinds, vec!["agent_message_chunk", "agent_message_chunk"]);
}

/// A file the machine saved and then changed, and a restore whose records diverge from the
/// machine's journal and name that file: the file's bytes after the restore was refused.
async fn a_changed_file_after_a_diverged_restore(rules: u8) -> Vec<u8> {
    use base64::Engine as _;
    let (hub, session) = hub_at(rules).await;
    let dir = super::file_uploads::session_dir(&session.id).unwrap().join("019a-changed");
    let path = dir.join("notes.txt");
    crate::config::private_state_dir(dir.parent().unwrap()).unwrap();
    crate::config::private_state_dir(&dir).unwrap();
    std::fs::write(&path, b"the machine's edit").unwrap();
    let last = session.seq.load(Ordering::SeqCst);
    // The machine's own record where the copy has another.
    hub.append(&session, "mux", "status", json!({"status": "idle", "detail": "its own"}));
    let params = json!({
        "sessionId": session.id,
        "createdAt": session.meta().created_at,
        "afterSeq": last,
        "records": [chunk(last + 1, 1), queued_with_file(last + 2, &path)],
        "files": [{"path": path,
                   "data": base64::engine::general_purpose::STANDARD.encode(b"the owner's bytes")}],
    });
    let answer = hub.journal_restore(&params).await;
    let reason = answer.unwrap_err().data.and_then(|d| d.get("reason").cloned());
    assert_eq!(reason, Some(json!("diverged")));
    let held = std::fs::read(&path).unwrap();
    let _ = std::fs::remove_dir_all(dir);
    held
}

/// Review of #37284 at ff3da306, F2: a restore changes nothing on disk until it has decided to
/// go ahead, and never writes over a file the machine holds: a diverged one leaves the file the
/// machine changed as it is. Under ff3da306's rules the owner's bytes went over it first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_diverged_restore_leaves_the_machines_files_as_they_are() {
    let old = a_changed_file_after_a_diverged_restore(super::journal_restore::AT_FF3D).await;
    assert_eq!(old, b"the owner's bytes".to_vec(), "ff3da306 wrote over it");
    let now = a_changed_file_after_a_diverged_restore(0).await;
    assert_eq!(now, b"the machine's edit".to_vec());
}

/// Two prompts waiting on the machine; a restore that stops short; while it holds the chat, the
/// first is edited and the second removed; then the owner's next try: each waiting prompt's id
/// and preview after it.
async fn edits_during_a_restores_hold(rules: u8) -> Vec<(String, String)> {
    let (hub, session) = hub_at(rules).await;
    for p in ["p1", "p2"] {
        let text = format!("{p} old words");
        hub.append(
            &session,
            "mux",
            "queued",
            json!({"promptId": p, "turnId": format!("t-{p}"), "text": text, "prompt": words(&text),
                   "held": true}),
        );
    }
    hub.restore_queue(&session);
    let last = session.seq.load(Ordering::SeqCst);
    let records = json!([chunk(last + 1, 1), chunk(last + 2, 2), chunk(last + 3, 3)]);
    let params = restore_params(&session, records);
    super::journal_restore::fail_once_after_first_record(&session.id);
    let first = hub.journal_restore(&params).await;
    let reason = first.unwrap_err().data.and_then(|d| d.get("reason").cloned());
    assert_eq!(reason, Some(json!("append_failed")));
    let edit = json!({"sessionId": session.id, "promptId": "p1", "op": "update",
                      "text": "p1 new words"});
    let edited = hub.queue_edit(&session, &edit, Control::Local, false, None).await.unwrap();
    assert_eq!(edited["ok"], json!(true), "{edited}");
    assert!(hub.remove_queued(&session, "p2"));
    hub.journal_restore(&params).await.unwrap();
    let queue = session.queue.lock().unwrap();
    queue.iter().map(|q| (q.prompt_id.clone(), q.preview.clone())).collect()
}

/// Review of #37284 at ff3da306, F1: what was written while a restore held the chat is in the
/// journal before the queue is rebuilt from it: an edit and a removal answered meanwhile stand.
/// Under ff3da306's rules the rebuild read the journal without them: the old words came back,
/// and the removed prompt waited again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_queue_edited_during_a_restores_hold_keeps_the_edits() {
    let old = edits_during_a_restores_hold(super::journal_restore::AT_FF3D).await;
    assert_ne!(old, vec![("p1".to_owned(), "p1 new words".to_owned())], "ff3da306 kept them");
    let now = edits_during_a_restores_hold(0).await;
    assert_eq!(now, vec![("p1".to_owned(), "p1 new words".to_owned())]);
}

/// Two prompts waiting on the machine; a restore whose settle, once it wrote what parked and
/// before it rebuilt the queue, sees the first edited and the second removed by another thread:
/// each waiting prompt's id and preview after it.
async fn changes_right_after_the_drain(rules: u8) -> Vec<(String, String)> {
    let (hub, session) = hub_at(rules).await;
    for p in ["p1", "p2"] {
        let text = format!("{p} old words");
        hub.append(
            &session,
            "mux",
            "queued",
            json!({"promptId": p, "turnId": format!("t-{p}"), "text": text, "prompt": words(&text),
                   "held": true}),
        );
    }
    hub.restore_queue(&session);
    let last = session.seq.load(Ordering::SeqCst);
    let params = restore_params(&session, json!([chunk(last + 1, 1)]));
    let (h, s, rt) = (hub.clone(), session.clone(), tokio::runtime::Handle::current());
    super::journal_restore::after_drain_once(
        &session.id,
        Box::new(move || {
            let edit = json!({"sessionId": s.id, "promptId": "p1", "op": "update",
                              "text": "p1 new words"});
            let edited = rt.block_on(h.queue_edit(&s, &edit, Control::Local, false, None)).unwrap();
            assert_eq!(edited["ok"], json!(true), "{edited}");
            assert!(h.remove_queued(&s, "p2"));
        }),
    );
    hub.journal_restore(&params).await.unwrap();
    let queue = session.queue.lock().unwrap();
    queue.iter().map(|q| (q.prompt_id.clone(), q.preview.clone())).collect()
}

/// Review of #37284 at 07f76930, F1: an edit and a removal that land after the settle wrote
/// what parked, and before it rebuilt the queue, stand: each change logs its record under the
/// queue's lock, and the settle rebuilds again with every change that parked meanwhile. Under
/// 07f76930's rules the rebuild read the journal without them: the old words came back, and the
/// removed prompt waited again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_queue_change_between_the_drain_and_the_rebuild_stands() {
    let old = changes_right_after_the_drain(super::journal_restore::AT_07F7).await;
    assert_ne!(old, vec![("p1".to_owned(), "p1 new words".to_owned())], "07f76930 kept them");
    let now = changes_right_after_the_drain(0).await;
    assert_eq!(now, vec![("p1".to_owned(), "p1 new words".to_owned())]);
}

/// Two prompts waiting on a machine whose disk refuses queue edits for a while; a restore that
/// stops short; meanwhile the first is edited and the second removed, and the disk refuses both
/// records; then the owner's next tries: whether the first of them succeeded, and each waiting
/// prompt's id and preview once one did.
async fn edits_the_disk_refuses(rules: u8) -> (bool, Vec<(String, String)>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let inner = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let fail = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let hub = Hub::new(cfg, Box::new(RefusingStore { inner, fail: fail.clone() }));
    hub.replay_rules(rules);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    for p in ["p1", "p2"] {
        let text = format!("{p} old words");
        hub.append(
            &session,
            "mux",
            "queued",
            json!({"promptId": p, "turnId": format!("t-{p}"), "text": text, "prompt": words(&text),
                   "held": true}),
        );
    }
    hub.restore_queue(&session);
    let last = session.seq.load(Ordering::SeqCst);
    let records = json!([chunk(last + 1, 1), chunk(last + 2, 2), chunk(last + 3, 3)]);
    let params = restore_params(&session, records);
    super::journal_restore::fail_once_after_first_record(&session.id);
    assert!(hub.journal_restore(&params).await.is_err());
    fail.store(true, Ordering::SeqCst);
    let edit = json!({"sessionId": session.id, "promptId": "p1", "op": "update",
                      "text": "p1 new words"});
    let edited = hub.queue_edit(&session, &edit, Control::Local, false, None).await.unwrap();
    assert_eq!(edited["ok"], json!(true), "{edited}");
    assert!(hub.remove_queued(&session, "p2"));
    let second = hub.journal_restore(&params).await;
    fail.store(false, Ordering::SeqCst);
    if let Err(e) = &second {
        let reason = e.data.as_ref().and_then(|d| d.get("reason"));
        assert_eq!(reason, Some(&json!("append_failed")));
        hub.journal_restore(&params).await.unwrap();
    }
    let queue = session.queue.lock().unwrap();
    (second.is_ok(), queue.iter().map(|q| (q.prompt_id.clone(), q.preview.clone())).collect())
}

/// Review of #37284 at a088585e, F1: a queue edit and a removal made while a restore holds the
/// chat, whose records the disk refuses as the restore settles, are not lost: that try fails
/// (`append_failed`) and the chat stays held, and a rebuild reads the records not stored yet
/// after the journal. Under a088585e's rules the try went on as if they were in, and the rebuilt
/// queue had the old words and the removed prompt again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_queue_edit_the_disk_refuses_during_a_restore_is_not_lost() {
    let (went_on, old) = edits_the_disk_refuses(super::journal_restore::AT_A088).await;
    assert!(went_on, "a088585e went on");
    assert_ne!(old, vec![("p1".to_owned(), "p1 new words".to_owned())], "a088585e kept them");
    let (went_on, now) = edits_the_disk_refuses(0).await;
    assert!(!went_on, "the try that could not store them went on");
    assert_eq!(now, vec![("p1".to_owned(), "p1 new words".to_owned())]);
}

/// Review of #37284 at a088585e, F2: a restore that brings a prompt's records naming its images
/// writes the images back where the machine keeps them, checked against their ids, and the
/// machine then says it holds them (`attachments_held`).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restore_writes_its_prompts_images_back() {
    use base64::Engine as _;
    let (hub, session) = hub_at(0).await;
    let bytes = b"\x89PNG\r\n\x1a\n a restored image".to_vec();
    let id = crate::attach::sha256(&bytes);
    let path = super::prompt_images::image_path(&id).unwrap();
    let _ = std::fs::remove_file(&path);
    let held = json!({"sessionId": session.id, "files": [], "images": [id]});
    assert_eq!(hub.attachments_held(&held).await.unwrap()["held"], json!(false));
    let last = session.seq.load(Ordering::SeqCst);
    let message = json!({"seq": last + 1, "at": 1, "dir": "mux", "kind": "user_message",
                         "msg": {"promptId": "pi", "turnId": "ti", "text": "look",
                                 "images": [{"id": id, "mimeType": "image/png"}]}});
    let mut params = restore_params(&session, json!([message]));
    let data = base64::engine::general_purpose::STANDARD.encode(&bytes);
    // Bytes that are not the image the id names are refused.
    params["files"] =
        json!([{"image": id, "data": base64::engine::general_purpose::STANDARD.encode(b"other")}]);
    assert!(hub.journal_restore(&params).await.is_err());
    params["files"] = json!([{"image": id, "data": data}]);
    hub.journal_restore(&params).await.unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    assert_eq!(hub.attachments_held(&held).await.unwrap()["held"], json!(true));
    let _ = std::fs::remove_file(&path);
}

/// Review of #37284 at 77f91e5a, F1: the machine says it holds a prompt's upload only when the
/// chat has that finished upload, which its prompt reads at its turn (`prompt_uploads.rs`).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_machine_holds_an_upload_only_once_it_is_finished_there() {
    let (hub, session) = hub_at(0).await;
    let id = "019a0000-0000-7000-8000-000000000003";
    let held = json!({"sessionId": session.id, "files": [],
                      "uploads": [{"uploadId": id, "fileName": "big.log"}]});
    assert_eq!(hub.attachments_held(&held).await.unwrap()["held"], json!(false));
    let path = super::file_uploads::finished_path(&session.id, id, "big.log").unwrap();
    let dir = path.parent().unwrap();
    crate::config::private_state_dir(dir.parent().unwrap()).unwrap();
    crate::config::private_state_dir(dir).unwrap();
    crate::agent_tools::write_private(&path, b"a log").unwrap();
    assert_eq!(hub.attachments_held(&held).await.unwrap()["held"], json!(true));
    let other = json!({"sessionId": session.id, "files": [],
                       "uploads": [{"uploadId": "../x", "fileName": "big.log"}]});
    assert!(hub.attachments_held(&other).await.is_err());
}

/// A memory store that a crash stops: from `crashed` on it writes nothing, as a daemon killed
/// then writes nothing, and a hub opened on the same `inner` reads what it held then.
struct CrashingStore {
    inner: Arc<dyn crate::store::Store>,
    crashed: Arc<std::sync::atomic::AtomicBool>,
}

impl CrashingStore {
    fn alive(&self) -> anyhow::Result<()> {
        anyhow::ensure!(!self.crashed.load(Ordering::SeqCst), "test: the daemon crashed");
        Ok(())
    }
}

impl crate::store::Store for CrashingStore {
    fn list(&self) -> anyhow::Result<Vec<crate::store::SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<crate::store::SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &crate::store::SessionMeta) -> anyhow::Result<()> {
        self.alive()?;
        self.inner.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
        self.alive()?;
        self.inner.append(id, record)
    }
    fn flush_session(&self, id: &str) -> anyhow::Result<()> {
        self.alive()?;
        self.inner.flush_session(id)
    }
    fn truncate_after(&self, id: &str, after: u64) -> anyhow::Result<bool> {
        self.alive()?;
        self.inner.truncate_after(id, after)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
        self.inner.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.alive()?;
        self.inner.delete(id)
    }
}

/// A hub on `inner` through a [`CrashingStore`], replaying the rules `rules` (0: now).
fn crashing_hub(
    inner: &Arc<dyn crate::store::Store>,
    rules: u8,
) -> (Arc<Hub>, Arc<std::sync::atomic::AtomicBool>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let crashed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let store = CrashingStore { inner: inner.clone(), crashed: crashed.clone() };
    let hub = Hub::new(cfg, Box::new(store));
    hub.replay_rules(rules);
    (hub, crashed)
}

/// What a restart after a crash inside a restore makes of the chat. A chat cut mid-turn whose
/// log a restart read: its recovery ends the journal, and its end is saved. The owner's copy
/// ends the turn (`turn_result`), queues a prompt and goes on past the recovery's end; the
/// daemon crashes once the restore took the recovery back and put the copy's first record in.
/// After the next start the owner sends what its copy holds past the `lastSeq` the chat says, as
/// its row reads it. The `lastSeq` the restarted chat said, the journal's end then, and at the
/// end whether the journal holds every seq of the copy, and the copy's queued prompt.
async fn crashed_between_records(rules: u8) -> (u64, u64, bool, bool) {
    let inner: Arc<dyn crate::store::Store> = Arc::new(crate::store::MemoryStore::default());
    let (hub, crashed) = crashing_hub(&inner, rules);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    hub.append(&session, "mux", "turn_started", json!({"turnId": "t1", "promptId": "p1"}));
    let cut = session.seq.load(Ordering::SeqCst);
    *session.log_load.lock().unwrap() = false;
    session.log_loaded.store(false, Ordering::SeqCst);
    hub.load_session_log(&session);
    // The recovery's end on disk, as its own save, or any later one, leaves it.
    hub.save_meta_answered(&session).unwrap();
    let end = session.seq.load(Ordering::SeqCst);
    assert!(end > cut + 1, "the restart's recovery wrote fewer than two records");
    let mut copy = vec![
        json!({"seq": cut + 1, "at": 1, "dir": "mux", "kind": "turn_result",
               "msg": {"turnId": "t1", "promptId": "p1", "status": "ok"}}),
        json!({"seq": cut + 2, "at": 2, "dir": "mux", "kind": "queued",
               "msg": {"promptId": "p2", "turnId": "t2", "text": "next", "prompt": words("next")}}),
    ];
    copy.extend((cut + 3..=end + 2).map(|seq| chunk(seq, seq)));
    let mut params = restore_params(&session, Value::from(copy.clone()));
    params["afterSeq"] = json!(cut);
    let id = session.id.clone();
    let stop = crashed.clone();
    super::journal_restore::between_records_once(
        &id,
        Box::new(move || stop.store(true, Ordering::SeqCst)),
    );
    let first = hub.journal_restore(&params).await;
    assert!(first.is_err(), "the crash did not stop the restore: {first:?}");
    assert!(crashed.load(Ordering::SeqCst), "it never reached its second record");
    // The next start, on what the store held at the crash.
    let (hub, _) = crashing_hub(&inner, rules);
    let meta = inner.load(&id).unwrap().expect("the chat is gone");
    hub.install_stored_session(meta, false, false);
    let session = hub.sessions.lock().unwrap().get(&id).cloned().unwrap();
    hub.load_session_log(&session);
    let said = session.meta().last_seq;
    let real = hub.events(&id, 0, 10_000).unwrap().last().map_or(0, |e| e.seq);
    // The owner gives back what its copy holds past the end the chat says.
    let past: Vec<Value> =
        copy.iter().filter(|r| r["seq"].as_u64().is_some_and(|s| s > said)).cloned().collect();
    let mut again = restore_params(&session, Value::from(past));
    again["afterSeq"] = json!(said);
    hub.journal_restore(&again).await.unwrap();
    let events = hub.events(&id, cut, 10_000).unwrap();
    // Through the copy's end: the prompt it queued may start its turn after the restore.
    let seqs: Vec<u64> = events.iter().map(|e| e.seq).filter(|s| *s <= end + 2).collect();
    let whole = seqs == (cut + 1..=end + 2).collect::<Vec<_>>();
    let queued =
        events.iter().any(|e| e.kind == "queued" && e.msg.get("promptId") == Some(&json!("p2")));
    (said, real, whole, queued)
}

/// Review of #37284 at 8b5f3063, F3: a restore that takes back the machine's recovery saves the
/// lowered end before it cuts, so a crash between the records it puts back leaves a saved end
/// the journal holds; the next start says the journal's own end, and the owner's next try fills
/// the rest, no record or prompt skipped. Under 8b5f3063's rules the end was lowered in memory
/// only: the next start said the recovery's end, past the journal's, and the owner sent only what
/// was past it, so the records between (the queued prompt among them) were lost for good.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_crash_between_restored_records_skips_no_record_after_a_restart() {
    let (said, real, whole, queued) =
        crashed_between_records(super::journal_restore::AT_8B5F).await;
    assert!(said > real, "8b5f3063 said the journal's own end: {said}, {real}");
    assert!(!whole && !queued, "8b5f3063 skipped nothing");
    let (said, real, whole, queued) = crashed_between_records(0).await;
    assert_eq!(said, real, "the restarted chat said an end past its journal's");
    assert!(whole, "a record of the copy is missing from the restored journal");
    assert!(queued, "the copy's queued prompt was skipped");
}

/// What the owner's retry makes of a chat whose restore's cut of the machine's recovery put the
/// shorter journal in place and then failed (its marker's write, `compact.rs`
/// `commit_compaction`), on a store on disk, replaying `rules`. A chat cut mid-turn whose log a
/// restart read: its recovery ends the journal. The owner's copy ends the turn, queues a prompt
/// and goes on past the recovery's end; the first try stops at the cut, and the owner sends what
/// its copy holds past the `lastSeq` that try answered. That `lastSeq`, the journal's end then,
/// and at the end whether the journal holds every seq of the copy, and the copy's queued prompt.
async fn cut_then_failed(rules: u8) -> (u64, u64, bool, bool) {
    let dir = std::env::temp_dir().join(format!("acpmux-cut-failed-{}", uuid::Uuid::now_v7()));
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dir).unwrap());
    hub.replay_rules(rules);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    hub.append(&session, "mux", "turn_started", json!({"turnId": "t1", "promptId": "p1"}));
    let cut = session.seq.load(Ordering::SeqCst);
    *session.log_load.lock().unwrap() = false;
    session.log_loaded.store(false, Ordering::SeqCst);
    hub.load_session_log(&session);
    hub.save_meta_answered(&session).unwrap();
    let end = session.seq.load(Ordering::SeqCst);
    assert!(end > cut + 1, "the restart's recovery wrote fewer than two records");
    let mut copy = vec![
        json!({"seq": cut + 1, "at": 1, "dir": "mux", "kind": "turn_result",
               "msg": {"turnId": "t1", "promptId": "p1", "status": "ok"}}),
        json!({"seq": cut + 2, "at": 2, "dir": "mux", "kind": "queued",
               "msg": {"promptId": "p2", "turnId": "t2", "text": "next", "prompt": words("next")}}),
    ];
    copy.extend((cut + 3..=end + 2).map(|seq| chunk(seq, seq)));
    let mut params = restore_params(&session, Value::from(copy.clone()));
    params["afterSeq"] = json!(cut);
    let id = session.id.clone();
    crate::store::fail_before_marker_once(&id);
    let first = hub.journal_restore(&params).await;
    let data = first.expect_err("the failed cut did not stop the try").data.unwrap_or_default();
    assert_eq!(data["reason"], "append_failed", "{data}");
    let said = data["lastSeq"].as_u64().expect("the try answers where the journal ends");
    let real = hub.events(&id, 0, 10_000).unwrap().last().map_or(0, |e| e.seq);
    // The owner gives back what its copy holds past the end the try answered.
    let past: Vec<Value> =
        copy.iter().filter(|r| r["seq"].as_u64().is_some_and(|s| s > said)).cloned().collect();
    let mut again = restore_params(&session, Value::from(past));
    again["afterSeq"] = json!(said);
    let answer = hub.journal_restore(&again).await;
    let events = hub.events(&id, cut, 10_000).unwrap();
    // Through the copy's end: the prompt it queued may start its turn after the restore.
    let seqs: Vec<u64> = events.iter().map(|e| e.seq).filter(|s| *s <= end + 2).collect();
    let whole = answer.is_ok() && seqs == (cut + 1..=end + 2).collect::<Vec<_>>();
    let queued =
        events.iter().any(|e| e.kind == "queued" && e.msg.get("promptId") == Some(&json!("p2")));
    drop(hub);
    let _ = std::fs::remove_dir_all(&dir);
    (said, real, whole, queued)
}

/// Review of #37284 at fd33a65b, F2: a cut that put the shorter journal in place and then failed
/// stops the try with the chat's end read back from its journal, so the owner's next try sends
/// from there and every record of its copy goes in, the queued prompt too. Under fd33a65b's rules
/// the try took the cut as undone and answered the recovery's old end, past the journal's: the
/// owner sent only what was past it, and the records between (the queued prompt among them) were
/// lost while the restore answered done.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cut_that_fails_after_it_shortened_the_journal_skips_no_record() {
    let (said, real, whole, queued) = cut_then_failed(super::journal_restore::AT_FD33).await;
    assert!(said > real, "fd33a65b answered the journal's own end: {said}, {real}");
    assert!(!whole && !queued, "fd33a65b skipped nothing");
    let (said, real, whole, queued) = cut_then_failed(0).await;
    assert_eq!(said, real, "the try answered an end past its journal's");
    assert!(whole, "a record of the copy is missing from the restored journal");
    assert!(queued, "the copy's queued prompt was skipped");
}

/// A chat cut mid-turn whose log a restart reads (a fresh machine on a disk taken mid-turn), and
/// an owner's copy that holds the rest of that turn, its end included, in `extra` more records
/// than the recovery wrote (0: just as many; it ends at the machine's `lastSeq`). Replaying
/// `rules`: where the owner's row says the copy goes back from (`restore.rs` `row_of`), the
/// restore of what the copy holds past it (None: nothing is past it, so none goes), whether the
/// log holds an unknown outcome then, whether it holds the copy's own turn result, how many
/// prompts wait in its queue, and the row's `recoveredAfter` after.
async fn a_recovery_as_long_as_the_copy(
    rules: u8,
    extra: u64,
) -> (u64, Option<Result<Value, RpcError>>, bool, bool, u64, Option<u64>) {
    let (hub, session) = hub_at(rules).await;
    hub.append(&session, "mux", "turn_started", json!({"turnId": "t1", "promptId": "p1"}));
    let cut = session.seq.load(Ordering::SeqCst);
    *session.log_load.lock().unwrap() = false;
    session.log_loaded.store(false, Ordering::SeqCst);
    hub.load_session_log(&session);
    let end = session.seq.load(Ordering::SeqCst);
    assert!(end > cut, "the restart's recovery wrote nothing");
    // The copy: the turn's output, then its result, at the recovery's last seq or past it.
    let through = end + extra;
    let mut copy: Vec<Value> = (cut + 1..through).map(|seq| chunk(seq, seq)).collect();
    copy.push(json!({"seq": through, "at": through, "dir": "mux", "kind": "turn_result",
                     "msg": {"turnId": "t1", "promptId": "p1", "status": "ok"}}));
    let summary = hub.session_summary(&session);
    let row = super::peer_snapshot::row_of(&session.id, &summary, hub.at_8b5f());
    let ((_, _, from), last) = row.expect("the row names its generation and end");
    assert_eq!(last, end);
    let past: Vec<Value> =
        copy.iter().filter(|r| r["seq"].as_u64().is_some_and(|s| s > from)).cloned().collect();
    let answer = if past.is_empty() {
        None
    } else {
        let mut params = restore_params(&session, Value::from(past));
        params["afterSeq"] = json!(from);
        Some(hub.journal_restore(&params).await)
    };
    let events = hub.events(&session.id, 0, 10_000).unwrap();
    let unknown = events
        .iter()
        .any(|e| e.msg.get("detail").and_then(Value::as_str) == Some("outcome_unknown"));
    let result =
        events.iter().any(|e| e.seq == through && e.kind == "turn_result" && e.at == through);
    let after = hub.session_summary(&session).get("recoveredAfter").and_then(Value::as_u64);
    (from, answer, unknown, result, session.queued(), after)
}

/// Review of #37284 at 8b5f3063, F2: a fresh machine whose startup recovery wrote as many records
/// as the owner's copy holds past where that recovery began names where it began
/// (`recoveredAfter`), and the copy goes back from there though it is not past the machine's
/// `lastSeq`: the turn keeps its own result at its own seq, with no unknown outcome and nothing
/// continued again. Under 8b5f3063's rules the owner compared with `lastSeq` alone, nothing went
/// back, and the turn's result was lost to its unknown outcome.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_recovery_as_long_as_the_copy_still_takes_the_copy_back() {
    let (from, answer, unknown, result, _, _) =
        a_recovery_as_long_as_the_copy(super::journal_restore::AT_8B5F, 0).await;
    assert!(answer.is_none(), "8b5f3063 gave back the copy from {from}");
    assert!(unknown && !result, "8b5f3063 kept the turn's result");
    let (from, answer, unknown, result, queued, after) = a_recovery_as_long_as_the_copy(0, 0).await;
    let answer = answer.expect("the copy did not go back");
    assert!(answer.is_ok(), "a restore from {from}: {answer:?}");
    assert!(!unknown, "the turn's result was lost to its unknown outcome");
    assert!(result, "the copy's turn result is not at its own seq");
    assert_eq!(queued, 0, "the turn is continued again");
    // Only a recovery of the restored log may be named now, never the one taken back.
    assert!(after.is_none_or(|a| a > from), "the recovery taken back is still named");
    // And a copy past the recovery's end goes back from where it began too.
    let (_, answer, unknown, result, ..) = a_recovery_as_long_as_the_copy(0, 2).await;
    assert!(answer.is_some_and(|a| a.is_ok()) && !unknown && result);
}

/// A chat whose recovery at its journal's end the owner's copy saw as it is (its pages read
/// it): restored from `recoveredAfter` with those same records, and with only the first of
/// them. The answers, whether the recovery's records are still at their seqs after each, and the
/// row's `recoveredAfter` after.
async fn a_copy_within_the_recovery() -> (Vec<Result<Value, RpcError>>, bool, Option<u64>) {
    let (hub, session) = hub_at(0).await;
    hub.append(&session, "mux", "turn_started", json!({"turnId": "t1", "promptId": "p1"}));
    let cut = session.seq.load(Ordering::SeqCst);
    *session.log_load.lock().unwrap() = false;
    session.log_loaded.store(false, Ordering::SeqCst);
    hub.load_session_log(&session);
    let end = session.seq.load(Ordering::SeqCst);
    let summary = hub.session_summary(&session);
    assert_eq!(summary.get("recoveredAfter").and_then(Value::as_u64), Some(cut));
    let recovery = hub.events(&session.id, cut, 10_000).unwrap();
    let as_seen: Vec<Value> = recovery.iter().map(|e| serde_json::to_value(e).unwrap()).collect();
    let mut answers = Vec::new();
    for records in [vec![as_seen[0].clone()], as_seen.clone()] {
        let mut params = restore_params(&session, Value::from(records));
        params["afterSeq"] = json!(cut);
        answers.push(hub.journal_restore(&params).await);
    }
    let now = hub.events(&session.id, cut, 10_000).unwrap();
    let kept = session.seq.load(Ordering::SeqCst) == end
        && now
            .iter()
            .map(|e| (e.seq, e.at, &e.kind))
            .eq(recovery.iter().map(|e| (e.seq, e.at, &e.kind)));
    let after = hub.session_summary(&session).get("recoveredAfter").and_then(Value::as_u64);
    (answers, kept, after)
}

/// Review of #37284 at 8b5f3063, F2: a copy that ends at or before the end of the machine's own
/// recovery and holds only what that recovery wrote gives nothing back: the restore leaves the
/// journal as it is (its turn is not continued again, no seq is written twice), answers its end,
/// so nothing is held, and the row names the recovery no more.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_copy_within_its_machines_recovery_gives_nothing_back() {
    let (answers, kept, after) = a_copy_within_the_recovery().await;
    for answer in &answers {
        let answer = answer.as_ref().expect("the restore was refused");
        assert_eq!(answer["restored"], json!(false), "{answer}");
    }
    assert!(kept, "the journal's own recovery was taken back for the same records");
    assert_eq!(after, None, "the row still names a recovery the copy holds");
}
