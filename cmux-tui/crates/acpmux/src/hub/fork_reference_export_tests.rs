//! A fork by reference moved to another machine keeps its history: the bundle's log holds the
//! chat's records and its meta names no chat the other machine lacks (`transfer.rs` `export`,
//! `import_into`; `store/fork_view.rs`). Review of #37020: an imported fork whose meta still named
//! its chat showed none of its history there.

use super::*;

fn memory_hub() -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["true"]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    Hub::new(config, store)
}

fn meta(id: &str, history_from: Option<crate::store::HistoryRef>) -> SessionMeta {
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    meta.history_from = history_from;
    meta
}

fn texts(hub: &Hub, id: &str) -> Vec<String> {
    hub.store
        .events(id, 0, usize::MAX)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "user_message")
        .filter_map(|e| e.msg.get("text").and_then(Value::as_str).map(str::to_owned))
        .collect()
}

#[tokio::test]
async fn an_exported_fork_by_reference_keeps_its_history_on_the_other_machine() {
    let dir = std::env::temp_dir().join(format!("acpmux-fork-ref-export-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let source = memory_hub();
    source.store.save(&meta("chat", None)).unwrap();
    let chat = source.make_session(meta("chat", None));
    source.append(&chat, "mux", "created", json!({"harness": "fake"}));
    source.append(&chat, "mux", "user_message", json!({"text": "from the chat"}));
    let through = chat.meta().last_seq;
    // The chat goes on past the fork: none of that is the fork's.
    source.append(&chat, "mux", "user_message", json!({"text": "after the fork"}));

    let reference = crate::store::HistoryRef { session: "chat".into(), through_seq: through };
    let mut fork_meta = meta("fork", Some(reference));
    fork_meta.last_seq = through;
    source.store.save(&fork_meta).unwrap();
    let fork = source.make_session(fork_meta);
    source.append(&fork, "mux", "forked", json!({"parentId": "chat", "forkSeq": through}));
    source.append(&fork, "mux", "user_message", json!({"text": "the fork's own"}));
    assert_eq!(texts(&source, "fork"), ["from the chat", "the fork's own"]);

    let bundle = source.export(&fork, &dir).unwrap();
    let written: Value =
        serde_json::from_str(&std::fs::read_to_string(bundle.join("session.json")).unwrap())
            .unwrap();
    assert!(written.get("historyFrom").is_none(), "the bundle names the source's chat");

    let here = memory_hub();
    let imported = here.import(&bundle, None).await;
    let _ = std::fs::remove_dir_all(&dir);
    let imported = imported.unwrap();
    assert!(imported.meta().history_from.is_none());
    // Its log keeps the chat's seqs through the fork's, and its meta says so (Edit and resend).
    assert_eq!(imported.meta().history_kept_through, Some(through));
    assert_eq!(texts(&here, &imported.id), ["from the chat", "the fork's own"]);
}

/// A delete refused because a fork of the chat is still being made leaves the chat as it was: not
/// marked purged, still listed, and what it writes after is kept (review of #37020 at c840d41: the
/// refusal came after `purged`, and the chat's later records went nowhere).
#[tokio::test]
async fn a_delete_refused_for_a_fork_being_made_leaves_the_chat_usable() {
    let hub = memory_hub();
    hub.store.save(&meta("chat", None)).unwrap();
    let chat = hub.make_session(meta("chat", None));
    hub.sessions.lock().unwrap().insert(chat.id.clone(), chat.clone());
    hub.append(&chat, "mux", "user_message", json!({"text": "before"}));
    let reference =
        crate::store::HistoryRef { session: "chat".into(), through_seq: chat.meta().last_seq };
    // A fork reserved and not saved yet.
    hub.store.reserve_reference("fork", &reference).unwrap();
    assert!(hub.kill(&chat, true).await.is_err(), "the chat went before its fork held the history");
    assert!(!chat.purged.load(Ordering::SeqCst), "the chat was marked purged");
    assert!(hub.sessions.lock().unwrap().contains_key("chat"));
    hub.append(&chat, "mux", "user_message", json!({"text": "after"}));
    assert_eq!(texts(&hub, "chat"), ["before", "after"]);
    // Once the fork is saved, the delete goes, and the fork keeps the history.
    hub.store.save(&meta("fork", Some(reference))).unwrap();
    hub.kill(&chat, true).await.unwrap();
    assert!(hub.store.load("chat").unwrap().is_none());
    assert_eq!(texts(&hub, "fork"), ["before"]);
}

/// While a chat's delete holds its fence, a new fork of it is refused, not left reading a chat
/// that is going (review of #37020 at c840d41).
#[tokio::test]
async fn a_fork_asked_while_its_chat_is_fenced_is_refused() {
    let hub = memory_hub();
    hub.store.save(&meta("chat", None)).unwrap();
    let reference = crate::store::HistoryRef { session: "chat".into(), through_seq: 0 };
    let fence = crate::store::fence_history(hub.store.as_ref(), "chat").unwrap();
    assert!(hub.store.reserve_reference("fork", &reference).is_err());
    drop(fence);
    hub.store.reserve_reference("fork", &reference).unwrap();
}
