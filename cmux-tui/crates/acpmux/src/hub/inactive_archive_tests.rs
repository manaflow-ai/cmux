//! Archived chats and the automatic archive of inactive ones (`hub/inactive_archive.rs`).

use super::*;
use crate::store::MemoryStore;

const DAY_MS: u64 = 86_400_000;

fn hub() -> Arc<Hub> {
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg, Box::new(MemoryStore::default()))
}

/// A chat last active at `updated`, in `status`, with `tags` (`{"pinned": "1"}`).
fn chat(hub: &Hub, id: &str, status: &str, updated: u64, tags: Value) -> Arc<Session> {
    let tags: serde_json::Map<String, Value> = tags
        .as_object()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|(k, v)| (k, json!({"value": v})))
        .collect();
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
        "cwd": "/tmp", "status": status, "createdAt": 1, "updatedAt": updated, "tags": tags,
    }))
    .unwrap();
    hub.insert_test_session(meta)
}

fn tag(session: &Session, key: &str) -> Option<String> {
    session.read_meta(|m| m.tags.get(key).map(|t| t.value.clone()))
}

#[test]
fn setting_accepts_only_the_offered_periods() {
    assert!(archive_after(&json!({})).is_none());
    for value in [json!(0), json!("never"), json!(-1), json!(3), json!("soon")] {
        assert!(archive_after(&json!({SETTING: value})).is_none());
    }
    for days in [1, 2, 7, 14, 30] {
        let after = Some(Duration::from_secs(days * 86_400));
        assert_eq!(archive_after(&json!({SETTING: days})), after);
        assert_eq!(
            archive_after(&json!({"agents": {"chats": {"archiveInactive": format!("{days}d")}}})),
            after
        );
    }
}

#[tokio::test]
async fn pass_archives_at_the_deadline_and_keeps_work_and_families() {
    let hub = hub();
    let now = 100 * DAY_MS;
    let old = now - 7 * DAY_MS;
    let after = Duration::from_millis(7 * DAY_MS);
    let idle = chat(&hub, "idle", "idle", old, json!({}));
    let recent = chat(&hub, "recent", "idle", old + 1, json!({}));
    let pinned = chat(&hub, "pin", "closed", old, json!({"pinned":"1"}));
    let running = chat(&hub, "run", "running", old, json!({}));
    let waiting = chat(&hub, "wait", "waiting", old, json!({}));
    let root = chat(&hub, "root", "idle", old, json!({}));
    let child = chat(&hub, "child", "idle", old, json!({}));
    child.meta.lock().unwrap().lineage = Some(
        serde_json::from_value(json!({
            "root": "root", "parent": "root", "depth": 1
        }))
        .unwrap(),
    );
    let grandchild = chat(&hub, "grandchild", "closed", old, json!({"spawnedBy":"child"}));
    let detached = chat(&hub, "detached", "idle", old, json!({"mux.parent":"missing"}));
    let shelved = chat(&hub, "shelved", "closed", old, json!({"archived":"1"}));
    let starting = chat(&hub, "starting", "ready", old, json!({}));
    let lease = starting.turn_lock.lock().await;

    assert_eq!(hub.inactive_archive_pass(after, now), 1);
    assert_eq!(tag(&idle, ARCHIVED_TAG), Some(now.to_string()));
    for kept in [recent, pinned, running, waiting, root, child, grandchild, detached] {
        assert_eq!(tag(&kept, ARCHIVED_TAG), None, "{}", kept.id);
    }
    assert_eq!(tag(&shelved, ARCHIVED_TAG).as_deref(), Some("1"));
    assert_eq!(hub.inactive_archive_pass(after, now), 0);
    assert_eq!(tag(&starting, ARCHIVED_TAG), None);
    drop(lease);

    // The ordinary unarchive removes the tag and records fresh activity.
    hub.set_tags_answered(&idle, None, &[ARCHIVED_TAG.to_owned()], None).unwrap();
    let restored = idle.read_meta(|m| m.updated_at);
    hub.inactive_archive_pass(after, restored + 7 * DAY_MS - 1);
    assert_eq!(tag(&idle, ARCHIVED_TAG), None);
    hub.inactive_archive_pass(after, restored + 7 * DAY_MS);
    assert!(tag(&idle, ARCHIVED_TAG).is_some());
    hub.shutdown_all().await;
}
