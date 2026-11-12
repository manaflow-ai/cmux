//! A whole session list goes to every connection in pages of at most [`MOST_LIST_REPLY_BYTES`]
//! (`list_reply.rs`'s `LIST_PAGE_BYTES`), each with the `nextCursor` of the rest. On 2026-11-06
//! one Mac (about 500 chats) sent a 24.8 MB `_acpmux/watch` list to a local Web connection
//! about once a minute for hours. On 2026-11-11 the same Mac's agent panes and app feeds, then
//! still read their list in one reply up to the message limit, were sent 31 MB watch replies
//! about seven times a minute while the app sat at 100% CPU ("im at 100% cpu rn"). The detector
//! here fails if any list reply, on any connection, passes a few megabytes.

use crate::config::{Config, StoreMode};
use crate::peer::{Peer, PeerNotice};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

use super::Origin;

/// The most one list reply may hold, on any connection: a few megabytes, never the message
/// limit. Fixed here rather than read from `list_reply.rs`, so raising that bound fails this.
const MOST_LIST_REPLY_BYTES: usize = 4 << 20;

/// This daemon's own chats: a few pages of every list (about 2.6 MB of census rows, about
/// 3 MB of ACP rows), past one page of each, and no more. Each page past the first can wait
/// for a list build and its pace: 3,000 chats with 10 KB titles (66 ACP pages) took this file's
/// detector 1,605 s in a debug build on hosted Linux (run 43145234111).
const OWN: usize = 1_200;
/// Past the census row's title cut (`hub/views.rs` `TITLE_CHARS`), so the cut is on the path.
const TITLE_BYTES: usize = 300;
/// A chat mirrored from the peer `box`.
const MIRRORED: &str = "box-chat";

/// The most a reply line adds to its result: the frame's id and envelope.
const FRAME: usize = 256;

async fn hub() -> Arc<crate::hub::Hub> {
    hub_of(OWN, TITLE_BYTES, "idle").await
}

/// A hub with `chats` of its own, each titled `title` bytes long and `status`, and one chat
/// mirrored from its peer `box`.
async fn hub_of(chats: usize, title: usize, status: &str) -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    for i in 0..chats {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": format!("own-{i}"), "name": format!("own-{i}"),
            "title": "t".repeat(title), "harness": "fake", "cwd": "/tmp", "status": status,
            "createdAt": 1, "updatedAt": i + 1
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    let hub = crate::hub::Hub::new(config, store);
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("box".to_owned(), peer.clone());
    let row = json!({"sessionId": MIRRORED, "name": "lane", "status": "idle", "updatedAt": 5});
    let mut settled = peer.settled();
    for notice in [PeerNotice::Sessions(vec![row]), PeerNotice::Connected] {
        hub.peer_notices.send(("box".to_owned(), peer.generation, notice)).await.unwrap();
    }
    tokio::time::timeout(Duration::from_secs(10), settled.wait_for(|n| *n >= 1))
        .await
        .expect("the hub applies the notices")
        .unwrap();
    hub
}

struct Client {
    input: mpsc::Sender<String>,
    outgoing: mpsc::Receiver<String>,
    id: u64,
}

impl Client {
    async fn on(hub: &Arc<crate::hub::Hub>, origin: Origin) -> Self {
        let (input, incoming) = mpsc::channel(8);
        let (output, outgoing) = mpsc::channel(64);
        tokio::spawn(super::serve_connection_with(hub.clone(), incoming, output, origin));
        let mut client = Self { input, outgoing, id: 0 };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "test", "version": "0"}});
        client.call(method::INITIALIZE, hello).await;
        client
    }

    /// The reply to `m`, the size of its line, and how long it took.
    async fn call(&mut self, m: &str, params: Value) -> (Value, usize, Duration) {
        self.id += 1;
        let id = self.id;
        let asked = Instant::now();
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let line = self.outgoing.recv().await.unwrap();
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == id {
                    assert!(reply.get("error").is_none(), "{m}: {}", &line[..line.len().min(400)]);
                    return (reply["result"].clone(), line.len(), asked.elapsed());
                }
            }
        })
        .await
        .expect("the reply comes")
    }

    /// The whole watch list as a paging client reads it (`_acpmux/watch`, then
    /// `_acpmux/sessions {cursor}`): every id, and each reply line's size.
    async fn whole_watch(&mut self) -> (Vec<String>, Vec<usize>) {
        self.whole(method::MUX_WATCH, json!({"enabled": true})).await
    }

    /// The whole list read from `m {params}` on, then by `_acpmux/sessions {cursor}`.
    async fn whole(&mut self, m: &str, params: Value) -> (Vec<String>, Vec<usize>) {
        let (mut page, size, _) = self.call(m, params).await;
        let (mut ids, mut sizes, mut seen) = (Vec::new(), vec![size], HashSet::new());
        loop {
            for row in page["sessions"].as_array().expect("a page lists sessions") {
                ids.push(row["sessionId"].as_str().unwrap().to_owned());
            }
            let Some(cursor) = page["nextCursor"].as_str().map(str::to_owned) else { break };
            assert!(seen.insert(cursor.clone()), "the cursor {cursor} came twice");
            let (next, size, _) = self.call(method::MUX_SESSIONS, json!({"cursor": cursor})).await;
            (page, sizes) = (next, [sizes, vec![size]].concat());
        }
        (ids, sizes)
    }
}

fn sorted(mut ids: Vec<String>) -> Vec<String> {
    ids.sort_unstable();
    ids
}

fn own_ids() -> Vec<String> {
    sorted((0..OWN).map(|i| format!("own-{i}")).collect())
}

/// This daemon's own chats and the one mirrored from `box`.
fn every_id() -> Vec<String> {
    sorted([own_ids(), vec![MIRRORED.to_owned()]].concat())
}

#[tokio::test(flavor = "multi_thread")]
async fn a_web_connection_reads_a_large_whole_list_in_bounded_pages() {
    let hub = hub().await;
    let mut web = Client::on(&hub, Origin::Web).await;
    let (ids, sizes) = web.whole_watch().await;
    assert!(sizes.len() > 1, "a list past one page goes in pages: {sizes:?}");
    assert!(sizes.iter().all(|s| *s <= MOST_LIST_REPLY_BYTES + FRAME), "{sizes:?}");
    // Every row once: the pages neither skip nor repeat one.
    assert_eq!(sorted(ids), every_id());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_peer_link_reads_its_own_rows_in_bounded_pages() {
    let hub = hub().await;
    let mut link = Client::on(&hub, Origin::Peer).await;
    let (ids, sizes) = link.whole_watch().await;
    assert!(sizes.len() > 1, "{sizes:?}");
    assert!(sizes.iter().all(|s| *s <= MOST_LIST_REPLY_BYTES + FRAME), "{sizes:?}");
    // Every row once, the mirrored one too: each page has the same rows as the first
    // (the link drops the mirrored ones on each page itself, `watch_sessions`).
    assert_eq!(sorted(ids), every_id());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_peer_link_reads_a_whole_sessions_list_in_bounded_pages() {
    let hub = hub().await;
    let mut link = Client::on(&hub, Origin::Peer).await;
    let (ids, sizes) = link.whole(method::MUX_SESSIONS, json!({})).await;
    assert!(sizes.len() > 1, "{sizes:?}");
    assert!(sizes.iter().all(|s| *s <= MOST_LIST_REPLY_BYTES + FRAME), "{sizes:?}");
    assert_eq!(sorted(ids), every_id());
}

/// The detector: every list method, on every connection, answers a list past one page (this
/// daemon's few pages; one Mac's was 34 MB on 2026-11-11) in replies of at most
/// [`MOST_LIST_REPLY_BYTES`], none of them skipped or repeated. The app's own connections (the
/// Unix socket's feeds, the agent pane's) included: they were the ones sent 31 MB replies.
#[tokio::test(flavor = "multi_thread")]
async fn no_list_reply_passes_a_few_megabytes_on_any_connection() {
    let hub = hub().await;
    for origin in [Origin::Local, Origin::LocalApp, Origin::Web, Origin::Peer] {
        let mut client = Client::on(&hub, origin).await;
        let reads = [
            (method::MUX_WATCH, json!({"enabled": true})),
            (method::MUX_WATCH, json!({"enabled": true, "withTools": true})),
            (method::MUX_SESSIONS, json!({})),
        ];
        for (m, params) in reads {
            let (ids, sizes) = client.whole(m, params.clone()).await;
            assert!(sizes.len() > 1, "{origin:?} {m} {params}: a list past one page goes in pages");
            let most = sizes.iter().max().copied().unwrap_or_default();
            assert!(most <= MOST_LIST_REPLY_BYTES + FRAME, "{origin:?} {m} {params}: {most} bytes");
            assert_eq!(sorted(ids), every_id(), "{origin:?} {m} {params}");
        }
        // ACP's `session/list`, its cursor followed by `session/list` itself.
        let (mut page, size, _) = client.call(method::SESSION_LIST, json!({})).await;
        let (mut sizes, mut ids) = (vec![size], Vec::new());
        loop {
            for row in page["sessions"].as_array().expect("a session/list page lists sessions") {
                ids.push(row["sessionId"].as_str().expect("a row has its id").to_owned());
            }
            let Some(cursor) = page["nextCursor"].as_str().map(str::to_owned) else { break };
            assert!(sizes.len() < 1_000, "{origin:?} session/list never ends");
            let (next, size, _) =
                client.call(method::SESSION_LIST, json!({"cursor": cursor})).await;
            (page, sizes) = (next, [sizes, vec![size]].concat());
        }
        assert!(sizes.len() > 1, "{origin:?} session/list: a list past one page goes in pages");
        // Every own chat once, and no id this daemon does not list.
        let unique: HashSet<&String> = ids.iter().collect();
        assert_eq!(unique.len(), ids.len(), "{origin:?} session/list repeated a row");
        let known: HashSet<String> = every_id().into_iter().collect();
        assert!(ids.iter().all(|id| known.contains(id)), "{origin:?} session/list: an unknown id");
        let skipped = own_ids().into_iter().find(|id| !unique.contains(id));
        assert_eq!(skipped, None, "{origin:?} session/list skipped a row");
        let most = sizes.iter().max().copied().unwrap_or_default();
        assert!(most <= MOST_LIST_REPLY_BYTES + FRAME, "{origin:?} session/list: {most} bytes");
    }
}

/// Bench: bytes and time of the first watch reply, and of the whole list read in pages, on a Web
/// connection against the app's own one (both paged now; the app's read its list in one reply
/// up to the message limit before), on about 9,000 closed chats (a whole list of about 15 MB;
/// summaries cap their titles). It asserts only that each reply comes within `Client::call`'s
/// 60 s: a debug build took 42 to 53 s in the lib's parallel run beside 16 busy loops on 8 CPUs,
/// and 65 to 67 s in 2 of 10, so it is a check for its own run, one test at a time:
/// `cargo test -p acpmux --lib server::list_web_page_tests::list_web_page_bench -- --ignored --exact --test-threads=1 --nocapture`.
/// The default run checks what the paging holds by bytes and ids, on 3,000 chats:
/// `a_web_connection_reads_a_large_whole_list_in_bounded_pages` (every page under the bound,
/// every row once), the two peer-link tests, and `no_list_reply_passes_a_few_megabytes_on_any_connection`.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "own run, one test at a time: a bench, 15 MB through a debug build within a 60 s reply wait"]
async fn list_web_page_bench() {
    let hub = hub_of(9_000, 2_600, "closed").await;
    let mut local = Client::on(&hub, Origin::Local).await;
    let _ = local.call(method::MUX_SESSIONS, json!({"limit": 1})).await;
    let (_, whole_bytes, whole_time) =
        local.call(method::MUX_WATCH, json!({"enabled": true})).await;
    let mut web = Client::on(&hub, Origin::Web).await;
    let (_, first_bytes, first_time) = web.call(method::MUX_WATCH, json!({"enabled": true})).await;
    let started = Instant::now();
    let (ids, sizes) = web.whole_watch().await;
    let paged_time = started.elapsed();
    println!(
        "PERF watch rows={} one_reply bytes={whole_bytes} ms={:.1} | web first_page bytes={first_bytes} ms={:.1} | web all_pages pages={} bytes={} ms={:.1}",
        ids.len(),
        whole_time.as_secs_f64() * 1000.0,
        first_time.as_secs_f64() * 1000.0,
        sizes.len(),
        sizes.iter().sum::<usize>(),
        paged_time.as_secs_f64() * 1000.0,
    );
}
