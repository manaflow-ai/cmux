//! `_acpmux/attach` from a phone's kept copy (`AgentTranscriptCache`): the phone reads on from
//! its kept cursor tail-first (`afterSeq` and `beforeSeq`), shows the newest page, and fills the
//! gap behind it. Its rows then end as a clean open's: every record once, in seq order. A cursor
//! past the log's end is not this log's, and the reply says `reset`.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use crate::store::{LocalStore, SessionMeta, Store};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const ID: &str = "kept-chat";
/// A small page so "10 pages behind" stays a quick test; the phone's is 400 (`AcpmuxHub.pageSize`).
const PAGE: u64 = 12;
/// `AcpmuxHub.tailBeforeSeq`: past any seq.
const TAIL: u64 = 1 << 40;

fn hub(sessions: &std::path::Path) -> Arc<crate::hub::Hub> {
    let writer = LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap();
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": ID, "name": "kept", "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 3, "updatedAt": 3,
    }))
    .unwrap();
    writer.save(&meta).unwrap();
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    crate::hub::Hub::new(
        config,
        Box::new(LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap()),
    )
}

/// One turn: its prompt, an answer, its result (three records).
fn turn(hub: &crate::hub::Hub, n: u64) {
    let s = hub.resolve(ID).unwrap();
    hub.append(
        &s,
        "mux",
        "user_message",
        json!({"text": format!("prompt {n}"), "turnId": format!("t{n}")}),
    );
    hub.append(
        &s,
        "in",
        "session/update",
        json!({"method": "session/update", "params": {"sessionId": ID, "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("answer {n}")}}}}),
    );
    hub.append(
        &s,
        "mux",
        "turn_result",
        json!({"status": "completed", "turnId": format!("t{n}"), "turnSeq": n}),
    );
}

/// One request's result on a new connection.
async fn call(hub: &Arc<crate::hub::Hub>, name: &str, params: Value) -> Value {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(4096);
    tokio::spawn(super::super::serve_connection_with(
        hub.clone(),
        incoming,
        output,
        super::super::Origin::Local,
    ));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "kept-test", "version": "0"}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    input.send(Message::request(2, name, params).to_line()).await.unwrap();
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let reply: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
            if reply["id"] == 2 {
                assert!(reply.get("error").is_none(), "{reply}");
                return reply["result"].clone();
            }
        }
    })
    .await
    .expect("the request answers")
}

/// The phone's first open (`AcpmuxHub.readPages`, `firstAttach`).
fn open() -> Value {
    json!({"sessionId": ID, "limit": PAGE, "maxBytes": 131072, "toolOutputMaxBytes": 65536,
        "kinds": ["transcript"], "eventStream": true})
}

/// The phone's catch-up from its kept cursor, tail-first (`allowGap`).
fn from_kept(after: u64) -> Value {
    let mut params = open();
    params["afterSeq"] = json!(after);
    params["beforeSeq"] = json!(TAIL);
    params
}

fn seqs(events: &Value) -> Vec<u64> {
    events.as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect()
}

fn is_prompt(event: &Value) -> bool {
    event["kind"] == "user_message"
}

/// Every record of the log, oldest first, as a clean open then scrolling up to the top reads it.
async fn whole_log(hub: &Arc<crate::hub::Hub>) -> Vec<u64> {
    let mut all = Vec::new();
    let mut after = 0;
    loop {
        let page = call(
            hub,
            method::MUX_EVENTS,
            json!({"sessionId": ID, "afterSeq": after,
            "limit": PAGE, "kinds": ["transcript"]}),
        )
        .await;
        let got = seqs(&page["events"]);
        all.extend(&got);
        match got.last() {
            Some(&last) if page["hasMore"] == true => after = last,
            _ => return all,
        }
    }
}

/// What the phone ends with after a kept copy through `kept_last` and a tail-first catch-up:
/// the kept records, the gap's records filled behind (`startGapFill`, before the newest page's
/// first prompt), then the newest page from that prompt (`tailStart`). Also the reply.
async fn catch_up(hub: &Arc<crate::hub::Hub>, kept: &[u64]) -> (Vec<u64>, Value) {
    let kept_last = *kept.last().unwrap();
    let reply = call(hub, method::MUX_ATTACH, from_kept(kept_last)).await;
    let page = reply["events"].as_array().unwrap().clone();
    let mut rows = kept.to_vec();
    let first = page.first().and_then(|e| e["seq"].as_u64());
    if reply["hasMore"] != true || first.is_none_or(|f| f == kept_last + 1) {
        // Nothing missing before the page: it joins the kept rows as it is.
        rows.extend(seqs(&Value::Array(page)));
        return (rows, reply);
    }
    let start = page.iter().position(is_prompt).expect("the newest page holds a prompt");
    let end = page[start]["seq"].as_u64().unwrap();
    let mut cursor = kept_last;
    while cursor + 1 < end {
        let fill = call(
            hub,
            method::MUX_EVENTS,
            json!({"sessionId": ID, "afterSeq": cursor,
            "limit": PAGE, "maxBytes": 262144, "kinds": ["transcript"]}),
        )
        .await;
        let got: Vec<u64> = seqs(&fill["events"]).into_iter().filter(|&s| s < end).collect();
        let Some(&last) = got.last() else { break };
        rows.extend(&got);
        cursor = last;
        if fill["hasMore"] != true {
            break;
        }
    }
    rows.extend(seqs(&Value::Array(page[start..].to_vec())));
    (rows, reply)
}

/// A kept copy 1, 2 and 10 pages behind ends with the same rows as a clean open of the whole log,
/// and the first read shows the newest records (one round trip after the link, no drop).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kept_copy_behind_by_pages_catches_up_to_a_clean_opens_rows() {
    for behind in [1u64, 2, 10] {
        let dir = std::env::temp_dir().join(format!("acpmux-kept-cursor-{}", uuid::Uuid::now_v7()));
        let hub = hub(&dir.join("sessions"));
        for n in 1..=4 {
            turn(&hub, n);
        }
        // What the phone kept: its open of the chat then.
        let kept = seqs(&call(&hub, method::MUX_ATTACH, open()).await["events"]);
        // The Mac goes on: `behind` pages of records (PAGE / 3 turns a page) and one more turn.
        for n in 0..(behind * PAGE / 3 + 1) {
            turn(&hub, 5 + n);
        }
        let last = hub.resolve(ID).unwrap().meta().last_seq;

        let (rows, reply) = catch_up(&hub, &kept).await;
        assert!(reply.get("reset").is_none(), "a cursor in the log is no reset: {reply}");
        assert_eq!(
            reply["newestPage"], true,
            "a tail-first read says its page is the newest: {reply}"
        );
        // The first read is the newest page, through the log's end.
        assert_eq!(seqs(&reply["events"]).last(), Some(&last), "{behind} pages behind: {reply}");
        // Each record once, in seq order, and every record a clean open reads.
        assert!(rows.windows(2).all(|w| w[0] < w[1]), "{behind} pages behind: {rows:?}");
        assert_eq!(rows, whole_log(&hub).await, "{behind} pages behind");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// A kept copy within one page reads on forward and needs no gap.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kept_copy_within_a_page_reads_on_with_no_gap() {
    let dir = std::env::temp_dir().join(format!("acpmux-kept-cursor-{}", uuid::Uuid::now_v7()));
    let hub = hub(&dir.join("sessions"));
    for n in 1..=4 {
        turn(&hub, n);
    }
    let kept = seqs(&call(&hub, method::MUX_ATTACH, open()).await["events"]);
    turn(&hub, 5);
    let (rows, reply) = catch_up(&hub, &kept).await;
    assert_eq!(reply["hasMore"], false, "{reply}");
    assert!(reply.get("reset").is_none(), "{reply}");
    assert_eq!(rows, whole_log(&hub).await);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A kept cursor past the log's end (the chat's history was replaced under its id) is not this
/// log's: the reply says `reset`, and the phone opens fresh instead of reading on.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kept_cursor_past_the_logs_end_says_reset() {
    let dir = std::env::temp_dir().join(format!("acpmux-kept-cursor-{}", uuid::Uuid::now_v7()));
    let hub = hub(&dir.join("sessions"));
    for n in 1..=2 {
        turn(&hub, n);
    }
    let last = hub.resolve(ID).unwrap().meta().last_seq;
    let reply = call(&hub, method::MUX_ATTACH, from_kept(last + 50)).await;
    assert_eq!(reply["reset"], true, "{reply}");
    // At the end exactly is a cursor in the log: nothing new, no reset.
    let reply = call(&hub, method::MUX_ATTACH, from_kept(last)).await;
    assert!(reply.get("reset").is_none(), "{reply}");
    // A forward read (an older phone's reattach) says it too.
    let reply = call(
        &hub,
        method::MUX_ATTACH,
        json!({"sessionId": ID, "afterSeq": last + 1,
        "limit": PAGE, "kinds": ["transcript"]}),
    )
    .await;
    assert_eq!(reply["reset"], true, "{reply}");
    assert!(reply.get("newestPage").is_none(), "a forward read's page is the oldest: {reply}");
    // A first open (no cursor) has nothing to tell apart.
    let reply = call(&hub, method::MUX_ATTACH, open()).await;
    assert!(reply.get("newestPage").is_none(), "{reply}");
    let _ = std::fs::remove_dir_all(&dir);
}
