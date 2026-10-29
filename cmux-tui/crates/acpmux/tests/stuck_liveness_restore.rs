//! The persisted harness-failure projection survives a daemon restart.
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::store::{EventRecord, META_SCHEMA, SessionMeta};
use serde_json::json;
use std::path::PathBuf;

#[test]
fn persisted_three_failure_projection_restores_and_clears_on_success() {
    let root = PathBuf::from("/tmp").join(format!("acpmux-stuck-restore-{}", uuid::Uuid::now_v7()));
    let id = "01a15800-0000-7000-8000-000000000042";
    std::fs::create_dir_all(&root).unwrap();
    let mut config: Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = StoreMode::Local;
    {
        let store = acpmux::store::open(&config.store, &root).unwrap();
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": META_SCHEMA, "id": id, "name": "restored", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
            "lastSeq": 3, "eventCount": 3
        }))
        .unwrap();
        // An older daemon saved no liveness projection: derive it from its turn log.
        for seq in 1..=3 {
            store
                .append(
                    id,
                    &EventRecord {
                        seq,
                        at: seq * 100,
                        dir: "mux".into(),
                        kind: "turn_result".into(),
                        msg: json!({"status": "failed", "errorText": "HTTP 503 unavailable"}),
                        host_seq: None,
                    },
                )
                .unwrap();
        }
        store.save(&meta).unwrap();
        store.flush().unwrap();
    }
    let hub = Hub::new(config.clone(), acpmux::store::open(&config.store, &root).unwrap());
    let restored = hub.session_summary(&hub.resolve(id).unwrap());
    assert_eq!(restored["state"], "stuck", "{restored}");
    assert_eq!(restored["stuckReason"], "harness_unavailable", "{restored}");
    assert_eq!(restored["stuckSince"], 300, "{restored}");
    assert_eq!(restored["stuckError"], "HTTP 503 unavailable", "{restored}");
    let persisted = hub.resolve(id).unwrap().meta();
    drop(hub);

    let store = acpmux::store::open(&config.store, &root).unwrap();
    store.save(&persisted).unwrap();
    store
        .append(
            id,
            &EventRecord {
                seq: 4,
                at: 400,
                dir: "mux".into(),
                kind: "turn_result".into(),
                msg: json!({"status": "completed", "stopReason": "end_turn"}),
                host_seq: None,
            },
        )
        .unwrap();
    store.flush().unwrap();
    let store_config = config.store.clone();
    let hub = Hub::new(config, acpmux::store::open(&store_config, &root).unwrap());
    let recovered = hub.session_summary(&hub.resolve(id).unwrap());
    assert_ne!(recovered["state"], "stuck", "{recovered}");
    assert!(recovered["stuckReason"].is_null(), "{recovered}");
    assert!(recovered["stuckSince"].is_null(), "{recovered}");
    assert!(recovered["stuckError"].is_null(), "{recovered}");
    drop(hub);
    drop(store);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_long_failure_log_restores_from_a_bounded_window_and_saves_it() {
    let root = PathBuf::from("/tmp").join(format!("acpmux-stuck-window-{}", uuid::Uuid::now_v7()));
    let id = "01a15800-0000-7000-8000-000000000043";
    std::fs::create_dir_all(&root).unwrap();
    let mut config: Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = StoreMode::Local;
    let failures = 40;
    {
        let store = acpmux::store::open(&config.store, &root).unwrap();
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": META_SCHEMA, "id": id, "name": "window", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
            "lastSeq": failures, "eventCount": failures
        }))
        .unwrap();
        for seq in 1..=failures {
            let msg = json!({"status": "failed", "errorText": "HTTP 503 unavailable"});
            let record = EventRecord {
                seq,
                at: seq * 100,
                dir: "mux".into(),
                kind: "turn_result".into(),
                msg,
                host_seq: None,
            };
            store.append(id, &record).unwrap();
        }
        store.save(&meta).unwrap();
        store.flush().unwrap();
    }
    let hub = Hub::new(config.clone(), acpmux::store::open(&config.store, &root).unwrap());
    let restored = hub.session_summary(&hub.resolve(id).unwrap());
    assert_eq!(restored["state"], "stuck", "{restored}");
    // Only the newest RESTORE_RESULTS results are read: the streak reads as starting there.
    let window_start = failures - acpmux::session_liveness::RESTORE_RESULTS as u64 + 1;
    assert_eq!(restored["stuckSince"], (window_start + 2) * 100, "{restored}");
    drop(hub);

    let saved = acpmux::store::open(&config.store, &root).unwrap().load(id).unwrap().unwrap();
    assert_eq!(saved.harness_failures.through_seq, failures, "the rebuilt projection is saved");
    assert!(saved.harness_failures.stuck().is_some());
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_memory_store_restores_from_the_same_bounded_window() {
    let id = "01a15800-0000-7000-8000-000000000044";
    let mut config: Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let failures = 300;
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": "memory-window", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "lastSeq": failures, "eventCount": failures
    }))
    .unwrap();
    store.save(&meta).unwrap();
    for seq in 1..=failures {
        let (dir, kind, msg) = if seq % 2 == 0 {
            ("mux", "turn_result", json!({"status": "failed", "errorText": "HTTP 503 unavailable"}))
        } else {
            ("agent", "session/update", json!({}))
        };
        let record = EventRecord {
            seq,
            at: seq * 100,
            dir: dir.into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        };
        store.append(id, &record).unwrap();
    }
    // Newest first, stopping where the visitor stops, skipped kinds left out.
    let mut seen = Vec::new();
    store
        .scan_back(id, 10, 290, &|dir, kind| dir != b"mux" || kind != b"turn_result", &mut |r| {
            seen.push(r.seq);
            seen.len() < 3
        })
        .unwrap();
    assert_eq!(seen, vec![288, 286, 284]);

    let hub = Hub::new(config, store);
    let restored = hub.session_summary(&hub.resolve(id).unwrap());
    assert_eq!(restored["state"], "stuck", "{restored}");
    // The newest RESTORE_RESULTS results (every other seq) are read: the streak starts there.
    let window = acpmux::session_liveness::RESTORE_RESULTS as u64;
    let oldest = failures - 2 * (window - 1);
    assert_eq!(restored["stuckSince"], (oldest + 4) * 100, "{restored}");
    assert_eq!(hub.resolve(id).unwrap().meta().harness_failures.through_seq, failures);
}
