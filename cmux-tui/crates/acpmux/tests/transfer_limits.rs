//! Bundle admission and event import keep file contents in bounded pages/records.
//! The final-page fixture uses a sparse file on Unix.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use std::io::{Read, Seek, SeekFrom, Write};

#[tokio::test]
async fn transfer_limits_paged_bundles_over_four_gib_and_multi_mib_event_import() {
    let dir = tempfile::tempdir().unwrap();
    acpmux::config::set_home_override(dir.path().join("home"));
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["true"]}}, "defaultHarness": "fake"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, dir.path()).unwrap());
    let id = uuid::Uuid::now_v7().to_string();
    let transfer_id = uuid::Uuid::now_v7().to_string();
    let page = vec![0x5au8; 4 << 20];
    let size = (4u64 << 30) + page.len() as u64;
    let mut manifest = json!({
        "schema": "acpmux.transfer.v1", "transferId": transfer_id, "sessionId": id,
        "session": {"harness": "fake"},
        "files": [{"path": "payload.bin", "size": size}]
    });
    let received = hub
        .transfer_request("_acpmux/transfer_receive", &json!({"manifest": manifest}))
        .await
        .unwrap();
    let receive_id = received["receiveId"].as_str().unwrap();
    let write = |offset| {
        json!({"receiveId": receive_id, "path": "payload.bin", "offset": offset,
               "data": BASE64.encode(&page)})
    };
    let first = hub.transfer_request("_acpmux/transfer_write", &write(0)).await.unwrap();
    assert_eq!(first["next"], page.len() as u64);
    // Represent a prefix already transferred to disk without sending 4 GiB in the test.
    // The final real page exercises offsets and writes beyond the old total-byte cap.
    let path =
        dir.path().join("home/transfers").join(format!("in-{receive_id}/bundle/payload.bin"));
    std::fs::OpenOptions::new().write(true).open(&path).unwrap().set_len(4u64 << 30).unwrap();
    let last = hub.transfer_request("_acpmux/transfer_write", &write(4u64 << 30)).await.unwrap();
    assert_eq!(last["next"], size);
    let mut file = std::fs::File::open(&path).unwrap();
    assert_eq!(file.metadata().unwrap().len(), size);
    file.seek(SeekFrom::Start(4u64 << 30)).unwrap();
    let mut actual = Vec::new();
    file.read_to_end(&mut actual).unwrap();
    assert_eq!(actual, page);
    assert!(hub.transfer_request("_acpmux/transfer_write", &write(size)).await.is_err());

    for bad in [Value::Null, json!(-1), json!("large"), json!(1.5)] {
        manifest["files"][0]["size"] = bad;
        let error = hub
            .transfer_request("_acpmux/transfer_receive", &json!({"manifest": manifest}))
            .await
            .unwrap_err();
        assert!(error.message.contains("file size must be a u64"), "{error:?}");
    }

    let bundle = dir.path().join("bundle");
    std::fs::create_dir_all(bundle.join("events")).unwrap();
    let mut meta = json!({
        "schema": acpmux::store::META_SCHEMA, "id": id, "name": "large-log",
        "harness": "fake", "cwd": dir.path(), "status": "idle", "createdAt": 1, "updatedAt": 1
    });
    std::fs::write(bundle.join("session.json"), meta.to_string()).unwrap();
    let events_path = bundle.join("events/000001.ndjson");
    let mut events = std::io::BufWriter::new(std::fs::File::create(&events_path).unwrap());
    let payload = "x".repeat(64 << 10);
    for seq in 1..=96 {
        serde_json::to_writer(
            &mut events,
            &json!({
                "seq": seq, "at": 1, "dir": "mux", "kind": "audit-payload", "msg": {"text": payload}
            }),
        )
        .unwrap();
        events.write_all(b"\n").unwrap();
    }
    events.flush().unwrap();
    assert!(std::fs::metadata(&events_path).unwrap().len() > 6 << 20);
    hub.import(&bundle, None).await.unwrap();
    let imported = hub.events(&id, 0, 1000).unwrap();
    let records: Vec<_> = imported.iter().filter(|e| e.kind == "audit-payload").collect();
    assert_eq!(records.len(), 96);
    assert_eq!(records.last().unwrap().seq, 96);
    assert!(records.iter().all(|e| e.msg["text"] == payload));

    // A late unreadable record rolls back the earlier streamed records, too.
    let failed_id = uuid::Uuid::now_v7().to_string();
    meta["id"] = json!(failed_id);
    std::fs::write(bundle.join("session.json"), meta.to_string()).unwrap();
    events.write_all(b"\xff\n").unwrap();
    events.flush().unwrap();
    let error = hub.import(&bundle, None).await.err().expect("invalid UTF-8 import must fail");
    assert!(error.message.starts_with("import events: read"), "{error:?}");
    assert!(!hub.session_dir(&failed_id).unwrap().exists());
}
