//! What the iPhone reads of a Mac's session list on a connect and on pull to refresh, in one
//! harness (cmuxterm-hq `docs/investigations/2026-11-18-boneheaded-designs.md`, finding 8). The
//! phone reaches acpmux over the Mac's local socket (`cmux-mobile-host`), so its connection is
//! `Origin::Local`.
//!
//! Before: a connect read the newest 100 rows (`_acpmux/watch {limit: 100}`), then every other
//! row in pages of 500 (`_acpmux/sessions {limit: 500, cursor}`, `AcpmuxHub+SessionPages.swift`);
//! pull to refresh read the whole list again (`_acpmux/watch {enabled}` and its byte pages,
//! `AcpmuxConnection.wholeList`). Both cost every chat. After: a connect with rows kept, and a
//! refresh, send `_acpmux/watch {afterSeq, listEpoch}` and read only the rows changed since
//! (`row_log.rs`): their cost is the changes, whatever the list's size.

use super::*;

/// A title of this many bytes makes a summary row about the 3,046 B the audit measured on a
/// lane's 250 rows.
const TITLE_BYTES: usize = 2_400;

/// A hub with `chats` idle chats of its own, each titled as a working chat is.
async fn phone_hub(chats: usize) -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    for n in 0..chats {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": format!("chat-{n}"), "name": format!("chat-{n}"),
            "title": format!("{n} {}", "t".repeat(TITLE_BYTES)), "harness": "fake", "cwd": "/tmp",
            "status": "idle", "createdAt": 1, "updatedAt": 1 + n as u64
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    let hub = Hub::new(config, store);
    // The daemon sorts its kept order once when it loads (`Hub::load_logs`).
    let _ = hub.own_rows_from(None, 0);
    hub
}

/// The result of `m` and the bytes of the line that carried it.
async fn call_sized(client: &mut Client, m: &str, params: Value) -> (Value, usize) {
    let id = client.next;
    client.next += 1;
    client.input.send(Message::request(id, m, params).to_line()).await.unwrap();
    tokio::time::timeout(Duration::from_secs(60), async {
        loop {
            let line = client.output.recv().await.unwrap();
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == id {
                assert!(message.get("error").is_none(), "{m}: {message}");
                return (message["result"].clone(), line.len());
            }
        }
    })
    .await
    .unwrap()
}

/// What one read cost: rows, bytes, requests.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Read {
    rows: usize,
    bytes: usize,
    requests: usize,
}

impl Read {
    fn add(&mut self, reply: &Value, bytes: usize) {
        self.rows += reply["sessions"].as_array().map_or(0, Vec::len);
        self.bytes += bytes;
        self.requests += 1;
    }
}

fn cursor_of(reply: &Value) -> Option<String> {
    reply["nextCursor"].as_str().map(str::to_owned)
}

/// The phone's connect before the fix: the first 100 rows, then pages of 500 until whole.
async fn connect_before(client: &mut Client) -> (Read, u64, Value) {
    let mut read = Read::default();
    let (first, bytes) =
        call_sized(client, method::MUX_WATCH, json!({"enabled": true, "limit": 100})).await;
    read.add(&first, bytes);
    let (seq, epoch) = (first["listSeq"].as_u64().unwrap(), first["listEpoch"].clone());
    let mut next = cursor_of(&first);
    while let Some(cursor) = next {
        let (page, bytes) =
            call_sized(client, method::MUX_SESSIONS, json!({"limit": 500, "cursor": cursor})).await;
        read.add(&page, bytes);
        next = cursor_of(&page);
    }
    (read, seq, epoch)
}

/// The phone's pull to refresh before the fix (`AcpmuxConnection.wholeList`).
async fn refresh_before(client: &mut Client) -> Read {
    let mut read = Read::default();
    let (mut reply, bytes) = call_sized(client, method::MUX_WATCH, json!({"enabled": true})).await;
    read.add(&reply, bytes);
    while let Some(cursor) = cursor_of(&reply) {
        let (page, bytes) =
            call_sized(client, method::MUX_SESSIONS, json!({"cursor": cursor})).await;
        read.add(&page, bytes);
        reply = page;
    }
    read
}

/// A connect with rows kept, or a pull to refresh, after the fix: the rows changed since
/// `after`, followed while the log says `more`. Returns the cost and the new cursor.
async fn follow(client: &mut Client, mut after: u64, epoch: &Value) -> (Read, u64) {
    let mut read = Read::default();
    loop {
        let params = json!({"enabled": true, "afterSeq": after, "listEpoch": epoch});
        let (reply, bytes) = call_sized(client, method::MUX_WATCH, params).await;
        assert_eq!(reply["follow"], true, "the log follows the phone's cursor: {reply}");
        read.add(&reply, bytes);
        after = reply["listSeq"].as_u64().unwrap();
        if reply["more"] != true {
            return (read, after);
        }
    }
}

fn change(hub: &Hub, chats: usize, k: usize, round: usize) {
    for n in 0..k {
        record(hub, &format!("chat-{}", (round * k + n) % chats), "renamed");
    }
}

/// The detector: a phone's reconnect and its pull to refresh after the same changes read the
/// same rows and about the same bytes from a Mac with 50 chats and one with 5,000. A phone read
/// that grows with the Mac's list fails here.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_phones_reconnect_and_refresh_read_only_the_changes_whatever_the_lists_size() {
    const K: usize = 3;
    let mut costs = Vec::new();
    for chats in [50, 5_000] {
        let hub = phone_hub(chats).await;
        let mut phone = Client::new(&hub, Origin::Local).await;
        let (whole, seq, epoch) = connect_before(&mut phone).await;
        assert_eq!(whole.rows, chats, "the first connect read the list");
        drop(phone);
        // Away: K chats change. Back: a reconnect follows from the kept cursor.
        change(&hub, chats, K, 0);
        let mut phone = Client::new(&hub, Origin::Local).await;
        let (reconnect, seq) = follow(&mut phone, seq, &epoch).await;
        // Pull to refresh after K more.
        change(&hub, chats, K, 1);
        let (refresh, _) = follow(&mut phone, seq, &epoch).await;
        costs.push((chats, reconnect, refresh));
    }
    let [(_, small_connect, small_refresh), (_, god_connect, god_refresh)] = costs[..] else {
        unreachable!()
    };
    for (what, small, god) in
        [("reconnect", small_connect, god_connect), ("refresh", small_refresh, god_refresh)]
    {
        assert_eq!((small.rows, god.rows), (K, K), "{what} reads the {K} changed rows only");
        assert_eq!(small.requests, god.requests, "{what}: one request whatever the list's size");
        // Row ids differ in length by a few digits; the list's size adds nothing.
        assert!(
            god.bytes <= small.bytes + 64 * K,
            "{what} read {} B at 5,000 chats and {} B at 50: it grows with the list",
            god.bytes,
            small.bytes
        );
    }
}

fn median(mut samples: Vec<Duration>) -> Duration {
    samples.sort_unstable();
    samples[samples.len() / 2]
}

/// The before and after numbers: bytes, rows, requests and wall time of a phone's connect and
/// pull to refresh, at 100 chats and 10,000, with 1 and 20 chats changed meanwhile.
/// `cargo test -p acpmux --release --lib phone_list_bench -- --ignored --nocapture`
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: prints the before and after numbers"]
async fn phone_list_bench() {
    const RUNS: usize = 9;
    for chats in [100, 10_000] {
        let hub = phone_hub(chats).await;
        let (mut connect, mut refresh, mut connect_ms, mut refresh_ms) =
            (Read::default(), Read::default(), Vec::new(), Vec::new());
        let (mut seq, mut epoch) = (0, Value::Null);
        for round in 0..RUNS {
            change(&hub, chats, 1, round);
            let mut phone = Client::new(&hub, Origin::Local).await;
            let started = Instant::now();
            (connect, seq, epoch) = connect_before(&mut phone).await;
            connect_ms.push(started.elapsed());
            change(&hub, chats, 1, round + 1);
            let started = Instant::now();
            refresh = refresh_before(&mut phone).await;
            refresh_ms.push(started.elapsed());
        }
        eprintln!(
            "PERF phone before chats={chats}: connect {} rows {} B {} requests median {:?}; refresh {} rows {} B {} requests median {:?}; row avg {} B",
            connect.rows,
            connect.bytes,
            connect.requests,
            median(connect_ms),
            refresh.rows,
            refresh.bytes,
            refresh.requests,
            median(refresh_ms),
            connect.bytes / connect.rows.max(1),
        );
        for k in [1, 20] {
            let (mut connect, mut refresh, mut connect_ms, mut refresh_ms) =
                (Read::default(), Read::default(), Vec::new(), Vec::new());
            for round in 0..RUNS {
                change(&hub, chats, k, round);
                let mut phone = Client::new(&hub, Origin::Local).await;
                let started = Instant::now();
                (connect, seq) = follow(&mut phone, seq, &epoch).await;
                connect_ms.push(started.elapsed());
                change(&hub, chats, k, round + RUNS);
                let started = Instant::now();
                (refresh, seq) = follow(&mut phone, seq, &epoch).await;
                refresh_ms.push(started.elapsed());
            }
            eprintln!(
                "PERF phone after chats={chats} changed={k}: connect {} rows {} B {} requests median {:?}; refresh {} rows {} B {} requests median {:?}",
                connect.rows,
                connect.bytes,
                connect.requests,
                median(connect_ms),
                refresh.rows,
                refresh.bytes,
                refresh.requests,
                median(refresh_ms),
            );
        }
    }
}
