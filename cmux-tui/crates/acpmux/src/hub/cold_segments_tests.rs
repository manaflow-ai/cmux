//! The cold segments' setting and worker (`hub/cold_segments.rs`).

use super::*;
use crate::store::{EventRecord, HistoryRef, LocalStore, SessionMeta, Store};

/// The smallest segment a store rolls at (`LocalStore::new`).
const SEGMENT: u64 = 64 * 1024;

fn hub(store: Box<dyn Store>) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg, store)
}

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "coordinator", "harness": "codex",
        "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap()
}

fn record(seq: u64) -> EventRecord {
    let pad = "x".repeat((seq as usize * 37) % 900);
    EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a",
            "update": {"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": format!("{seq} {pad}")}}}}),
        host_seq: None,
    }
}

fn all(store: &dyn Store, id: &str) -> Vec<EventRecord> {
    store.events(id, 0, usize::MAX).unwrap()
}

/// The `.ndjson` segments of chat `id` but its newest: the sealed segments still hot.
fn hot_sealed(sessions: &Path, id: &str) -> usize {
    let names = std::fs::read_dir(sessions.join(id).join("events"))
        .map(|rd| {
            rd.flatten().filter(|e| e.file_name().to_string_lossy().ends_with(".ndjson")).count()
        })
        .unwrap_or(0);
    names.saturating_sub(1)
}

fn cold(sessions: &Path, id: &str) -> usize {
    std::fs::read_dir(sessions.join(id).join("cold-segments"))
        .map(|rd| {
            rd.flatten().filter(|e| e.file_name().to_string_lossy().ends_with(".zst")).count()
        })
        .unwrap_or(0)
}

/// Off unless the settings say so, at level 3 unless they name one from 1 to 19; flat and
/// nested keys alike.
#[test]
fn the_setting_is_off_by_default_and_names_the_level() {
    assert_eq!(level_of(&json!({})), None);
    assert_eq!(level_of(&json!({"agents.chats.coldSegments": false})), None);
    assert_eq!(level_of(&json!({"agents.chats.coldSegmentsLevel": 9})), None);
    assert_eq!(level_of(&json!({"agents.chats.coldSegments": true})), Some(3));
    assert_eq!(
        level_of(&json!({"agents": {"chats": {"coldSegments": true, "coldSegmentsLevel": 7}}})),
        Some(7)
    );
    assert_eq!(
        level_of(&json!({"agents.chats.coldSegments": true, "agents.chats.coldSegmentsLevel": 40})),
        Some(3)
    );
}

/// With the setting off a seal moves nothing; on, the one worker moves every sealed segment as
/// the chat seals them, the chat reads the same, and the worker ends at shutdown.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn one_worker_moves_sealed_segments_and_ends_at_shutdown() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let hub = hub(Box::new(LocalStore::new(sessions.clone(), SEGMENT).unwrap()));
    *hub.cold_segments_level.lock().unwrap() = Some(None);
    let worker = hub.cold_segments_worker();
    for seq in 1..=600 {
        hub.store.append("c", &record(seq)).unwrap();
    }
    let sealed = hot_sealed(&sessions, "c");
    assert!(sealed > 1, "{sealed} sealed segments");
    // The worker's round is in: with the setting off, nothing went.
    let quiet = std::time::Instant::now();
    while !hub.cold_sealed.lock().unwrap().is_empty() && quiet.elapsed().as_secs() < 10 {
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert_eq!(cold(&sessions, "c"), 0, "the setting is off");

    *hub.cold_segments_level.lock().unwrap() = Some(Some(3));
    for seq in 601..=1500 {
        hub.store.append("c", &record(seq)).unwrap();
    }
    let started = std::time::Instant::now();
    while hot_sealed(&sessions, "c") > 0 && started.elapsed().as_secs() < 20 {
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert_eq!(hot_sealed(&sessions, "c"), 0, "every sealed segment went cold");
    assert!(cold(&sessions, "c") > 4);
    assert_eq!(all(hub.store.as_ref(), "c"), (1..=1500).map(record).collect::<Vec<_>>());

    hub.shutdown_all().await;
    tokio::time::timeout(std::time::Duration::from_secs(5), worker)
        .await
        .expect("the worker ends at shutdown")
        .unwrap();
}

/// A fork by reference reads its chat's history through the archives, and a read under way
/// while the chat's segments go cold reads every record once.
#[test]
fn a_fork_reads_its_history_while_the_chat_goes_cold() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let writer = LocalStore::new(sessions.clone(), SEGMENT).unwrap();
    writer.save(&meta("parent")).unwrap();
    for seq in 1..=1500 {
        writer.append("parent", &record(seq)).unwrap();
    }
    writer.flush().unwrap();
    drop(writer);
    let hub = hub(Box::new(LocalStore::new(sessions.clone(), SEGMENT).unwrap()));
    let mut fork = meta("fork");
    fork.history_from = Some(HistoryRef { session: "parent".into(), through_seq: 1400 });
    hub.store.save(&fork).unwrap();
    let before = all(hub.store.as_ref(), "fork");
    assert_eq!(before.len(), 1400);

    let mut moved = 0;
    let mut during = Vec::new();
    hub.store
        .scan("fork", 0, &mut |rec| {
            if moved == 0 {
                loop {
                    let (done, more) = hub.cold_segments_of("parent", Some(3)).unwrap();
                    moved += done.segments;
                    if !more {
                        break;
                    }
                }
            }
            during.push(rec);
            true
        })
        .unwrap();
    assert!(moved > 4, "{moved} segments went cold");
    assert_eq!(during, before, "the read under way");
    assert_eq!(hot_sealed(&sessions, "parent"), 0);
    assert_eq!(all(hub.store.as_ref(), "fork"), before, "the fork after");
}

/// `cmux chats warm`: refused while the setting is on (the worker would compress them again),
/// and with it off every cold segment of the chat is plain again, the chat and its fork reading
/// as before.
#[test]
fn warm_is_refused_while_the_setting_is_on_and_brings_a_chat_back_with_it_off() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let writer = LocalStore::new(sessions.clone(), SEGMENT).unwrap();
    writer.save(&meta("parent")).unwrap();
    for seq in 1..=1500 {
        writer.append("parent", &record(seq)).unwrap();
    }
    writer.flush().unwrap();
    drop(writer);
    let hub = hub(Box::new(LocalStore::new(sessions.clone(), SEGMENT).unwrap()));
    let mut fork = meta("fork");
    fork.history_from = Some(HistoryRef { session: "parent".into(), through_seq: 1400 });
    hub.store.save(&fork).unwrap();
    let before = (all(hub.store.as_ref(), "parent"), all(hub.store.as_ref(), "fork"));
    loop {
        let (_, more) = hub.cold_segments_of("parent", Some(3)).unwrap();
        if !more {
            break;
        }
    }
    let moved = cold(&sessions, "parent");
    assert!(moved > 4, "{moved}");

    *hub.cold_segments_level.lock().unwrap() = Some(Some(3));
    let refused = hub.warm_cold_segments(Some("parent")).expect_err("the setting is on");
    assert!(format!("{refused:#}").contains("agents.chats.coldSegments"), "{refused:#}");
    assert_eq!(cold(&sessions, "parent"), moved, "nothing changed");

    *hub.cold_segments_level.lock().unwrap() = Some(None);
    let warmed = hub.warm_cold_segments(Some("parent")).unwrap();
    assert_eq!(warmed["segments"], json!(moved), "{warmed}");
    assert_eq!(warmed["left"], json!([]), "{warmed}");
    assert_eq!(cold(&sessions, "parent"), 0);
    assert!(!sessions.join("parent").join("cold-segments").exists());
    assert_eq!((all(hub.store.as_ref(), "parent"), all(hub.store.as_ref(), "fork")), before);
}
