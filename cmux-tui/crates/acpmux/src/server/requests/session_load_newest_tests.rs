//! `session/load` of a chat past [`super::session_open::REPLAY_LIMIT`] records replays the newest
//! ones and says how many older ones it left out. It replayed the oldest 100,000 and stopped with
//! no word of it: a long chat's transcript ended days before the chat did.

use super::session_open::REPLAY_LIMIT;
use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use crate::store::{LocalStore, SessionMeta, Store};
use serde_json::{Value, json};
use std::io::Write;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const ID: &str = "long-chat";

/// A chat whose log holds `old` prompts, then filler the replay sends nothing for, then one last
/// prompt: `total` records in all, written as the daemon writes them (one segment, `seq` first).
fn hub(sessions: &std::path::Path, old: u64, total: u64) -> Arc<crate::hub::Hub> {
    let events = sessions.join(ID).join("events");
    std::fs::create_dir_all(&events).unwrap();
    let mut log =
        std::io::BufWriter::new(std::fs::File::create(events.join("000001.ndjson")).unwrap());
    for seq in 1..=total {
        let line = if seq <= old {
            json!({"seq": seq, "at": seq, "dir": "mux", "kind": "user_message", "msg": {"text": format!("old {seq}")}})
        } else if seq == total {
            json!({"seq": seq, "at": seq, "dir": "mux", "kind": "user_message", "msg": {"text": "newest"}})
        } else {
            json!({"seq": seq, "at": seq, "dir": "mux", "kind": "replay_test_filler", "msg": {}})
        };
        writeln!(log, "{line}").unwrap();
    }
    log.flush().unwrap();
    drop(log);
    LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap().save(&meta(total)).unwrap();
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    crate::hub::Hub::new(
        config,
        Box::new(LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap()),
    )
}

fn meta(last_seq: u64) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": ID, "name": "long", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 3, "updatedAt": 3, "lastSeq": last_seq,
    }))
    .unwrap()
}

/// One connection's `session/load`: the replayed prompts' texts, in order, and the answer.
async fn load(hub: &Arc<crate::hub::Hub>) -> (Vec<String>, Value) {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(4096);
    tokio::spawn(super::super::serve_connection_with(
        hub.clone(),
        incoming,
        output,
        super::super::Origin::Local,
    ));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "load-test", "version": "0"}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    let params = json!({"sessionId": ID, "cwd": "/tmp", "mcpServers": []});
    input.send(Message::request(2, method::SESSION_LOAD, params).to_line()).await.unwrap();
    let mut prompts = Vec::new();
    tokio::time::timeout(Duration::from_secs(120), async {
        loop {
            let line = outgoing.recv().await.unwrap();
            let msg: Value = serde_json::from_str(&line).unwrap();
            if msg["id"] == 2 {
                assert!(msg.get("error").is_none(), "{msg}");
                return (prompts, msg["result"].clone());
            }
            let update = &msg["params"]["update"];
            if msg["method"] == method::SESSION_UPDATE
                && update["sessionUpdate"] == "user_message_chunk"
            {
                prompts.push(update["content"]["text"].as_str().unwrap().to_owned());
            }
        }
    })
    .await
    .expect("session/load answers")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_load_past_the_limit_replays_the_newest_records_and_says_how_many_it_left_out() {
    const K: u64 = 7;
    let dir = std::env::temp_dir().join(format!("acpmux-load-newest-{}", uuid::Uuid::now_v7()));
    let total = REPLAY_LIMIT + K;
    let hub = hub(&dir.join("sessions"), K, total);
    let (prompts, answer) = load(&hub).await;
    // The old replay sent `old 1..=7` and stopped before the newest prompt.
    assert_eq!(prompts, vec!["newest".to_owned()], "the replay is not the newest records");
    let truncated = &answer["_meta"]["acpmux"]["replayTruncated"];
    assert_eq!(truncated["skipped"], K, "{answer}");
    assert_eq!(truncated["total"], total, "{answer}");
    assert_eq!(truncated["limit"], REPLAY_LIMIT, "{answer}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_load_within_the_limit_replays_everything_and_says_nothing_is_left_out() {
    let dir = std::env::temp_dir().join(format!("acpmux-load-whole-{}", uuid::Uuid::now_v7()));
    let hub = hub(&dir.join("sessions"), 3, 10);
    let (prompts, answer) = load(&hub).await;
    assert_eq!(prompts, ["old 1", "old 2", "old 3", "newest"]);
    assert!(answer["_meta"]["acpmux"].get("replayTruncated").is_none(), "{answer}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The window read alone, over each store: the newest `n` records before `before`, however the
/// log's seqs run (a compacted log keeps its seqs and drops records between them).
#[test]
fn the_newest_window_counts_records_back_from_the_end() {
    let dir = std::env::temp_dir().join(format!("acpmux-newest-window-{}", uuid::Uuid::now_v7()));
    let sessions = dir.join("sessions");
    let events = sessions.join(ID).join("events");
    std::fs::create_dir_all(&events).unwrap();
    let seqs = [1u64, 2, 5, 9, 10, 11, 20];
    let lines: String = seqs
        .iter()
        .map(|seq| {
            format!("{}\n", json!({"seq": seq, "at": seq, "dir": "mux", "kind": "f", "msg": {}}))
        })
        .collect();
    std::fs::write(events.join("000001.ndjson"), &lines).unwrap();
    let local = LocalStore::new(sessions.clone(), 8 << 20).unwrap();
    let memory = crate::store::MemoryStore::default();
    memory.save(&meta(20)).unwrap();
    for seq in seqs {
        memory
            .append(
                ID,
                &crate::store::EventRecord {
                    seq,
                    at: seq,
                    dir: "mux".into(),
                    kind: "f".into(),
                    msg: json!({}),
                    host_seq: None,
                },
            )
            .unwrap();
    }
    let stores: [(&str, &dyn Store); 2] = [("local", &local), ("memory", &memory)];
    for (name, store) in stores {
        let w = |before, n| store.newest_window(ID, before, n).unwrap();
        assert_eq!((w(u64::MAX, 3).after, w(u64::MAX, 3).newest), (9, 20), "{name}");
        assert_eq!((w(u64::MAX, 7).after, w(u64::MAX, 7).newest), (0, 20), "{name}");
        assert_eq!((w(u64::MAX, 100).after, w(u64::MAX, 100).newest), (0, 20), "{name}");
        assert_eq!((w(11, 2).after, w(11, 2).newest), (5, 10), "{name}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}
