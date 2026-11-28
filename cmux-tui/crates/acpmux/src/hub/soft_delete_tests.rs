//! A deleted chat kept for its grace, restored, and purged once the grace ends
//! (`hub/soft_delete.rs`).

use super::*;
use crate::config::{Config, StoreMode};

struct Root(PathBuf);

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn root() -> Root {
    Root(std::env::temp_dir().join(format!("acpmux-soft-del-{}", uuid::Uuid::now_v7())))
}

const DAY: u64 = 86_400_000;
const RECORDS: u64 = 3;

/// A closed chat with [`RECORDS`] records, saved with `tags`.
fn chat(root: &Path, id: &str, tags: Value) {
    named(root, id, &format!("chat {id}"), tags);
}

/// [`chat`] named `name`.
fn named(root: &Path, id: &str, name: &str, tags: Value) {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, root).unwrap();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": name,
        "harness": "claude", "cwd": "/tmp", "status": "closed", "createdAt": 1,
        "updatedAt": now_ms(), "lastSeq": RECORDS, "eventCount": RECORDS, "tags": tags,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    for seq in 1..=RECORDS {
        let record = EventRecord {
            seq,
            at: now_ms(),
            dir: "mux".into(),
            kind: "user_message".into(),
            msg: json!({"text": format!("question {seq}")}),
            host_seq: None,
        };
        store.append(id, &record).unwrap();
    }
    store.close_log(id);
    store.flush().unwrap();
}

fn open(root: &Path) -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    Hub::new(cfg.clone(), crate::store::open(&cfg.store, root).unwrap())
}

fn why() -> crate::close_why::CloseWhy {
    crate::close_why::CloseWhy::by("app", "deleted in a test")
}

fn listed(hub: &Hub, id: &str) -> bool {
    hub.kept_order_for_test().iter().any(|row| row == id)
}

fn deleted_ids(hub: &Hub) -> Vec<String> {
    hub.deleted_chats()["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["sessionId"].as_str().unwrap().to_owned())
        .collect()
}

fn texts(hub: &Hub, id: &str) -> Vec<String> {
    hub.store
        .events(id, 0, 100)
        .unwrap()
        .into_iter()
        .filter_map(|r| r.msg["text"].as_str().map(str::to_owned))
        .collect()
}

#[tokio::test]
async fn a_deleted_chat_is_restored_inside_its_grace_with_its_whole_log() {
    let root = root();
    chat(&root.0, "keep", json!({}));
    let hub = open(&root.0);
    let dir = hub.store.session_path("keep").unwrap();
    let before = texts(&hub, "keep");
    assert_eq!(before.len(), RECORDS as usize);
    assert!(listed(&hub, "keep"));

    let s = hub.resolve("keep").unwrap();
    let reply = hub.soft_delete(&s, Default::default(), why()).await.unwrap();
    assert_eq!(reply["deleted"], true, "{reply}");
    assert_eq!(reply["purged"], false, "{reply}");
    let until = reply["restorableUntil"].as_u64().unwrap();
    let at = reply["deletedAt"].as_u64().unwrap();
    assert_eq!(until - at, 7 * DAY, "a 7-day grace");

    // Gone from every list and lookup, kept on disk.
    assert!(hub.resolve("keep").is_err(), "deleted: not found");
    assert!(!listed(&hub, "keep"), "deleted: off the list");
    assert_eq!(deleted_ids(&hub), ["keep"]);
    assert!(dir.exists(), "its folder stays through the grace");
    assert_eq!(texts(&hub, "keep"), before, "its log stays through the grace");

    // A restart keeps it deleted.
    hub.shutdown_all().await;
    drop(hub);
    let hub = open(&root.0);
    assert!(hub.resolve("keep").is_err(), "still deleted after a restart");
    assert!(!listed(&hub, "keep"));
    assert_eq!(deleted_ids(&hub), ["keep"]);

    // Restored by its name, with its whole log.
    let restored = hub.undelete("chat keep").unwrap();
    assert_eq!(restored["undeleted"], true, "{restored}");
    assert_eq!(restored["sessionId"], "keep", "{restored}");
    let s = hub.resolve("keep").expect("restored: found");
    assert!(listed(&hub, "keep"), "restored: listed again");
    assert!(deleted_ids(&hub).is_empty());
    assert_eq!(texts(&hub, "keep"), before, "restored with its whole log");
    let tags = s.meta().tags;
    assert!(!tags.contains_key(soft_delete::DELETED_TAG), "{tags:?}");
    assert!(!tags.contains_key(soft_delete::DELETED_UNTIL_TAG), "{tags:?}");
    // A second restore finds nothing to restore.
    let again = hub.undelete("keep").unwrap_err();
    assert_eq!(again.data.unwrap()["reason"], "session.not_deleted");
    // And no purge pass takes it any more.
    assert_eq!(hub.purge_deleted_chats_at(now_ms() + 8 * DAY).await, 0);
    assert!(dir.exists());

    // A restart keeps it restored.
    hub.shutdown_all().await;
    drop(hub);
    let hub = open(&root.0);
    assert!(hub.resolve("keep").is_ok(), "still restored after a restart");
    assert!(listed(&hub, "keep"));
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_deleted_chat_is_purged_once_its_grace_ends() {
    let root = root();
    chat(&root.0, "gone", json!({}));
    chat(&root.0, "other", json!({}));
    let hub = open(&root.0);
    let dir = hub.store.session_path("gone").unwrap();
    let s = hub.resolve("gone").unwrap();
    hub.soft_delete(&s, Default::default(), why()).await.unwrap();

    // Inside the grace: kept.
    assert_eq!(hub.purge_deleted_chats_at(now_ms() + 6 * DAY).await, 0);
    assert!(dir.exists());
    // Past it: purged through the delete, folder and all.
    assert_eq!(hub.purge_deleted_chats_at(now_ms() + 8 * DAY).await, 1);
    assert!(!dir.exists(), "its folder is gone from disk");
    assert!(hub.resolve("gone").is_err());
    assert!(!listed(&hub, "gone"));
    assert!(deleted_ids(&hub).is_empty());
    let late = hub.undelete("gone").unwrap_err();
    assert_eq!(late.data.unwrap()["reason"], "session.not_deleted");
    assert!(hub.resolve("other").is_ok(), "another chat is kept");
    hub.shutdown_all().await;
    drop(hub);
    let hub = open(&root.0);
    assert!(hub.resolve("gone").is_err(), "a restart brings nothing back");
    assert!(deleted_ids(&hub).is_empty());
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_chat_past_its_grace_at_start_is_not_restored_and_the_next_pass_purges_it() {
    let root = root();
    let past = (now_ms() - DAY).to_string();
    let tags = json!({
        soft_delete::DELETED_TAG: {"value": (now_ms() - 8 * DAY).to_string()},
        soft_delete::DELETED_UNTIL_TAG: {"value": past},
    });
    chat(&root.0, "late", tags);
    let hub = open(&root.0);
    let dir = hub.store.session_path("late").unwrap();
    assert!(hub.resolve("late").is_err(), "a deleted chat stays out of the map at start");
    assert!(!listed(&hub, "late"));
    let refused = hub.undelete("late").unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "session.restore_expired");
    assert_eq!(deleted_ids(&hub), ["late"], "still kept for its purge");
    assert_eq!(hub.purge_deleted_chats().await, 1);
    assert!(!dir.exists());
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_restored_chat_whose_name_was_taken_comes_back_suffixed() {
    let root = root();
    chat(&root.0, "first", json!({}));
    let hub = open(&root.0);
    let s = hub.resolve("first").unwrap();
    hub.soft_delete(&s, Default::default(), why()).await.unwrap();
    hub.shutdown_all().await;
    drop(hub);
    // A new chat takes its name meanwhile.
    named(&root.0, "second", "chat first", json!({}));
    let hub = open(&root.0);
    assert_eq!(hub.resolve("second").unwrap().meta().name, "chat first");
    let restored = hub.undelete("first").unwrap();
    assert_eq!(restored["name"], "chat first-2", "{restored}");
    assert_eq!(hub.resolve("second").unwrap().meta().name, "chat first", "the new chat keeps it");
    assert!(hub.resolve("first").is_ok());
    hub.shutdown_all().await;
}

/// Over the socket: a client that does not ask for the grace (every older one) still deletes at
/// once, one that asks keeps the chat, and `session/delete` takes `grace` too.
#[tokio::test]
async fn over_the_socket_an_old_delete_is_at_once_and_a_new_one_is_restorable() {
    let root = root();
    for id in ["old-client", "new-client", "acp-delete"] {
        chat(&root.0, id, json!({}));
    }
    let hub = open(&root.0);
    let dirs: Vec<PathBuf> = ["old-client", "new-client", "acp-delete"]
        .iter()
        .map(|id| hub.store.session_path(id).unwrap())
        .collect();
    let sock = cmux_unix_socket::short_test_dir("acpmux-softdel");
    let path = sock.path().join("d.sock");
    let listener = crate::server::bind_unix(&path).await.unwrap();
    tokio::spawn(crate::server::serve_unix(hub.clone(), listener));
    let client = crate::client::Client::connect(&path).await.unwrap();
    assert!(client.daemon_lists(soft_delete::FEATURE), "the daemon lists the capability");

    let old = client
        .request(crate::rpc::method::MUX_KILL, json!({"sessionId": "old-client", "purge": true}))
        .await
        .unwrap();
    assert_eq!(old, json!({"sessionId": "old-client", "purged": true}), "today's reply");
    assert!(!dirs[0].exists(), "an old client's delete is at once");

    let new = client
        .request(
            crate::rpc::method::MUX_KILL,
            json!({"sessionId": "new-client", "purge": true, "grace": true}),
        )
        .await
        .unwrap();
    assert_eq!(new["deleted"], true, "{new}");
    assert!(dirs[1].exists());

    let acp = client
        .request(
            crate::rpc::method::SESSION_DELETE,
            json!({"sessionId": "acp-delete", "grace": true}),
        )
        .await
        .unwrap();
    assert_eq!(acp["deleted"], true, "{acp}");
    assert!(dirs[2].exists());

    let list = client.request(crate::rpc::method::MUX_DELETED, json!({})).await.unwrap();
    assert_eq!(list["sessions"].as_array().unwrap().len(), 2, "{list}");
    let back = client
        .request(crate::rpc::method::MUX_UNDELETE, json!({"sessionId": "new-client"}))
        .await
        .unwrap();
    assert_eq!(back["undeleted"], true, "{back}");
    assert!(hub.resolve("new-client").is_ok());
    hub.shutdown_all().await;
}
