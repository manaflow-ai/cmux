//! `_acpmux/sessions` and `_acpmux/watch` with no `limit` answer the whole list, and on a daemon
//! that mirrors a fleet that list passes the 15 MiB message limit: one daemon's 5241 rows were
//! 17 MB with tools on 2026-10-30, and about 2.3 KB a row without. Such a list was refused as
//! `message.too_large`. A list too large for one message now goes in pages, each under the limit
//! with the `nextCursor` of the rest, read with `_acpmux/sessions {cursor}`; one that fits is
//! still one reply with no cursor.

use super::serve_connection;
use crate::config::{Config, StoreMode};
use crate::peer::{Peer, PeerNotice};
use crate::rpc::{MAX_MESSAGE_BYTES, Message, method};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// A hub mirroring `rows` chats from each of `peers` peers, each with a 3 KB preview and a
/// 3.3 KB tool list.
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
                    "updatedAt": (p * rows + i + 1) as u64, "preview": "p".repeat(3000),
                    "tools": [{"id": "tool", "description": "x".repeat(3300)}]})
            })
            .collect();
        let mut settled = peer.settled();
        for notice in [PeerNotice::Sessions(list), PeerNotice::Connected] {
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

/// One unix-socket connection of `hub`'s.
struct Conn {
    input: mpsc::Sender<String>,
    output: mpsc::Receiver<String>,
    next: i64,
}

impl Conn {
    async fn open(hub: &Arc<crate::hub::Hub>) -> Self {
        let (input, incoming) = mpsc::channel(8);
        let (out, output) = mpsc::channel(64);
        tokio::spawn(serve_connection(hub.clone(), incoming, out));
        let mut conn = Self { input, output, next: 0 };
        conn.call(method::INITIALIZE, json!({"protocolVersion": 1})).await;
        conn
    }

    /// `m`'s result and the bytes of its reply line; it fails the test on an error.
    async fn call(&mut self, m: &str, params: Value) -> (Value, usize) {
        self.next += 1;
        let id = self.next;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let line = self.output.recv().await.unwrap();
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == id {
                    assert!(reply.get("error").is_none(), "{m}: {}", reply["error"]);
                    return (reply["result"].clone(), line.len());
                }
            }
        })
        .await
        .expect("the reply comes")
    }

    /// The list `m` with `params` answers, following `nextCursor` with `_acpmux/sessions`
    /// (the same params, the cursor added): every row, and each reply's bytes.
    async fn whole_list(&mut self, m: &str, params: Value) -> (Vec<Value>, Vec<usize>) {
        let (mut rows, mut sizes) = (Vec::new(), Vec::new());
        let (mut method, mut params) = (m, params);
        loop {
            let (page, bytes) = self.call(method, params.clone()).await;
            sizes.push(bytes);
            rows.extend(page["sessions"].as_array().cloned().unwrap_or_default());
            let Some(next) = page.get("nextCursor").and_then(Value::as_str) else {
                return (rows, sizes);
            };
            assert!(sizes.len() < 100, "the pages never end");
            method = method::MUX_SESSIONS;
            params.as_object_mut().unwrap().remove("enabled");
            params["cursor"] = Value::String(next.to_owned());
        }
    }
}

fn check(what: &str, rows: &[Value], sizes: &[usize], expected: usize, tools: bool) {
    let total: usize = sizes.iter().sum();
    assert!(total > MAX_MESSAGE_BYTES, "{what}: the list is not past the limit: {total} bytes");
    assert!(sizes.iter().all(|s| *s <= MAX_MESSAGE_BYTES), "{what}: pages {sizes:?}");
    let mut seen = HashSet::new();
    for row in rows {
        let id = row["sessionId"].as_str().unwrap();
        assert!(seen.insert(id.to_owned()), "{what}: {id} came twice");
        assert_eq!(row["tools"].is_array(), tools, "{what}: {id}'s tools");
    }
    assert_eq!(seen.len(), expected, "{what}");
    println!("PERF {what} rows={} bytes={total} pages={}", seen.len(), sizes.len());
}

#[tokio::test]
async fn a_fleet_sized_session_list_goes_in_pages_under_the_message_limit() {
    // 25 peers with 210 chats each: 5250 rows, about as many as that daemon listed.
    let hub = fleet_hub(25, 210).await;
    let mut conn = Conn::open(&hub).await;
    let all = 25 * 210;
    let (rows, sizes) = conn.whole_list(method::MUX_SESSIONS, json!({})).await;
    check("sessions", &rows, &sizes, all, false);
    let (rows, sizes) = conn.whole_list(method::MUX_SESSIONS, json!({"withTools": true})).await;
    check("sessions withTools", &rows, &sizes, all, true);
    let filter = json!({"excludeStatus": ["closed"]});
    let (rows, sizes) = conn.whole_list(method::MUX_SESSIONS, filter).await;
    check("sessions filtered", &rows, &sizes, all, false);
    let mut watcher = Conn::open(&hub).await;
    let (rows, sizes) = watcher.whole_list(method::MUX_WATCH, json!({"enabled": true})).await;
    check("watch", &rows, &sizes, all, false);
}

/// A list that fits is one reply with no cursor, newest first, as before paging: with tools,
/// filtered, whole and as a watch's first list.
#[tokio::test]
async fn a_session_list_that_fits_is_one_reply_newest_first_with_no_cursor() {
    let hub = fleet_hub(2, 20).await;
    let mut conn = Conn::open(&hub).await;
    for (m, params) in [
        (method::MUX_SESSIONS, json!({})),
        (method::MUX_SESSIONS, json!({"withTools": true})),
        (method::MUX_SESSIONS, json!({"excludeStatus": ["closed"]})),
        (method::MUX_SESSIONS, json!({"withTools": true, "excludeStatus": ["closed"]})),
        (method::MUX_WATCH, json!({"enabled": true})),
    ] {
        let (page, _) = conn.call(m, params.clone()).await;
        let rows = page["sessions"].as_array().unwrap();
        assert_eq!(rows.len(), 40, "{m} {params}");
        assert!(page.get("nextCursor").is_none(), "{m} {params}: {}", page["nextCursor"]);
        let stamps: Vec<u64> = rows.iter().map(|r| r["updatedAt"].as_u64().unwrap()).collect();
        assert!(stamps.windows(2).all(|w| w[0] >= w[1]), "{m} {params}: not newest first");
    }
}

/// `Client::whole_list` joins a paged list newest first, as one reply lists it, and refuses a
/// cursor that comes again instead of asking for it forever, and one that is not a string
/// instead of returning a short list.
#[cfg(unix)]
#[tokio::test]
async fn whole_list_joins_pages_newest_first_and_refuses_a_repeated_or_bad_cursor() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let dir = cmux_unix_socket::short_test_dir("whole-list");
    let socket = dir.path().join("s");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let server = tokio::spawn(async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let msg: Value = serde_json::from_str(&line).unwrap();
                    let Some(id) = msg.get("id") else { continue };
                    let row = |id: &str, at: u64| json!({"sessionId": id, "updatedAt": at});
                    let loops = msg["params"]["loop"] == true;
                    let bad = msg["params"]["bad"] == true;
                    let result =
                        match (msg["method"].as_str().unwrap(), msg["params"]["cursor"].as_str()) {
                            (method::INITIALIZE, _) => json!({}),
                            (_, None) if bad => {
                                json!({"sessions": [row("old", 1)], "nextCursor": 7})
                            }
                            (_, None) => json!({"sessions": [row("old", 1)], "nextCursor": "h1"}),
                            (_, Some(_)) if loops => json!({"sessions": [], "nextCursor": "h1"}),
                            (_, Some("h1")) => {
                                json!({"sessions": [row("new", 9)], "nextCursor": "h2"})
                            }
                            (_, Some(_)) => json!({"sessions": [row("mid", 5)]}),
                        };
                    let response = json!({"jsonrpc": "2.0", "id": id, "result": result});
                    write.write_all(format!("{response}\n").as_bytes()).await.unwrap();
                }
            });
        }
    });
    let client = crate::client::Client::connect(&socket).await.unwrap();
    let list = client.whole_list(method::MUX_SESSIONS, json!({})).await.unwrap();
    let ids: Vec<&str> = list["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["sessionId"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["new", "mid", "old"]);
    let error = client.whole_list(method::MUX_SESSIONS, json!({"loop": true})).await.unwrap_err();
    assert!(error.to_string().contains("twice"), "{error}");
    let error = client.whole_list(method::MUX_SESSIONS, json!({"bad": true})).await.unwrap_err();
    assert!(error.to_string().contains("page cursor 7"), "{error}");
    server.abort();
}
