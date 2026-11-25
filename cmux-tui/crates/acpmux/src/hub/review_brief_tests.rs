//! `_acpmux/review_brief` on a hub over a store on disk: the brief is folded once, saved beside
//! the log, and later opens read only what the chat logged since.

use super::*;
use crate::review_brief::Fold;
use crate::store::{EventRecord, LocalStore, SessionMeta, Store};

const CLAUDE: &str = include_str!("../review_brief_fixtures/claude.ndjson");

fn root(name: &str) -> PathBuf {
    let root =
        std::env::temp_dir().join(format!("acpmux-review-brief-{}-{name}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    root
}

fn hub(sessions: &Path) -> Arc<Hub> {
    let writer = LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap();
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat", "harness": "claude",
        "cwd": "/work/repo", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    writer.save(&meta).unwrap();
    for line in CLAUDE.lines() {
        let rec: EventRecord = serde_json::from_str(line).unwrap();
        writer.append("chat", &rec).unwrap();
    }
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg, Box::new(LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap()))
}

fn pure_brief() -> Value {
    let mut fold = Fold::default();
    for line in CLAUDE.lines() {
        fold.feed(&serde_json::from_str(line).unwrap());
    }
    fold.brief(Some("/work/repo"))
}

#[tokio::test]
async fn a_brief_is_folded_once_saved_beside_the_log_and_read_back_while_nothing_new_is_logged() {
    let dir = root("cached");
    let sessions = dir.join("sessions");
    let hub = hub(&sessions);
    let session = hub.resolve("chat").unwrap();

    let first = hub.review_brief(&session, Some("/work/repo")).unwrap();
    assert_eq!(first["brief"], pure_brief());
    assert_eq!(first["seq"], 17);
    let saved = sessions.join("chat").join(crate::review_brief::FILE);
    assert!(saved.is_file(), "the fold is kept beside the log");

    // Nothing logged since: the saved fold answers, and no record is read. A goal changed in the
    // saved file shows that.
    let mut text: Value = serde_json::from_slice(&std::fs::read(&saved).unwrap()).unwrap();
    text["goal"] = json!("from the saved fold");
    std::fs::write(&saved, serde_json::to_vec(&text).unwrap()).unwrap();
    let again = hub.review_brief(&session, Some("/work/repo")).unwrap();
    assert_eq!(again["brief"]["goal"], "from the saved fold");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_later_open_folds_only_what_the_chat_logged_since() {
    let dir = root("tail");
    let sessions = dir.join("sessions");
    let hub = hub(&sessions);
    let session = hub.resolve("chat").unwrap();
    hub.review_brief(&session, Some("/work/repo")).unwrap();

    let saved = sessions.join("chat").join(crate::review_brief::FILE);
    let mut text: Value = serde_json::from_slice(&std::fs::read(&saved).unwrap()).unwrap();
    text["goal"] = json!("from the saved fold");
    std::fs::write(&saved, serde_json::to_vec(&text).unwrap()).unwrap();

    hub.append(&session, "in", "agent_message_chunk", json!({"jsonrpc": "2.0",
        "method": "session/update", "params": {"sessionId": "s1", "update": {
            "sessionUpdate": "agent_message_chunk", "messageId": "m9",
            "content": {"type": "text", "text": "Hopefully the retry budget in upload.rs is enough."}}}}));
    hub.append(&session, "mux", "turn_result", json!({}));

    let next = hub.review_brief(&session, Some("/work/repo")).unwrap();
    // The saved fold went on from its seq: the changed goal stays, and the new hedge is in.
    assert_eq!(next["brief"]["goal"], "from the saved fold");
    let texts: Vec<&str> = next["brief"]["unsure"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|s| s["text"].as_str())
        .collect();
    assert!(texts.contains(&"Hopefully the retry budget in upload.rs is enough."), "{texts:?}");
    assert!(next["seq"].as_u64().unwrap() > 17);
    let _ = std::fs::remove_dir_all(&dir);
}
