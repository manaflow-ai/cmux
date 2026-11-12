//! The settled view on a hub over a store on disk (cmuxterm-hq#9655 stage 1): written for the
//! pane's page shape, read back whole, answered only for that shape and chat, never replaced by
//! an older one.

use super::*;
use crate::hub::settled_view::{FILE, SettledKey, fork_seqs};
use crate::store::{LocalStore, SessionMeta, Store};

fn root(name: &str) -> PathBuf {
    let root =
        std::env::temp_dir().join(format!("acpmux-settled-view-{}-{name}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    root
}

fn hub(sessions: &Path) -> Arc<Hub> {
    let writer = LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap();
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat", "harness": "claude",
        "cwd": "/work/repo", "status": "idle", "createdAt": 7, "updatedAt": 7,
    }))
    .unwrap();
    writer.save(&meta).unwrap();
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg, Box::new(LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap()))
}

/// One ended turn: its prompt, its answer and its result.
fn turn(hub: &Hub, session: &Session, n: u64, status: &str) {
    hub.append(session, "mux", "user_message", json!({"text": format!("prompt {n}")}));
    hub.append(
        session,
        "in",
        "session/update",
        json!({"method": "session/update", "params": {"sessionId": "chat", "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("answer {n}")}}}}),
    );
    hub.append(
        session,
        "mux",
        "turn_result",
        json!({"status": status, "turnId": format!("t{n}"), "turnSeq": n}),
    );
}

fn key() -> SettledKey {
    SettledKey::of_attach(&json!({"kinds": ["transcript"], "limit": 400, "maxBytes": 131072}))
        .unwrap()
}

#[test]
fn a_key_is_the_newest_pages_shape_only() {
    let k = key();
    assert_eq!(k.limit, 400);
    assert_eq!(k.max_bytes, 131072);
    assert_eq!(k.kinds, json!(["transcript"]));
    assert!(SettledKey::of_attach(&json!({"afterSeq": 3, "limit": 400})).is_none());
    assert!(SettledKey::of_attach(&json!({"beforeSeq": 3, "limit": 400})).is_none());
    assert!(SettledKey::of_attach(&json!({"limit": 401})).is_none(), "more than one open page");
    // The default limit (2000) is past what a view holds.
    assert!(SettledKey::of_attach(&json!({})).is_none());
}

#[test]
fn a_view_is_written_beside_the_log_and_read_back_whole() {
    let dir = root("written");
    let sessions = dir.join("sessions");
    let hub = hub(&sessions);
    let session = hub.resolve("chat").unwrap();
    turn(&hub, &session, 1, "completed");
    turn(&hub, &session, 2, "failed");
    turn(&hub, &session, 3, "cancelled");
    assert!(hub.write_settled_view(&session, &key()));
    assert!(sessions.join("chat").join(FILE).is_file(), "kept beside the log");

    let view = hub.settled_view(&session).expect("read back");
    assert_eq!(view.last_seq, session.meta().last_seq);
    assert_eq!(view.created_at, 7);
    assert_eq!(view.key, key());
    assert!(!view.has_more);
    assert!(view.answers(&session, &key()));
    // The records are the newest page of the asked kinds, oldest first, through the log's end.
    let seqs: Vec<u64> = view.records.iter().map(|r| r.seq).collect();
    assert!(!seqs.is_empty());
    assert!(seqs.windows(2).all(|w| w[0] < w[1]), "{seqs:?}");
    assert_eq!(*seqs.last().unwrap(), view.last_seq);
    // A failed turn forks through nothing; the completed and the cancelled ones do.
    assert_eq!(view.fork_seqs, fork_seqs(&view.records));
    assert_eq!(view.fork_seqs.len(), 2, "{:?}", view.fork_seqs);
    assert_eq!(view.queue, json!([]));
    assert_eq!(view.pending, json!([]));
}

#[test]
fn a_view_answers_only_its_own_shape_and_chat() {
    let dir = root("answers");
    let sessions = dir.join("sessions");
    let hub = hub(&sessions);
    let session = hub.resolve("chat").unwrap();
    turn(&hub, &session, 1, "completed");
    assert!(hub.write_settled_view(&session, &key()));
    let view = hub.settled_view(&session).unwrap();

    let other = SettledKey::of_attach(
        &json!({"kinds": ["transcript", "usage"], "limit": 400, "maxBytes": 131072}),
    )
    .unwrap();
    assert!(!view.answers(&session, &other), "another page shape");
    let mut remade = view.clone();
    remade.created_at = 8;
    assert!(!remade.answers(&session, &key()), "a chat made again under the same id");
    let mut ahead = view.clone();
    ahead.last_seq = session.meta().last_seq + 1;
    assert!(!ahead.answers(&session, &key()), "records the log no longer holds");
    // Records logged since leave it standing: the open sends them after it.
    turn(&hub, &session, 2, "completed");
    assert!(view.answers(&session, &key()));
}

#[test]
fn a_view_never_replaces_a_newer_one_and_a_turn_end_writes_it_again() {
    let dir = root("newer");
    let sessions = dir.join("sessions");
    let hub = hub(&sessions);
    let session = hub.resolve("chat").unwrap();
    turn(&hub, &session, 1, "completed");
    assert!(hub.write_settled_view(&session, &key()));
    // Nothing logged since: the saved view is as new, nothing is written.
    assert!(!hub.write_settled_view(&session, &key()));

    turn(&hub, &session, 2, "completed");
    // No runtime here: the turn end writes in place, for the key the view was saved with.
    hub.settle_view_at_turn_end(&session);
    let view = hub.settled_view(&session).unwrap();
    assert_eq!(view.last_seq, session.meta().last_seq);
    assert_eq!(view.fork_seqs.len(), 2);
}

#[test]
fn a_chat_no_pane_opened_settled_writes_no_view_at_turn_end() {
    let dir = root("none");
    let sessions = dir.join("sessions");
    let hub = hub(&sessions);
    let session = hub.resolve("chat").unwrap();
    turn(&hub, &session, 1, "completed");
    hub.settle_view_at_turn_end(&session);
    assert!(!sessions.join("chat").join(FILE).exists());
    assert!(hub.settled_view(&session).is_none());
}

#[test]
fn a_view_holds_at_most_one_page() {
    let dir = root("capped");
    let sessions = dir.join("sessions");
    let hub = hub(&sessions);
    let session = hub.resolve("chat").unwrap();
    for n in 0..20 {
        turn(&hub, &session, n, "completed");
    }
    let small =
        SettledKey::of_attach(&json!({"kinds": ["transcript"], "limit": 10, "maxBytes": 131072}))
            .unwrap();
    assert!(hub.write_settled_view(&session, &small));
    let view = hub.settled_view(&session).unwrap();
    assert_eq!(view.records.len(), 10);
    assert!(view.has_more);
    assert_eq!(view.records.last().unwrap().seq, view.last_seq);
}
