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
