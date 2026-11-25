//! ACP's `session/list` on a daemon that mirrors a fleet: one daemon's list was 5241 rows with
//! tools, 17 MB (2026-10-30), over the 15 MiB message limit, so the whole list came back as
//! `message.too_large`. A list too large for one message goes in pages (ACP's `cursor` and
//! `nextCursor`), each under the limit; one that fits is still sent whole.

use crate::config::{Config, StoreMode};
use crate::peer::{Peer, PeerNotice};
use crate::rpc::{MAX_MESSAGE_BYTES, Message, method};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// A hub mirroring `rows` chats from each of `peers` peers, each with a tool list of about 3.4 KB.
async fn fleet_hub(peers: usize, rows: usize) -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    for p in 0..peers {
        let name = format!("peer-{p}");
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new(&name, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
        let list = (0..rows)
            .map(|i| {
                json!({"sessionId": format!("{name}-chat-{i}"), "name": format!("chat-{i}"),
                    "harness": "claude", "cwd": "/work", "status": "idle",
                    "updatedAt": (p * rows + i + 1) as u64,
                    "tools": [{"id": "tool", "description": "x".repeat(3300)}]})
            })
            .collect();
        let mut settled = peer.settled();
        for notice in [PeerNotice::sessions_from_values(list), PeerNotice::Connected] {
            hub.peer_notices.send((name.clone(), peer.generation, notice)).await.unwrap();
        }
        tokio::time::timeout(Duration::from_secs(10), settled.wait_for(|n| *n >= 1))
            .await
            .expect("the hub applies the notices")
            .unwrap();
    }
    assert_eq!(hub.remote_sessions().len(), peers * rows);
    hub
}

/// Each `session/list` reply line, following `nextCursor` to the end, on one connection, with
/// how long it took.
async fn acp_pages(hub: &Arc<crate::hub::Hub>) -> Vec<(Value, usize, Duration)> {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(8);
    let task = tokio::spawn(super::serve_connection(hub.clone(), incoming, output));
    input
        .send(Message::request(1, method::INITIALIZE, json!({"protocolVersion": 1})).to_line())
        .await
        .unwrap();
    let mut pages = Vec::new();
    let mut params = json!({});
    for id in 2..100 {
        let started = std::time::Instant::now();
        input
            .send(Message::request(id, method::SESSION_LIST, params.clone()).to_line())
            .await
            .unwrap();
        let (reply, bytes) = tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let line = outgoing.recv().await.unwrap();
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == id {
                    return (reply, line.len());
                }
            }
        })
        .await
        .expect("the page comes");
        assert!(reply.get("error").is_none(), "page {}: {}", pages.len(), reply["error"]);
        let next = reply["result"]["nextCursor"].clone();
        pages.push((reply["result"].clone(), bytes, started.elapsed()));
        if !next.is_string() {
            task.abort();
            return pages;
        }
        params = json!({"cursor": next});
    }
    panic!("the pages never end");
}

#[tokio::test]
async fn a_fleet_sized_acp_list_goes_in_pages_under_the_message_limit() {
    // 25 peers with 400 chats each: 10,000 rows, enough to exceed the larger transport limit.
    let hub = fleet_hub(25, 400).await;
    let pages = acp_pages(&hub).await;
    let total: usize = pages.iter().map(|(_, bytes, _)| bytes).sum();
    assert!(total > MAX_MESSAGE_BYTES, "the list is not past the limit: {total} bytes");
    let mut seen = HashSet::new();
    for (page, bytes, _) in &pages {
        assert!(*bytes <= MAX_MESSAGE_BYTES, "a page of {bytes} bytes");
        for row in page["sessions"].as_array().unwrap() {
            assert!(row["_meta"]["acpmux"]["tools"].is_array(), "a row lost its tools: {row}");
            let id = row["sessionId"].as_str().unwrap().to_owned();
            assert!(seen.insert(id.clone()), "{id} came twice");
        }
    }
    assert_eq!(seen.len(), 25 * 400);
    let ms: Vec<u128> = pages.iter().map(|(_, _, took)| took.as_millis()).collect();
    println!("PERF acp_list rows={} bytes={total} pages={} ms={ms:?}", seen.len(), pages.len());
}

#[tokio::test]
async fn an_acp_list_that_fits_is_one_reply_with_no_cursor() {
    let hub = fleet_hub(2, 20).await;
    let pages = acp_pages(&hub).await;
    assert_eq!(pages.len(), 1);
    assert_eq!(pages[0].0["sessions"].as_array().unwrap().len(), 40);
    assert!(pages[0].0.get("nextCursor").is_none(), "{}", pages[0].0["nextCursor"]);
}

/// Bench (ignored; run on a fleet Mac): the cost of each ACP `session/list` page, with the hub
/// quiet between pages and with one change between pages (a peer's chat updated, as a busy fleet
/// does many times a second), at three list sizes, so the growth in pages x rows shows.
/// `cargo test -p acpmux --lib -- --ignored --nocapture acp_list_page_cost`
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a bench: run on a fleet Mac"]
async fn acp_list_page_cost() {
    for (peers, rows) in [(5, 500), (10, 500), (20, 500)] {
        let hub = fleet_hub(peers, rows).await;
        for busy in [false, true] {
            let (input, incoming) = mpsc::channel(8);
            let (output, mut outgoing) = mpsc::channel(8);
            let task = tokio::spawn(super::serve_connection(hub.clone(), incoming, output));
            input
                .send(
                    Message::request(1, method::INITIALIZE, json!({"protocolVersion": 1}))
                        .to_line(),
                )
                .await
                .unwrap();
            let mut params = json!({});
            let mut took = Vec::new();
            let started = std::time::Instant::now();
            for id in 2..1000 {
                if busy {
                    let changed = json!({"sessionId": "peer-0-chat-0", "name": "chat-0",
                        "harness": "claude", "cwd": "/work", "status": "running",
                        "updatedAt": 1_000_000 + id as u64,
                        "tools": [{"id": "tool", "description": "x".repeat(3300)}]});
                    let notice = PeerNotice::SessionChanged {
                        session: changed,
                        kind: "status".into(),
                        seq: id as u64,
                    };
                    let generation = hub.peers.lock().unwrap()["peer-0"].generation;
                    hub.peer_notices.send(("peer-0".into(), generation, notice)).await.unwrap();
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                let page = std::time::Instant::now();
                input
                    .send(Message::request(id, method::SESSION_LIST, params.clone()).to_line())
                    .await
                    .unwrap();
                let reply: Value = loop {
                    let line = outgoing.recv().await.unwrap();
                    let reply: Value = serde_json::from_str(&line).unwrap();
                    if reply["id"] == id {
                        break reply;
                    }
                };
                took.push(page.elapsed());
                assert!(reply.get("error").is_none(), "{}", reply["error"]);
                let next = reply["result"]["nextCursor"].clone();
                if !next.is_string() {
                    break;
                }
                params = json!({"cursor": next});
            }
            task.abort();
            let mut sorted = took.clone();
            sorted.sort();
            println!(
                "PERF acp_list_page_cost rows={} busy={busy} pages={} total={:?} per page: median {:?} max {:?}",
                peers * rows,
                took.len(),
                started.elapsed(),
                sorted[sorted.len() / 2],
                sorted[sorted.len() - 1],
            );
        }
    }
}

/// A client that watches the list and pages an ACP `session/list`: a chat on a later page is
/// renamed after its first page, and the client reads the `_acpmux/session_changed` notice of the
/// rename before it asks for the next page. No later page may show the older name: a page cut
/// from a list built before that notice tells the client a change it already had back out of
/// order (a page reused from an older list did that, merge queue gate t91, 2026-11-12).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_page_after_a_change_notice_shows_that_change() {
    let hub = fleet_hub(10, 500).await;
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(64);
    let task = tokio::spawn(super::serve_connection(hub.clone(), incoming, output));
    let ask = |id: u64, method: &'static str, params: Value| {
        let input = input.clone();
        async move { input.send(Message::request(id, method, params).to_line()).await.unwrap() }
    };
    // Every line up to the reply to `id`; the notices among them go to `heard`.
    async fn until_reply(
        outgoing: &mut mpsc::Receiver<String>,
        id: u64,
        heard: &mut Vec<Value>,
    ) -> Value {
        tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let line: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
                if line["id"] == id {
                    return line;
                }
                if line["method"] == method::MUX_SESSION_CHANGED {
                    heard.push(line["params"]["session"].clone());
                }
            }
        })
        .await
        .expect("the reply comes")
    }
    let mut heard = Vec::new();
    ask(1, method::INITIALIZE, json!({"protocolVersion": 1})).await;
    until_reply(&mut outgoing, 1, &mut heard).await;
    ask(2, method::MUX_WATCH, json!({"enabled": true})).await;
    until_reply(&mut outgoing, 2, &mut heard).await;

    ask(3, method::SESSION_LIST, json!({})).await;
    let first = until_reply(&mut outgoing, 3, &mut heard).await;
    let on_first: HashSet<&str> = first["result"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["sessionId"].as_str().unwrap())
        .collect();
    let (p, i) = (0..10)
        .flat_map(|p| (0..500).map(move |i| (p, i)))
        .find(|(p, i)| !on_first.contains(format!("peer-{p}-chat-{i}").as_str()))
        .expect("a chat past the first page");
    let (peer, chat) = (format!("peer-{p}"), format!("peer-{p}-chat-{i}"));
    let renamed = json!({"sessionId": chat, "name": "renamed", "harness": "claude",
        "cwd": "/work", "status": "idle", "updatedAt": (p * 500 + i + 1) as u64,
        "tools": [{"id": "tool", "description": "x".repeat(3300)}]});
    let generation = hub.peers.lock().unwrap()[&peer].generation;
    let told = format!("{peer}/renamed");
    let notice = PeerNotice::SessionChanged { session: renamed, kind: "name".into(), seq: 1 };
    hub.peer_notices.send((peer, generation, notice)).await.unwrap();
    // The client has the notice of the rename before it asks for the next page.
    tokio::time::timeout(Duration::from_secs(10), async {
        // A peer's row is named with its peer (`peer-0/renamed`).
        while !heard.iter().any(|s| s["sessionId"] == chat.as_str() && s["name"] == told) {
            let line: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
            if line["method"] == method::MUX_SESSION_CHANGED {
                heard.push(line["params"]["session"].clone());
            }
        }
    })
    .await
    .expect("the watcher hears the rename");

    let (mut cursor, mut listed) = (first["result"]["nextCursor"].clone(), None);
    for id in 4..100 {
        assert!(cursor.is_string(), "no page after the first holds {chat}");
        ask(id, method::SESSION_LIST, json!({"cursor": cursor})).await;
        let reply = until_reply(&mut outgoing, id, &mut heard).await;
        assert!(reply.get("error").is_none(), "{}", reply["error"]);
        let rows = reply["result"]["sessions"].as_array().unwrap();
        if let Some(row) = rows.iter().find(|row| row["sessionId"] == chat.as_str()) {
            // An ACP row carries the summary a watcher hears in `_meta.acpmux` (`acp_row`).
            listed = Some(row["_meta"]["acpmux"]["name"].clone());
            break;
        }
        cursor = reply["result"]["nextCursor"].clone();
    }
    task.abort();
    assert_eq!(
        listed,
        Some(json!(told)),
        "{chat} listed with its old name after the notice of its rename"
    );
}

/// A chat added and a chat removed while a client pages an ACP `session/list` (between its
/// first page and the rest): no row comes twice, every chat that was there before and stays
/// comes exactly once, the cursor stays valid to the end (`session_pages::byte_page`: a hash
/// order that a change does not move).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_added_or_removed_between_pages_breaks_no_page() {
    let hub = fleet_hub(10, 500).await;
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(8);
    let task = tokio::spawn(super::serve_connection(hub.clone(), incoming, output));
    input
        .send(Message::request(1, method::INITIALIZE, json!({"protocolVersion": 1})).to_line())
        .await
        .unwrap();
    let row = |name: &str, i: usize, updated: u64| {
        json!({"sessionId": format!("{name}-chat-{i}"), "name": format!("chat-{i}"),
            "harness": "claude", "cwd": "/work", "status": "idle", "updatedAt": updated,
            "tools": [{"id": "tool", "description": "x".repeat(3300)}]})
    };
    let (mut params, mut seen, mut pages) = (json!({}), HashSet::new(), 0);
    for id in 2..100 {
        if id == 3 {
            // peer-0 now holds chats 1..=500 and a new 9999: chat 0 left, chat 9999 came.
            let mut list: Vec<Value> = (1..500).map(|i| row("peer-0", i, (i + 1) as u64)).collect();
            list.push(row("peer-0", 9999, 9_000_000));
            let list = list.iter().map(|row| Arc::<str>::from(row.to_string())).collect();
            let generation = hub.peers.lock().unwrap()["peer-0"].generation;
            hub.peer_notices
                .send(("peer-0".into(), generation, PeerNotice::Sessions(list)))
                .await
                .unwrap();
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        input
            .send(Message::request(id, method::SESSION_LIST, params.clone()).to_line())
            .await
            .unwrap();
        let reply: Value = loop {
            let reply: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
            if reply["id"] == id {
                break reply;
            }
        };
        assert!(reply.get("error").is_none(), "page {pages}: {}", reply["error"]);
        pages += 1;
        for row in reply["result"]["sessions"].as_array().unwrap() {
            let id = row["sessionId"].as_str().unwrap().to_owned();
            assert!(seen.insert(id.clone()), "{id} came twice");
        }
        let next = reply["result"]["nextCursor"].clone();
        if !next.is_string() {
            break;
        }
        params = json!({"cursor": next});
    }
    task.abort();
    assert!(pages > 2, "{pages} pages");
    for p in 0..10 {
        for i in 0..500 {
            let id = format!("peer-{p}-chat-{i}");
            if id != "peer-0-chat-0" {
                assert!(seen.contains(&id), "{id}, there before and after, was not listed");
            }
        }
    }
    let extra: Vec<&String> = seen
        .iter()
        .filter(|id| *id != "peer-0-chat-0" && *id != "peer-0-chat-9999")
        .filter(|id| !id.starts_with("peer-") || !id.contains("-chat-"))
        .collect();
    assert!(extra.is_empty(), "rows no list held: {extra:?}");
}

/// Every page of an ACP `session/list` read, quiet (`busy` false) or with a peer's chat changed
/// before each page (`busy`, as streaming agents change rows many times a second): the read's
/// whole time and its pages. Every row comes once.
async fn timed_read(hub: &Arc<crate::hub::Hub>, busy: bool) -> (Duration, usize) {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(8);
    let task = tokio::spawn(super::serve_connection(hub.clone(), incoming, output));
    input
        .send(Message::request(1, method::INITIALIZE, json!({"protocolVersion": 1})).to_line())
        .await
        .unwrap();
    let (mut params, mut seen, mut pages) = (json!({}), HashSet::new(), 0);
    let started = std::time::Instant::now();
    for id in 2..1000_u64 {
        if busy {
            let changed = json!({"sessionId": "peer-0-chat-0", "name": "chat-0",
                "harness": "claude", "cwd": "/work", "status": "running",
                "updatedAt": 1_000_000 + id,
                "tools": [{"id": "tool", "description": "x".repeat(3300)}]});
            let notice =
                PeerNotice::SessionChanged { session: changed, kind: "status".into(), seq: id };
            let generation = hub.peers.lock().unwrap()["peer-0"].generation;
            hub.peer_notices.send(("peer-0".into(), generation, notice)).await.unwrap();
        }
        input
            .send(Message::request(id, method::SESSION_LIST, params.clone()).to_line())
            .await
            .unwrap();
        let reply: Value = loop {
            let reply: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
            if reply["id"] == id {
                break reply;
            }
        };
        assert!(reply.get("error").is_none(), "{}", reply["error"]);
        pages += 1;
        for row in reply["result"]["sessions"].as_array().unwrap() {
            assert!(seen.insert(row["sessionId"].as_str().unwrap().to_owned()), "{row} twice");
        }
        let next = reply["result"]["nextCursor"].clone();
        if !next.is_string() {
            break;
        }
        params = json!({"cursor": next});
    }
    task.abort();
    assert_eq!(seen.len(), hub.remote_sessions().len(), "every chat once");
    (started.elapsed(), pages)
}

/// A paged ACP `session/list` of 10,000 rows with tools is read in a few seconds, quiet or busy,
/// not pages times the whole list: before the list's pacer was removed (#42131) a quiet read took
/// 18 s and a busy one 68-98 s (39 pages, each waiting a pacing window or building every row;
/// aws-m4pro-2, 2026-11-12). The bound is loose for a loaded host; the growth it guards is 10x.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_paged_acp_list_costs_about_one_list_quiet_or_busy() {
    let hub = fleet_hub(20, 500).await;
    let (quiet, pages) = timed_read(&hub, false).await;
    let (busy, busy_pages) = timed_read(&hub, true).await;
    assert!(pages >= 30 && busy_pages >= 30, "{pages} / {busy_pages} pages");
    println!("ACP session/list 10,000 rows: quiet {quiet:?} ({pages} pages), busy {busy:?}");
    assert!(quiet < Duration::from_secs(10), "a quiet paged read took {quiet:?}");
    assert!(
        busy < quiet * 4 + Duration::from_secs(2),
        "a busy paged read took {busy:?}, against {quiet:?} quiet: a page costs the whole list"
    );
}
