//! The store's size cap (`hub/store_pressure.rs`): a store over its cap compacts and cold-archives
//! its closed chats, oldest first, and leaves open chats whole.

use super::*;
use crate::config::{Config, StoreMode};

fn pressure(free: u64, store: Option<u64>, cap: Option<u64>, floor: Option<u8>) -> Pressure {
    Pressure { free, total: 1000, store_bytes: store, cap, floor_percent: floor }
}

#[test]
fn over_and_relieved_follow_the_cap_and_the_floor() {
    // Under the cap, above the floor with margin: nothing to do.
    assert!(!pressure(500, Some(100), Some(250), Some(15)).over());
    assert!(pressure(500, Some(100), Some(250), Some(15)).relieved());
    // Over the cap.
    assert!(pressure(500, Some(300), Some(250), Some(15)).over());
    // Under the cap but not 90% under it: a pass under way goes on.
    assert!(!pressure(500, Some(240), Some(250), Some(15)).relieved());
    // Under the free floor (15% of 1000 is 150).
    assert!(pressure(100, None, None, Some(15)).over());
    // Above the floor but inside its margin (20%): not over, not relieved.
    assert!(!pressure(170, None, None, Some(15)).over());
    assert!(!pressure(170, None, None, Some(15)).relieved());
    // Both off: never over.
    assert!(!pressure(0, None, None, None).over());
}

#[test]
fn the_settings_default_to_a_quarter_of_the_disk_and_15_percent() {
    let mut store = crate::config::StoreConfig::default();
    assert_eq!(store.store_cap(4000), Some(1000));
    assert_eq!(store.free_floor_percent(), Some(15));
    store.max_bytes = Some(0);
    store.min_free_percent = Some(0);
    assert_eq!((store.store_cap(4000), store.free_floor_percent()), (None, None));
    store.max_bytes = Some(7);
    assert_eq!(store.store_cap(4000), Some(7));
    let parsed: crate::config::StoreConfig =
        serde_json::from_value(json!({"maxBytes": 9, "minFreePercent": 3})).unwrap();
    assert_eq!((parsed.max_bytes, parsed.min_free_percent), (Some(9), Some(3)));
}

#[tokio::test]
async fn a_store_over_its_cap_compacts_and_archives_closed_chats_and_leaves_open_ones() {
    let root = std::env::temp_dir().join(format!("acpmux-pressure-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    let text = "x".repeat(200_000);
    for (id, status) in [("closed-a", "closed"), ("closed-b", "closed"), ("open", "idle")] {
        let meta = json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
            "cwd": "/tmp", "status": status, "createdAt": 1, "updatedAt": 2,
        });
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        for seq in 1..=3 {
            let record = crate::store::EventRecord {
                seq,
                at: 2,
                dir: "in".into(),
                kind: "claude.raw".into(),
                msg: json!({"text": text}),
                host_seq: None,
            };
            store.append(id, &record).unwrap();
        }
        store.close_log(id);
    }
    drop(store);
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
    for id in ["closed-a", "closed-b", "open"] {
        let _ = hub.events(id, 0, 10).unwrap();
    }
    // A cap of one byte: always over; the floor off so the test machine's disk plays no part.
    let mut store_cfg = cfg.store.clone();
    store_cfg.max_bytes = Some(1);
    store_cfg.min_free_percent = Some(0);
    let before = hub.store_pressure(&store_cfg).unwrap();
    assert!(before.over(), "{before:?}");
    let open_bytes_before =
        super::store_pressure::tests_dir_bytes(&hub.store.session_path("open").unwrap());

    let relieve = hub.clone();
    let cfg2 = store_cfg.clone();
    let report = tokio::task::spawn_blocking(move || relieve.relieve_store_pressure(&cfg2))
        .await
        .unwrap()
        .expect("a pass ran");
    let after = report["after"]["storeBytes"].as_u64().unwrap();
    assert!(after < before.store_bytes.unwrap(), "{report}");
    assert_eq!(report["stillOver"], json!(true), "a one-byte cap stays over: {report}");
    // The open chat is left whole; both closed chats still read back their messages.
    assert_eq!(
        super::store_pressure::tests_dir_bytes(&hub.store.session_path("open").unwrap()),
        open_bytes_before
    );
    for id in ["closed-a", "closed-b"] {
        let session = hub.resolve(id).unwrap();
        assert_eq!(session.meta().status, SessionStatus::Closed);
    }
    // Under no cap and no floor, no pass runs.
    let mut off = cfg.store.clone();
    off.max_bytes = Some(0);
    off.min_free_percent = Some(0);
    let relieve = hub.clone();
    assert!(
        tokio::task::spawn_blocking(move || relieve.relieve_store_pressure(&off))
            .await
            .unwrap()
            .is_none()
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
