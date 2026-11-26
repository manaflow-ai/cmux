//! Offloading old cold chats to cloud history on a setting (`hub/cloud_offload.rs`).

use super::*;
use crate::config::{Config, StoreMode};

struct Root(PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const DAY: u64 = 86_400_000;

fn chat(store: &dyn crate::store::Store, id: &str, updated_at: u64) {
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": format!("chat {id}"),
        "harness": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1,
        "updatedAt": updated_at, "lastSeq": 1, "eventCount": 1,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let record = EventRecord {
        seq: 1,
        at: updated_at,
        dir: "mux".into(),
        kind: "user_message".into(),
        msg: json!({"text": "question"}),
        host_seq: None,
    };
    store.append(id, &record).unwrap();
    store.close_log(id);
}

#[test]
fn the_setting_offloads_nothing_by_default() {
    assert_eq!(offload_after(&json!({})), None);
    assert_eq!(offload_after(&json!({"agents": {"chats": {"cloudOffload": false}}})), None);
    assert_eq!(
        offload_after(&json!({"agents": {"chats": {"cloudOffload": true}}})),
        Some(std::time::Duration::from_secs(14 * 86_400))
    );
    assert_eq!(
        offload_after(
            &json!({"agents": {"chats": {"cloudOffload": true, "cloudOffloadAfterDays": 60}}})
        ),
        Some(std::time::Duration::from_secs(60 * 86_400))
    );
}

#[tokio::test]
async fn only_old_archived_chats_past_the_newest_are_offloadable() {
    let root = Root(std::env::temp_dir().join(format!("acpmux-offload-{}", uuid::Uuid::now_v7())));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let now = now_ms();
    {
        let store = crate::store::open(&cfg.store, &root.0).unwrap();
        chat(&*store, "cold-old", now - 40 * DAY);
        chat(&*store, "warm-old", now - 40 * DAY);
        // The newest KEEP_NEWEST chats stay local whatever their age.
        for n in 0..KEEP_NEWEST {
            chat(&*store, &format!("new-{n}"), now - 30 * DAY + n as u64);
        }
        store.flush().unwrap();
    }
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root.0).unwrap());
    let cold = hub.resolve("cold-old").unwrap();
    hub.cold_archive_request(cold.clone(), true).await.unwrap();
    let newest_cold = hub.resolve("new-0").unwrap();
    hub.cold_archive_request(newest_cold, true).await.unwrap();
    let report = hub
        .history_offload_now(HistoryOffloadRequest { dry_run: true, older_than_days: Some(14) })
        .await
        .unwrap();
    assert_eq!(report["wouldOffload"], 1, "{report}");
    assert_eq!(report["chats"][0]["sessionId"], "cold-old");
    assert_eq!(report["skipped"]["not archived"], KEEP_NEWEST as u64, "{report}");
    assert_eq!(report["skipped"]["newest"], 1, "{report}");
    // With no cloud history set up, a real pass offloads nothing and loses nothing.
    let report = hub
        .history_offload_now(HistoryOffloadRequest { dry_run: false, older_than_days: Some(14) })
        .await
        .unwrap();
    assert_eq!(report["offloaded"], 0, "{report}");
    assert!(hub.store.is_cold("cold-old"), "the local archive stays");
    hub.shutdown_all().await;
}
