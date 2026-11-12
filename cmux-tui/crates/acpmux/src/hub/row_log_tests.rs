//! The session list's row log: positions, a follow from a cursor, and a reconnect storm that
//! reads the changes and never the list (cmuxterm-hq `docs/design/acpmux-session-list-row-log.md`).

use super::*;
use crate::config::{Config, StoreMode};
use crate::peer::{Peer, PeerNotice};
use crate::rpc::{Message, method};
use crate::server::{Origin, serve_connection_with};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

fn own(id: &str) -> RowKey {
    RowKey::Own(id.to_owned())
}

#[test]
fn a_row_changed_again_keeps_only_its_newest_position() {
    let mut log = RowLog::default();
    assert_eq!(log.stamp(own("a"), false), 1);
    assert_eq!(log.stamp(own("b"), false), 2);
    assert_eq!(log.stamp(own("a"), false), 3);
    assert_eq!(log.len(), (2, 0), "one entry a row, however often it changed");
    let since = log.since(1).unwrap();
    let keys: Vec<_> =
        since.rows.iter().map(|(seq, key, gone)| (*seq, key.clone(), *gone)).collect();
    assert_eq!(keys, [(2, own("b"), false), (3, own("a"), false)]);
    assert_eq!(since.head, 3);
    assert!(log.since(3).unwrap().rows.is_empty(), "nothing after the head");
    assert!(log.since(4).is_none(), "a cursor past the head is another run's");
    // A row that went is a removal, until it comes back.
    log.stamp(own("b"), true);
    assert_eq!(log.since(3).unwrap().rows, [(4, own("b"), true)]);
    log.stamp(own("b"), false);
    assert_eq!(log.len(), (2, 0));
}

#[test]
fn removals_past_the_bound_raise_the_floor_and_older_cursors_reset() {
    let mut log = RowLog::default();
    for n in 0..GONE_MOST + 10 {
        log.stamp(own(&format!("c{n}")), true);
    }
    assert_eq!(log.len(), (0, GONE_MOST));
    assert!(log.since(9).is_none(), "a cursor before the oldest removal kept may have missed one");
    assert_eq!(log.since(10).unwrap().rows.len(), GONE_MOST);
}

#[test]
fn a_list_reply_says_the_position_it_is_current_to() {
    let text = with_cursor(r#"{"sessions":[]}"#, 7, "e1", false);
    assert_eq!(text, r#"{"listEpoch":"e1","listSeq":7,"sessions":[]}"#);
    let text = with_cursor("{}", 7, "e1", true);
    let value: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value, json!({"listEpoch": "e1", "listSeq": 7, "reset": true}));
}

fn chat(id: &str, updated: u64) -> crate::store::SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id,
        "harness": "fake", "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": updated
    }))
    .unwrap()
}

/// A hub with `chats` closed chats of its own, and `peers` peers of `rows` rows each.
async fn hub_with(chats: usize, peers: usize, rows: usize) -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    for n in 0..chats {
        store.save(&chat(&format!("chat-{n}"), 1 + n as u64)).unwrap();
    }
    let hub = Hub::new(config, store);
    for p in 0..peers {
        let name = format!("peer-{p}");
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new(&name, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
        let list = (0..rows)
            .map(|r| json!({"sessionId": format!("m{r}"), "name": "lane", "status": "idle", "updatedAt": 5}))
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
    hub
}

/// A connection of `origin`, initialized.
struct Client {
    input: mpsc::Sender<String>,
    output: mpsc::Receiver<String>,
    next: u64,
}

impl Client {
    async fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (input, incoming) = mpsc::channel(64);
        let (output, outgoing) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), incoming, output, origin));
        let mut client = Self { input, output: outgoing, next: 1 };
        let hello = json!({"protocolVersion": 1, "clientCapabilities": {},
            "clientInfo": {"name": crate::peer::CLIENT_NAME, "version": "0"}});
        client.call(method::INITIALIZE, hello).await;
        client
    }

    /// The result of `m`, and the notices that came before it.
    async fn call_with_notices(&mut self, m: &str, params: Value) -> (Value, Vec<Value>) {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut notices = Vec::new();
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let line = self.output.recv().await.unwrap();
                let message: Value = serde_json::from_str(&line).unwrap();
                if message["id"] == id {
                    assert!(message.get("error").is_none(), "{m}: {message}");
                    return (message["result"].clone(), notices);
                }
                notices.push(message);
            }
        })
        .await
        .unwrap()
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.call_with_notices(m, params).await.0
    }

    /// The next `session_changed` notice.
    async fn changed(&mut self) -> Value {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let message: Value =
                    serde_json::from_str(&self.output.recv().await.unwrap()).unwrap();
                if message["method"] == method::MUX_SESSION_CHANGED {
                    return message["params"].clone();
                }
            }
        })
        .await
        .unwrap()
    }
}

fn record(hub: &Hub, chat: &str, kind: &str) {
    hub.row_changed_for_test(chat, kind);
}

fn ids(rows: &Value) -> Vec<String> {
    let mut ids: Vec<String> = rows
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| r["sessionId"].as_str().map(str::to_owned))
        .collect();
    ids.sort_unstable();
    ids
}

#[tokio::test]
async fn a_reconnect_follows_from_its_cursor_and_reads_only_what_changed() {
    let hub = hub_with(5, 1, 3).await;
    let mut app = Client::new(&hub, Origin::Local).await;
    let first = app.call(method::MUX_WATCH, json!({"enabled": true, "limit": 2})).await;
    let (head, epoch) = (first["listSeq"].as_u64().unwrap(), first["listEpoch"].clone());
    assert_eq!(epoch, hub.list_cursor().1);
    assert_eq!(first["sessions"].as_array().unwrap().len(), 2, "{first}");
    // A change while it watches: a notice with the next position.
    record(&hub, "chat-1", "renamed");
    let notice = app.changed().await;
    assert_eq!(
        (notice["sessionId"].as_str(), notice["listSeq"].as_u64()),
        (Some("chat-1"), Some(head + 1))
    );
    drop(app);
    // While it is away: two more changes.
    record(&hub, "chat-2", "renamed");
    record(&hub, "chat-3", "titled");
    let mut back = Client::new(&hub, Origin::Local).await;
    let follow = back
        .call(method::MUX_WATCH, json!({"enabled": true, "afterSeq": head + 1, "listEpoch": epoch}))
        .await;
    assert_eq!(follow["follow"], true, "{follow}");
    assert_eq!(ids(&follow["sessions"]), ["chat-2", "chat-3"]);
    assert_eq!(follow["gone"], json!([]));
    assert_eq!(follow["listSeq"].as_u64(), Some(head + 3));
    assert_eq!(follow["more"], false);
    // The watch is on: the next change is a notice.
    record(&hub, "chat-4", "renamed");
    assert_eq!(back.changed().await["listSeq"].as_u64(), Some(head + 4));
    // Nothing changed since: an empty follow.
    let idle = back
        .call(method::MUX_WATCH, json!({"enabled": true, "afterSeq": head + 4, "listEpoch": epoch}))
        .await;
    assert_eq!((ids(&idle["sessions"]).len(), idle["gone"].as_array().map(Vec::len)), (0, Some(0)));
}

#[tokio::test]
async fn a_cursor_of_another_run_reads_the_first_page_marked_reset() {
    let hub = hub_with(3, 0, 0).await;
    let mut app = Client::new(&hub, Origin::Local).await;
    let reply = app
        .call(
            method::MUX_WATCH,
            json!({"enabled": true, "limit": 2, "afterSeq": 0, "listEpoch": "old"}),
        )
        .await;
    assert_eq!(reply["reset"], true, "{reply}");
    assert_eq!(reply["sessions"].as_array().unwrap().len(), 2);
    assert!(reply.get("follow").is_none());
    assert_eq!(reply["listEpoch"], hub.list_cursor().1);
}

#[tokio::test]
async fn a_peer_link_follows_only_this_daemons_own_rows() {
    let hub = hub_with(2, 1, 2).await;
    let (head, epoch) = {
        let (h, e) = hub.list_cursor();
        (h, e.to_owned())
    };
    record(&hub, "chat-0", "renamed");
    hub.announce_remote("peer-0", json!({"sessionId": "m0", "status": "running"}), "status");
    let mut web = Client::new(&hub, Origin::Web).await;
    let mut link = Client::new(&hub, Origin::Peer).await;
    let params = json!({"enabled": true, "afterSeq": head, "listEpoch": epoch});
    let all = web.call(method::MUX_WATCH, params.clone()).await;
    assert_eq!(ids(&all["sessions"]), ["chat-0", "m0"], "{all}");
    let peer_row =
        all["sessions"].as_array().unwrap().iter().find(|r| r["sessionId"] == "m0").unwrap();
    assert_eq!(peer_row["peer"], "peer-0");
    let own = link.call(method::MUX_WATCH, params).await;
    assert_eq!(ids(&own["sessions"]), ["chat-0"], "{own}");
}

/// The storm in the lane's bar: 30 peer links flapping, each reconnect a watch. On base each
/// reconnect read the whole own list through the paced builder; here it is a follow of what
/// changed, never paced and never refused. Prints the bytes and time per reconnect.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_reconnect_storm_of_30_links_never_pages_or_refuses_a_list() {
    let hub = hub_with(525, 0, 0).await;
    let (head, epoch) = {
        let (h, e) = hub.list_cursor();
        (h, e.to_owned())
    };
    let started = Instant::now();
    let mut storms = Vec::new();
    for link in 0..30 {
        let hub = hub.clone();
        let epoch = epoch.clone();
        storms.push(tokio::spawn(async move {
            let (mut bytes, mut cursor) = (0_usize, head);
            for flap in 0..20 {
                // Something changes between flaps, as on a live daemon.
                record(&hub, &format!("chat-{}", (link * 20 + flap) % 525), "renamed");
                let mut client = Client::new(&hub, Origin::Peer).await;
                let reply = client
                    .call(
                        method::MUX_WATCH,
                        json!({"enabled": true, "afterSeq": cursor, "listEpoch": epoch}),
                    )
                    .await;
                assert_eq!(reply["follow"], true, "{reply}");
                bytes += reply.to_string().len();
                cursor = reply["listSeq"].as_u64().unwrap();
            }
            bytes
        }));
    }
    let mut bytes = 0;
    for storm in storms {
        bytes += storm.await.unwrap();
    }
    let elapsed = started.elapsed();
    let mut whole = Client::new(&hub, Origin::Peer).await;
    let list = whole.call(method::MUX_WATCH, json!({"enabled": true})).await.to_string().len();
    eprintln!(
        "PERF storm: 600 reconnects in {:?} ({:?} each), {} bytes each; a whole own list is {list} bytes",
        elapsed,
        elapsed / 600,
        bytes / 600
    );
    assert!(bytes / 600 < list / 5, "a follow reads the changes, not the list");
}

/// A hub with the closed chats `parent`, `child` (spawned by `parent`: its row folds under it)
/// and `other`.
async fn family() -> Arc<Hub> {
    let hub = hub_with(0, 0, 0).await;
    let mut child = chat("child", 2);
    child.tags.insert(
        super::super::views::SPAWNED_BY_TAG.into(),
        crate::store::Tag { value: "parent".into(), expires_at: None },
    );
    for meta in [chat("parent", 1), child, chat("other", 3)] {
        hub.insert_test_session(meta);
    }
    hub
}

fn session(hub: &Hub, id: &str) -> Arc<Session> {
    hub.resolve(id).unwrap()
}

/// The ids of a follow from `after`, sorted.
async fn follow_ids(app: &mut Client, after: u64, epoch: &str) -> Vec<String> {
    let params = json!({"enabled": true, "afterSeq": after, "listEpoch": epoch});
    let follow = app.call(method::MUX_WATCH, params).await;
    assert_eq!(follow["follow"], true, "{follow}");
    ids(&follow["sessions"])
}

/// #42091 F1: a parent's `tags` (or its purge) changes its children's rows, which its record does
/// not name. Each is stamped and told after it, so a client whose cursor is the
/// record's own notice's `listSeq` follows them. Before, the record set a floor at its own
/// position and the log followed that cursor past the children: the client never got them.
#[tokio::test]
async fn a_record_that_reaches_other_rows_tells_them_after_its_own_notice() {
    for kind in ["tags", "purged"] {
        let hub = family().await;
        let epoch = hub.list_cursor().1.to_owned();
        let mut app = Client::new(&hub, Origin::Local).await;
        app.call(method::MUX_WATCH, json!({"enabled": true, "limit": 10})).await;
        hub.append(&session(&hub, "parent"), "mux", kind, json!({}));
        let notice = app.changed().await;
        let named = (notice["sessionId"].as_str(), notice["kind"].as_str());
        assert_eq!(named, (Some("parent"), Some(kind)));
        let at = notice["listSeq"].as_u64().unwrap();
        // A reconnect from the parent's notice follows the child, and only the rows that read it.
        let mut back = Client::new(&hub, Origin::Local).await;
        assert_eq!(follow_ids(&mut back, at, &epoch).await, ["child"], "{kind}");
        // The watcher hears the child's row too, after the parent's.
        let told = app.changed().await;
        assert_eq!(told["sessionId"], "child", "{kind}: {told}");
        assert!(told["listSeq"].as_u64().unwrap() > at, "{kind}: {told}");
    }
}

/// #42091 F2: a child's `created` record changes its parent's row (the child folds under it).
/// The parent is stamped and told, so a follow from before the record sends both. Before,
/// `created` set no floor and stamped only the child: the parent's row stayed as it was.
#[tokio::test]
async fn a_created_child_tells_its_parents_row() {
    let hub = family().await;
    let (head, epoch) = {
        let (h, e) = hub.list_cursor();
        (h, e.to_owned())
    };
    let mut app = Client::new(&hub, Origin::Local).await;
    hub.append(&session(&hub, "child"), "mux", "created", json!({}));
    assert_eq!(follow_ids(&mut app, head, &epoch).await, ["child", "parent"]);
    // A session that comes with no record of its own (moved here, forked) tells it too.
    let (head, _) = hub.list_cursor();
    let mut late = chat("late", 4);
    late.tags.insert(
        super::super::views::SPAWNED_BY_TAG.into(),
        crate::store::Tag { value: "other".into(), expires_at: None },
    );
    hub.insert_test_session(late);
    assert_eq!(follow_ids(&mut app, head, &epoch).await, ["late", "other"]);
}

/// A change no record carries that may reach any row (new usage warning thresholds,
/// `Events::changed`) is a barrier: a cursor before it, the head itself too, reads the first page
/// again (`reset`), and the reset's own `listSeq` follows. Before, it moved no position, and a
/// reconnect followed with an empty patch and kept every row as it was (review of #41865 at
/// 316f5ca, F1).
#[tokio::test]
async fn a_change_that_may_reach_every_row_resets_every_older_cursor() {
    let hub = family().await;
    let (head, epoch) = {
        let (h, e) = hub.list_cursor();
        (h, e.to_owned())
    };
    hub.events.changed();
    let mut app = Client::new(&hub, Origin::Local).await;
    let params = json!({"enabled": true, "limit": 10, "afterSeq": head, "listEpoch": epoch});
    let reply = app.call(method::MUX_WATCH, params).await;
    assert_eq!(reply["reset"], true, "{reply}");
    assert_eq!(ids(&reply["sessions"]), ["child", "other", "parent"]);
    let at = reply["listSeq"].as_u64().unwrap();
    hub.append(&session(&hub, "other"), "mux", "renamed", json!({}));
    assert_eq!(follow_ids(&mut app, at, &epoch).await, ["other"]);
}

#[path = "row_log_bench_tests.rs"]
mod bench;
