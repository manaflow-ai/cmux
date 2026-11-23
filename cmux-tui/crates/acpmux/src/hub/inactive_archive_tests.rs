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
fn the_setting_is_never_by_default_and_reads_days() {
    let days = |n: u64| Some(std::time::Duration::from_secs(n * 86_400));
    assert_eq!(archive_after(&json!({})), None);
    assert_eq!(archive_after(&json!({"agents": {"chats": {"archiveInactive": "never"}}})), None);
    assert_eq!(archive_after(&json!({"agents": {"chats": {"archiveInactive": 0}}})), None);
    assert_eq!(archive_after(&json!({"agents": {"chats": {"archiveInactive": true}}})), None);
    assert_eq!(archive_after(&json!({"agents": {"chats": {"archiveInactive": "7d"}}})), days(7));
    assert_eq!(archive_after(&json!({"agents": {"chats": {"archiveInactive": 3}}})), days(3));
    assert_eq!(archive_after(&json!({"agents.chats.archiveInactive": "30"})), days(30));
}

#[tokio::test]
async fn a_pass_archives_only_inactive_chats_with_nothing_at_work() {
    let hub = hub();
    let now = 100 * DAY_MS;
    let old = now - 10 * DAY_MS;
    let closed = chat(&hub, "closed", "closed", old, json!({}));
    let idle = chat(&hub, "idle", "idle", old, json!({}));
    let recent = chat(&hub, "recent", "idle", now - DAY_MS, json!({}));
    let running = chat(&hub, "running", "running", old, json!({}));
    let waiting = chat(&hub, "waiting", "waiting", old, json!({}));
    let pinned = chat(&hub, "pinned", "closed", old, json!({"pinned": "1"}));
    let side = chat(&hub, "side", "closed", old, json!({"side": "closed"}));
    let shelved = chat(&hub, "shelved", "closed", old, json!({"archived": "5"}));
    let gone = chat(&hub, "gone", "idle", old, json!({}));
    gone.purged.store(true, Ordering::SeqCst);

    assert_eq!(hub.inactive_archive_pass(std::time::Duration::from_millis(7 * DAY_MS), now), 2);
    for archived in [&closed, &idle] {
        assert!(
            tag(archived, ARCHIVED_TAG).unwrap().parse::<u64>().unwrap() > 0,
            "{}",
            archived.id
        );
        assert_eq!(tag(archived, ARCHIVED_BY_TAG).as_deref(), Some(ARCHIVED_BY_AUTO));
    }
    for kept in [&recent, &running, &waiting, &pinned, &side, &gone] {
        assert_eq!(tag(kept, ARCHIVED_TAG), None, "{}", kept.id);
    }
    // One archived already keeps its own archive: its time, and no marker.
    assert_eq!(tag(&shelved, ARCHIVED_TAG).as_deref(), Some("5"));
    assert_eq!(tag(&shelved, ARCHIVED_BY_TAG), None);
    // A second pass finds nothing more.
    assert_eq!(hub.inactive_archive_pass(std::time::Duration::from_millis(7 * DAY_MS), now), 0);
    hub.shutdown_all().await;
}

#[tokio::test]
async fn an_unarchived_chat_waits_a_whole_new_period() {
    let hub = hub();
    let after = std::time::Duration::from_millis(7 * DAY_MS);
    let chat = chat(&hub, "c", "closed", 1, json!({}));
    assert_eq!(hub.inactive_archive_pass(after, now_ms()), 1);
    assert!(hub.set_archived(&chat, false, false).unwrap());
    assert_eq!(tag(&chat, ARCHIVED_TAG), None);
    assert_eq!(tag(&chat, ARCHIVED_BY_TAG), None);
    // The unarchive is activity: no pass archives it again until the period passed since.
    let unarchived = chat.read_meta(|m| m.updated_at);
    assert!(unarchived + DAY_MS > now_ms());
    assert_eq!(hub.inactive_archive_pass(after, now_ms()), 0);
    assert_eq!(hub.inactive_archive_pass(after, unarchived + 6 * DAY_MS), 0);
    assert_eq!(hub.inactive_archive_pass(after, unarchived + 8 * DAY_MS), 1);
    assert_eq!(tag(&chat, ARCHIVED_BY_TAG).as_deref(), Some(ARCHIVED_BY_AUTO));
    hub.shutdown_all().await;
}

#[tokio::test]
async fn archive_and_unarchive_change_only_what_differs() {
    let hub = hub();
    let chat = chat(&hub, "c", "idle", 1, json!({}));
    let seq = || chat.read_meta(|m| m.last_seq);
    // Unarchive of a chat that is not archived: a success that logs nothing.
    assert!(!hub.set_archived(&chat, false, false).unwrap());
    assert_eq!(seq(), 0);
    assert!(hub.set_archived(&chat, true, false).unwrap());
    let at = tag(&chat, ARCHIVED_TAG).unwrap();
    assert_eq!(tag(&chat, ARCHIVED_BY_TAG), None);
    // Archived again by hand: unchanged, the first time kept.
    let logged = seq();
    assert!(!hub.set_archived(&chat, true, false).unwrap());
    assert_eq!(seq(), logged);
    assert_eq!(tag(&chat, ARCHIVED_TAG), Some(at));
    hub.shutdown_all().await;
}

#[tokio::test]
async fn any_other_change_of_the_archive_drops_the_automatic_marker() {
    let hub = hub();
    let chat = chat(&hub, "c", "idle", 1, json!({}));
    assert!(hub.set_archived(&chat, true, true).unwrap());
    let at = tag(&chat, ARCHIVED_TAG).unwrap();
    // Archived by hand after: the same archive, now the person's.
    assert!(hub.set_archived(&chat, true, false).unwrap());
    assert_eq!(tag(&chat, ARCHIVED_TAG), Some(at));
    assert_eq!(tag(&chat, ARCHIVED_BY_TAG), None);
    // An unarchive through `_acpmux/tag`, as the chat menu's sends it, drops it too.
    assert!(hub.set_archived(&chat, true, true).unwrap());
    hub.set_tags_answered(&chat, None, &[ARCHIVED_TAG.to_owned()], None).unwrap();
    assert_eq!(tag(&chat, ARCHIVED_BY_TAG), None);
    // And an archive set through it.
    assert!(hub.set_archived(&chat, true, true).unwrap());
    let mut set = serde_json::Map::new();
    set.insert(ARCHIVED_TAG.into(), json!("9"));
    hub.set_tags_answered(&chat, Some(&set), &[], None).unwrap();
    assert_eq!(tag(&chat, ARCHIVED_BY_TAG), None);
    hub.shutdown_all().await;
}
