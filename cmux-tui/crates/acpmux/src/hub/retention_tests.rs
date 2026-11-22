//! A pass never compacts a chat an import is replacing (`transfer_in.rs`) or one written to while
//! its log was read (`hub/retention.rs`).

use super::*;
use crate::config::{Config, StoreMode};

#[tokio::test]
async fn a_chat_an_import_is_replacing_is_left_whole() {
    let root = std::env::temp_dir().join(format!("acpmux-retention-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "old", "name": "old", "harness": "claude",
        "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let text = "x".repeat(5000);
    let record = |seq: u64, kind: &str, msg: Value| crate::store::EventRecord {
        seq,
        at: 2,
        dir: "in".into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    };
    store.append("old", &record(1, "claude.assistant", json!({"text": text}))).unwrap();
    store.close_log("old");
    drop(store);
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
    let session = hub.resolve("old").unwrap();
    let req = || RetentionRequest { older_than_days: Some(0), ..Default::default() };

    // An import replacing it marks it before it moves its folder aside (`transfer_in.rs`).
    session.replaced.store(true, Ordering::SeqCst);
    let pass = hub.retention_pass(req()).await.unwrap();
    assert_eq!((&pass["chats"], &pass["skipped"]["busy"]), (&json!(0), &json!(1)), "{pass}");
    assert_eq!(hub.events("old", 0, 10).unwrap()[0].msg["text"], json!(text));

    // The same chat when nothing replaces it: the pass does compact it.
    session.replaced.store(false, Ordering::SeqCst);
    let pass = hub.retention_pass(req()).await.unwrap();
    assert_eq!(pass["chats"], 1, "{pass}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_chat_written_to_while_its_log_was_read_is_left_whole() {
    let root = std::env::temp_dir().join(format!("acpmux-retention-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "old", "name": "old", "harness": "claude",
        "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let record = crate::store::EventRecord {
        seq: 1,
        at: 2,
        dir: "mux".into(),
        kind: "status".into(),
        msg: json!({"status": "closed"}),
        host_seq: None,
    };
    store.append("old", &record).unwrap();
    store.close_log("old");
    drop(store);
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
    let session = hub.resolve("old").unwrap();
    let hosted = std::collections::HashSet::new();
    let cutoff = now_ms() + 1000;
    let seen =
        hub.retainable(&session, cutoff, &hosted, false).unwrap_or_else(|why| panic!("{why}"));
    assert!(hub.untouched(&session, seen, cutoff, false), "nothing happened to it since");
    // While the pass read its log, it was reopened and closed again: each status write stamps
    // the chat before its record waits for the append lock the pass holds (`write_status`).
    std::thread::sleep(std::time::Duration::from_millis(2));
    assert!(hub.reopen(&session, session.stops.load(Ordering::SeqCst)));
    hub.set_status(&session, SessionStatus::Closed);
    assert_eq!(session.status(), SessionStatus::Closed);
    assert!(
        !hub.untouched(&session, seen, cutoff, false),
        "a chat closed just now is not compacted"
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// huge-blue, 2026-10-27: something stopped its 464 closed chats again every few minutes, each
/// stop dated the chat now, and none was ever older than a day, so no pass compacted any.
#[tokio::test]
async fn a_closed_chat_stopped_again_keeps_its_age() {
    let root = std::env::temp_dir().join(format!("acpmux-retention-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "old", "name": "old", "harness": "claude",
        "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let text = "x".repeat(5000);
    let record = crate::store::EventRecord {
        seq: 1,
        at: 2,
        dir: "in".into(),
        kind: "claude.assistant".into(),
        msg: json!({"text": text}),
        host_seq: None,
    };
    store.append("old", &record).unwrap();
    store.close_log("old");
    drop(store);
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
    let session = hub.resolve("old").unwrap();
    hub.kill(&session, false).await.unwrap();
    // Both repeated close and a failed idle cancel reach stop_auto_resume. Neither
    // should journal a fresh retry-cancellation boundary for an already closed chat.
    hub.kill(&session, false).await.unwrap();
    assert!(hub.cancel(&session).await.is_err());
    assert_eq!(session.meta().updated_at, 2, "a stop that changed nothing dates nothing");
    assert_eq!(hub.events("old", 0, 10).unwrap().len(), 1, "and logs nothing");
    // The default 14 days: the chat closed long ago is compacted.
    let pass = hub.retention_pass(RetentionRequest::default()).await.unwrap();
    assert_eq!(pass["chats"], 1, "{pass}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A chat dated today in its `session.json` (stopped again before #25863) is as old as its log.
#[tokio::test]
async fn a_closed_chat_is_as_old_as_its_log() {
    let root = std::env::temp_dir().join(format!("acpmux-retention-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    let now = now_ms();
    for id in ["log-old", "log-new"] {
        let meta = json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
            "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": now,
        });
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        let record = crate::store::EventRecord {
            seq: 1,
            at: 2,
            dir: "in".into(),
            kind: "claude.assistant".into(),
            msg: json!({"text": "x".repeat(5000)}),
            host_seq: None,
        };
        store.append(id, &record).unwrap();
        store.close_log(id);
    }
    drop(store);
    let month = std::time::SystemTime::now() - std::time::Duration::from_secs(30 * 86_400);
    let segment = root.join("sessions/log-old/events/000001.ndjson");
    std::fs::File::options().append(true).open(&segment).unwrap().set_modified(month).unwrap();
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
    let pass = hub.retention_pass(RetentionRequest::default()).await.unwrap();
    assert_eq!((&pass["chats"], &pass["skipped"]["recent"]), (&json!(1), &json!(1)), "{pass}");
    assert_eq!(pass["largest"][0]["sessionId"], "log-old", "{pass}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A close sets its status and stamp, then logs its record: a pass that looks in between sees an
/// old log and today's stamp, and must still leave the chat whole.
#[tokio::test]
async fn a_chat_whose_close_is_not_logged_yet_is_left_whole() {
    let root = std::env::temp_dir().join(format!("acpmux-retention-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "c", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let record = |seq: u64| crate::store::EventRecord {
        seq,
        at: 2,
        dir: "mux".into(),
        kind: "status".into(),
        msg: json!({"status": "idle"}),
        host_seq: None,
    };
    store.append("c", &record(1)).unwrap();
    store.close_log("c");
    drop(store);
    let month = std::time::SystemTime::now() - std::time::Duration::from_secs(30 * 86_400);
    let segment = root.join("sessions/c/events/000001.ndjson");
    std::fs::File::options().append(true).open(&segment).unwrap().set_modified(month).unwrap();
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
    let session = hub.resolve("c").unwrap();
    let cutoff = now_ms() - 14 * 86_400_000;
    let hosted = std::collections::HashSet::new();
    // The close between its status and its record, as `write_status` leaves it.
    session.status_writes.fetch_add(1, Ordering::SeqCst);
    {
        let mut m = session.meta.lock().unwrap();
        m.status = SessionStatus::Closed;
        m.updated_at = now_ms();
    }
    let seen =
        hub.retainable(&session, cutoff, &hosted, false).unwrap_or_else(|why| panic!("{why}"));
    assert!(!hub.untouched(&session, seen, cutoff, false), "its close is under way");
    // Its record logged after the pass looked: the log is new again.
    hub.store.append("c", &record(2)).unwrap();
    session.status_writes.fetch_sub(1, Ordering::SeqCst);
    assert!(!hub.untouched(&session, seen, cutoff, false), "it closed just now");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// hq#19257: the one pass a log written before the tap left out a resume's replays needs. An open
/// chat nothing uses now is let in (a plain pass leaves it: "open"); the replayed history and the
/// thread a resume answer held go, the mode a load reported and the end of a call only the replay
/// closed stay, every other record is as written, and the chat reads back the same rows. The old
/// segments stay in the archive.
#[tokio::test]
async fn an_unread_only_pass_drops_the_replays_and_keeps_the_chat() {
    let root = std::env::temp_dir().join(format!("acpmux-retention-{}", uuid::Uuid::now_v7()));
    let archive = root.join("kept");
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "codex", "name": "codex", "harness": "codex",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let update = |u: Value| {
        json!({"jsonrpc": "2.0", "method": "session/update",
        "params": {"sessionId": "s1", "update": u}})
    };
    let output = "test result: ok. 412 passed\n".repeat(200);
    let mut seq = 0;
    let mut add = |kind: &str, msg: Value| {
        seq += 1;
        let record = crate::store::EventRecord {
            seq,
            at: 2,
            dir: "in".into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        };
        store.append("codex", &record).unwrap();
    };
    // The chat: a prompt, a call the live log never saw end, a reply with a long output.
    add(
        "user_message_chunk",
        update(json!({"sessionUpdate": "user_message_chunk",
        "content": {"type": "text", "text": "run the tests"}})),
    );
    add(
        "tool_call",
        update(json!({"sessionUpdate": "tool_call", "toolCallId": "open",
        "status": "in_progress", "title": "cargo test"})),
    );
    add(
        "tool_call",
        update(json!({"sessionUpdate": "tool_call", "toolCallId": "done",
        "status": "completed", "title": "cargo build", "rawOutput": output})),
    );
    add(
        "agent_message_chunk",
        update(json!({"sessionUpdate": "agent_message_chunk",
        "content": {"type": "text", "text": "green"}})),
    );
    // Twenty resumes, each with its answer's whole thread and the history replayed.
    for _ in 0..20 {
        add(
            "codex.response",
            json!({"method": "codex.response", "params": {"id": 2,
            "result": {"thread": {"id": "th", "turns": [{"id": "t1", "items": [{"text": output}]}]}}}}),
        );
        add(
            "user_message_chunk.replay",
            update(json!({"sessionUpdate": "user_message_chunk",
            "content": {"type": "text", "text": "run the tests"}})),
        );
        add(
            "tool_call.replay",
            update(json!({"sessionUpdate": "tool_call", "toolCallId": "done",
            "status": "completed", "rawOutput": output})),
        );
        add(
            "tool_call_update.replay",
            update(json!({"sessionUpdate": "tool_call_update",
            "toolCallId": "open", "status": "completed", "rawOutput": output})),
        );
        add(
            "current_mode_update.replay",
            update(json!({"sessionUpdate": "current_mode_update",
            "currentModeId": "auto"})),
        );
    }
    store.close_log("codex");
    drop(store);
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
    let before = hub.events("codex", 0, usize::MAX).unwrap();
    let live = |records: &[crate::store::EventRecord]| -> Vec<String> {
        records
            .iter()
            .filter(|r| !r.kind.ends_with(".replay") && r.kind != "codex.response")
            .map(|r| serde_json::to_string(r).unwrap())
            .collect()
    };
    // A plain pass leaves an open chat whole.
    let plain = RetentionRequest { older_than_days: Some(0), ..Default::default() };
    let pass = hub.retention_pass(plain).await.unwrap();
    assert_eq!((&pass["chats"], &pass["skipped"]["open"]), (&json!(0), &json!(1)), "{pass}");

    // A dry run measures what the pass will remove, and changes nothing.
    let dry = RetentionRequest {
        unread_only: true,
        dry_run: true,
        only: Some("codex".into()),
        ..Default::default()
    };
    let measured = hub.retention_pass(dry).await.unwrap();
    assert_eq!(hub.events("codex", 0, usize::MAX).unwrap().len(), before.len());

    let req = RetentionRequest {
        unread_only: true,
        archive: Some(archive.clone()),
        only: Some("codex".into()),
        ..Default::default()
    };
    let pass = hub.retention_pass(req).await.unwrap();
    assert_eq!(pass["chats"], 1, "{pass}");
    assert_eq!(
        (&measured["bytesBefore"], &measured["bytesAfter"]),
        (&pass["bytesBefore"], &pass["bytesAfter"]),
        "the dry run measured this pass: {measured} {pass}"
    );
    let (bytes_before, bytes_after) =
        (pass["bytesBefore"].as_u64().unwrap(), pass["bytesAfter"].as_u64().unwrap());
    println!("unread-only pass: {bytes_before} -> {bytes_after} bytes");
    assert!(bytes_after * 10 < bytes_before, "{pass}");
    let chat = &pass["readBack"][0];
    assert_eq!(chat["sessionId"], "codex", "{pass}");
    assert!(chat["rows"].as_u64().unwrap() >= 3, "{pass}");

    let after = hub.events("codex", 0, usize::MAX).unwrap();
    assert_eq!(live(&after), live(&before), "every record of the chat is as written");
    let kinds = |kind: &str| after.iter().filter(|r| r.kind == kind).count();
    assert_eq!(kinds("current_mode_update.replay"), 20, "a restart reads the modes back");
    assert_eq!(kinds("user_message_chunk.replay") + kinds("tool_call.replay"), 0);
    // Only the first replayed end of the call left open stays, as a stub.
    assert_eq!(kinds("tool_call_update.replay"), 1);
    let end = after.iter().find(|r| r.kind == "tool_call_update.replay").unwrap();
    assert_eq!(
        end.msg["params"]["update"],
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "open", "status": "completed"})
    );
    let answers: Vec<_> = after.iter().filter(|r| r.kind == "codex.response").collect();
    assert_eq!(answers.len(), 20);
    assert_eq!(answers[0].msg["params"]["result"]["thread"]["turnsOmitted"], 1);
    // Every seq that stayed is its old one.
    for r in &after {
        assert!(before.iter().any(|b| b.seq == r.seq && b.kind == r.kind));
    }
    // The old segments, whole, in the archive.
    let kept: u64 = walk(&archive)
        .iter()
        .filter(|p| p.extension().is_some_and(|e| e == "ndjson"))
        .map(|p| std::fs::metadata(p).unwrap().len())
        .sum();
    assert_eq!(kept, bytes_before, "the archive holds the old log");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

fn walk(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() {
            out.extend(walk(&path));
        } else {
            out.push(path);
        }
    }
    out
}
