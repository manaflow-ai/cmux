//! A finished chat archives itself after its wait, leaves first; a person's unread chat, a chat
//! whose parent is at work, a chat tagged `autoArchive` `off` and one archived by hand stay as
//! they are; a use brings an auto-archived chat back (`hub/auto_archive.rs`).

use super::*;
use crate::config::{Config, StoreMode};

const HOUR: u64 = 3_600_000;

/// A hub whose store holds `chats`: (id, unread, tags), each hibernated (`idle`).
fn hub_with(chats: &[(&str, bool, Value)]) -> (Arc<Hub>, PathBuf) {
    let root = std::env::temp_dir().join(format!("acpmux-auto-archive-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    for (id, unread, tags) in chats {
        let meta = json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2, "unread": unread,
            "tags": tags,
        });
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    }
    drop(store);
    (Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap()), root)
}

fn tags(hub: &Hub, id: &str) -> Vec<String> {
    hub.resolve(id).unwrap().read_meta(|m| m.tags.keys().cloned().collect())
}

fn archived(hub: &Hub, id: &str) -> bool {
    let t = tags(hub, id);
    t.contains(&"archived".to_owned()) && t.contains(&AUTO_ARCHIVED_TAG.to_owned())
}

fn later() -> u64 {
    now_ms() + 7 * HOUR
}

#[tokio::test]
async fn off_by_default_and_nothing_archives() {
    assert_eq!(Config::default().auto_archive_after(), None);
    let (hub, root) = hub_with(&[("a", false, json!({}))]);
    let pass = hub.auto_archive_pass(None, later());
    assert_eq!(pass, Pass::default());
    assert!(!archived(&hub, "a"));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_finished_chat_archives_once_its_wait_is_over() {
    let (hub, root) = hub_with(&[("a", false, json!({}))]);
    // Not yet: the daemon's start counts as a use.
    let soon = hub.auto_archive_pass(Some(6 * HOUR), now_ms() + HOUR);
    assert!(soon.archived.is_empty());
    assert!(soon.next_due.is_some_and(|at| at > now_ms() + 5 * HOUR), "{soon:?}");
    assert!(!archived(&hub, "a"));
    let pass = hub.auto_archive_pass(Some(6 * HOUR), later());
    assert_eq!(pass.archived, vec!["a".to_owned()]);
    assert!(archived(&hub, "a"));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn an_unread_own_chat_stays_and_an_unread_child_does_not() {
    let (hub, root) = hub_with(&[
        ("mine", true, json!({})),
        ("lead", false, json!({})),
        ("lane", true, json!({"spawnedBy": {"value": "lead"}})),
    ]);
    let pass = hub.auto_archive_pass(Some(6 * HOUR), later());
    // The lane first, then its lead, in the same pass.
    assert_eq!(pass.archived, vec!["lane".to_owned(), "lead".to_owned()]);
    assert!(!archived(&hub, "mine"));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_chat_whose_parent_is_at_work_stays_and_so_does_the_parent() {
    let (hub, root) = hub_with(&[
        ("lead", false, json!({})),
        ("lane", false, json!({"spawnedBy": {"value": "lead"}})),
    ]);
    let lead = hub.resolve("lead").unwrap();
    lead.harness_turn.store(true, Ordering::SeqCst);
    let pass = hub.auto_archive_pass(Some(6 * HOUR), later());
    assert!(pass.archived.is_empty(), "{pass:?}");
    lead.harness_turn.store(false, Ordering::SeqCst);
    let pass = hub.auto_archive_pass(Some(6 * HOUR), later());
    assert_eq!(pass.archived, vec!["lane".to_owned(), "lead".to_owned()]);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_chat_s_own_tag_wins() {
    let (hub, root) = hub_with(&[
        ("pinned", false, json!({"autoArchive": {"value": "off"}})),
        ("quick", false, json!({"autoArchive": {"value": "1"}})),
        ("plain", false, json!({})),
    ]);
    // Off for the daemon: only the chat that turned it on for itself archives.
    let pass = hub.auto_archive_pass(None, now_ms() + 2 * HOUR);
    assert_eq!(pass.archived, vec!["quick".to_owned()]);
    let pass = hub.auto_archive_pass(Some(HOUR), later());
    assert_eq!(pass.archived, vec!["plain".to_owned()]);
    assert!(!archived(&hub, "pinned"));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_use_brings_an_auto_archived_chat_back_and_never_a_hand_archived_one() {
    let (hub, root) = hub_with(&[
        ("auto", false, json!({})),
        ("hand", false, json!({"archived": {"value": "5"}})),
    ]);
    let pass = hub.auto_archive_pass(Some(HOUR), later());
    assert_eq!(pass.archived, vec!["auto".to_owned()]);
    for id in ["auto", "hand"] {
        hub.auto_archive_used(&hub.resolve(id).unwrap());
    }
    assert!(tags(&hub, "auto").is_empty(), "{:?}", tags(&hub, "auto"));
    assert_eq!(tags(&hub, "hand"), vec!["archived".to_owned()]);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
