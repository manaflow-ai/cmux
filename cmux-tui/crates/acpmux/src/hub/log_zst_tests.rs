//! A chat's log compressed once it closes (`hub/log_zst.rs`), and a reopen going on in plain.

use super::*;
use crate::config::{Config, StoreMode};

struct Root(PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn events_dir(root: &Path, id: &str) -> PathBuf {
    root.join("sessions").join(id).join("events")
}

fn names(root: &Path, id: &str) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(events_dir(root, id))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// Each segment's plain bytes, by index, the compressed ones decoded.
fn plain_bytes(root: &Path, id: &str) -> std::collections::BTreeMap<u32, Vec<u8>> {
    let mut out = std::collections::BTreeMap::new();
    for name in names(root, id) {
        let Some((index, zst)) = crate::store::segment_file::segment_name(&name) else { continue };
        let bytes = std::fs::read(events_dir(root, id).join(&name)).unwrap();
        let bytes = if zst { zstd::decode_all(&bytes[..]).unwrap() } else { bytes };
        assert!(out.insert(index, bytes).is_none(), "segment {index} under both names");
    }
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_closed_chat_is_compressed_and_a_reopen_goes_on_plain() {
    let root =
        Root(std::env::temp_dir().join(format!("acpmux-log-zst-hub-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    cfg.store.segment_bytes = 64 * 1024;
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root.0).unwrap());
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "z", "name": "to close", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert("z".to_owned(), session.clone());
    session.log_loaded.store(true, Ordering::SeqCst);
    for n in 0..800 {
        hub.append(
            &session,
            "mux",
            "user_message",
            json!({"text": format!("prompt {n} {}", "p".repeat(200))}),
        );
    }
    let worker = hub.log_zst_worker().expect("on by default");
    // A close queues the chat; the worker compresses every segment of its log.
    hub.set_status(&session, SessionStatus::Closed);
    let before = plain_bytes(&root.0, "z");
    assert!(before.len() >= 3, "several segments: {}", before.len());
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !names(&root.0, "z").iter().all(|n| n.ends_with(".ndjson.zst")) {
        assert!(std::time::Instant::now() < deadline, "not compressed: {:?}", names(&root.0, "z"));
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    // Contents identical, nothing plain or temporary left.
    assert_eq!(plain_bytes(&root.0, "z"), before);
    let all = hub.events("z", 0, usize::MAX).unwrap();
    assert_eq!(all.len() as u64, session.seq.load(Ordering::SeqCst));
    // Reopened: its records go on in a new plain segment after the compressed ones.
    assert!(hub.test_reopen("z"));
    hub.append(&session, "mux", "user_message", json!({"text": "after the reopen"}));
    let listed = names(&root.0, "z");
    let last = listed.last().unwrap();
    assert!(last.ends_with(".ndjson") && !last.ends_with(".zst"), "{listed:?}");
    let after = hub.events("z", 0, usize::MAX).unwrap();
    assert_eq!(&after[..all.len()], &all[..]);
    assert_eq!(after.last().unwrap().msg["text"], "after the reopen");
    hub.shutdown_all().await;
    drop(worker);
}
