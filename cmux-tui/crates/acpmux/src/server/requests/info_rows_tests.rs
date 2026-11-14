//! `_acpmux/info` with `sessionIds`: the session list's rows by key, equal once parsed to the
//! rows `_acpmux/sessions` lists, bounded, and a peer's row read here with nothing sent on its
//! link; and `_acpmux/status`'s `closedListed` and `closedRemoteListed`.

use crate::config::{Config, StoreMode};
use crate::hub::Hub;
use crate::rpc::{Message, method};
use crate::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const PEER_CHAT: &str = "0190f2a4-7c1e-7d3a-9f00-00000000c4a7";
const PEER_CLOSED: &str = "0190f2a4-7c1e-7d3a-9f00-00000000c4a8";

fn memory_hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

fn session(hub: &Hub, n: usize, status: &str) -> String {
    let id = crate::god_fixture::chat_id(n);
    let mut meta = crate::god_fixture::session_meta(
        &id,
        &format!("chat-{n}"),
        "/work",
        &crate::god_fixture::agent_session_id(n),
        400,
        1_791_540_000_000 + n as u64,
    );
    meta["status"] = Value::from(status);
    hub.insert_test_session(serde_json::from_value(meta).unwrap());
    id
}

fn peer_rows() -> Vec<Value> {
    vec![
        json!({"sessionId": PEER_CHAT, "name": "lane", "status": "running", "turnCount": 3,
               "updatedAt": 5, "tools": [{"id": "t"}]}),
        json!({"sessionId": PEER_CLOSED, "name": "old", "status": "closed", "updatedAt": 4}),
    ]
}

/// A live row, a closed row, and peer `far`'s rows: a ready link (any request on it would fail,
/// as it has no transport) when `ready`, else a down one whose rows the list marks stale.
fn fixture(ready: bool) -> (Arc<Hub>, Arc<crate::peer::Peer>, String, String) {
    let hub = memory_hub();
    let live = session(&hub, 0, "idle");
    let closed = session(&hub, 1, "closed");
    let peer = hub.seed_down_peer("far", peer_rows());
    if ready {
        hub.seed_peer_back(&peer, peer_rows());
    }
    (hub, peer, live, closed)
}

/// `m` with `params` on a new unix-socket connection to `hub`: its reply line's result (or
/// error) and the line's length.
async fn call(hub: &Arc<Hub>, m: &str, params: Value) -> (Result<Value, Value>, usize) {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
    for line in [Message::request(1, method::INITIALIZE, hello), Message::request(2, m, params)] {
        input.send(line.to_line()).await.unwrap();
    }
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), outgoing.recv()).await;
        let line = line.unwrap().unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap();
        if reply.get("id") == Some(&json!(2)) {
            let result = match reply.get("error") {
                Some(e) => Err(e.clone()),
                None => Ok(reply["result"].clone()),
            };
            return (result, line.len());
        }
    }
}

/// The list's rows by the key `sessionIds` takes: a session id, or `PEER/ID`.
fn listed_by_key(list: &Value) -> HashMap<String, Value> {
    list["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            let id = row["sessionId"].as_str().unwrap();
            let key = match row["peer"].as_str() {
                Some(peer) => format!("{peer}/{id}"),
                None => id.to_owned(),
            };
            (key, row.clone())
        })
        .collect()
}

#[tokio::test]
async fn the_rows_by_key_are_the_lists_rows_once_parsed() {
    for ready in [true, false] {
        let (hub, _, live, closed) = fixture(ready);
        for tools in [false, true] {
            let (list, _) = call(&hub, method::MUX_SESSIONS, json!({"withTools": tools})).await;
            let listed = listed_by_key(&list.unwrap());
            let keys = vec![
                format!("far/{PEER_CHAT}"),
                live.clone(),
                "nobody".to_owned(),
                closed.clone(),
                format!("far/{PEER_CLOSED}"),
            ];
            let (reply, _) = call(
                &hub,
                method::MUX_INFO,
                json!({"sessionIds": keys, "row": true, "withTools": tools}),
            )
            .await;
            let reply = reply.unwrap();
            let rows = reply["rows"].as_array().unwrap();
            let expected: Vec<&Value> =
                keys.iter().filter(|key| *key != "nobody").map(|key| &listed[key]).collect();
            assert_eq!(rows.len(), expected.len(), "{reply}");
            for (row, want) in rows.iter().zip(expected) {
                // The bytes the client reads: the same text once parsed and written again.
                assert_eq!(row.to_string(), want.to_string(), "ready={ready} tools={tools}");
            }
            assert_eq!(reply["missing"], json!(["nobody"]));
            assert_eq!(reply["rest"], json!([]));
            if !ready {
                // A down link's rows are marked as the list marks them.
                assert_eq!(rows[0]["stale"], true, "{}", rows[0]);
            }
        }
    }
}

#[tokio::test]
async fn a_peers_row_by_key_sends_nothing_on_its_link() {
    // A ready link with no transport: a request sent on it would fail as unreachable.
    let (hub, peer, _, _) = fixture(true);
    for _ in 0..3 {
        let (reply, _) = call(
            &hub,
            method::MUX_INFO,
            json!({"sessionIds": [format!("far/{PEER_CHAT}")], "row": true}),
        )
        .await;
        let reply = reply.expect("answered here, from the mirrored row");
        assert_eq!(reply["rows"][0]["sessionId"], PEER_CHAT);
    }
    assert_eq!(peer.pending_requests().await, 0);
}

#[tokio::test]
async fn a_batch_past_its_bounds_is_refused() {
    let (hub, _, live, _) = fixture(false);
    let many: Vec<String> = (0..101).map(|n| format!("k{n}")).collect();
    for params in [
        json!({"sessionIds": many, "row": true}),
        json!({"sessionIds": [], "row": true}),
        json!({"sessionIds": [live.clone()], "sessionId": live.clone(), "row": true}),
        // A peer's chat beside them is refused too, never forwarded to the peer.
        json!({"sessionIds": [live.clone()], "sessionId": format!("far/{PEER_CHAT}"), "row": true}),
        json!({"sessionIds": [live.clone()], "session": live.clone(), "row": true}),
        json!({"sessionIds": [live.clone()], "name": "chat-0", "row": true}),
        json!({"sessionIds": [live.clone()]}),
        json!({"sessionIds": [7], "row": true}),
    ] {
        let (reply, _) = call(&hub, method::MUX_INFO, params.clone()).await;
        let error = reply.expect_err(&params.to_string());
        assert_eq!(error["code"], -32602, "{params}: {error}");
    }
    // A hundred are answered.
    let hundred: Vec<String> = (0..100).map(|n| format!("k{n}")).collect();
    let (reply, _) =
        call(&hub, method::MUX_INFO, json!({"sessionIds": hundred, "row": true})).await;
    assert_eq!(reply.unwrap()["missing"].as_array().unwrap().len(), 100);
}

#[test]
fn a_reply_past_its_bytes_names_the_rest_and_a_second_completes_it() {
    let keys: Vec<String> = (0..5).map(|n| format!("k{n}")).collect();
    let text = |n: usize| -> Option<Arc<str>> {
        (n != 2)
            .then(|| format!("{{\"sessionId\":\"k{n}\",\"pad\":\"{}\"}}", "x".repeat(90)).into())
    };
    let texts: Vec<_> = (0..5).map(text).collect();
    // Two rows fit 250 bytes; a missing key is answered whatever the bytes.
    let first = super::rows_reply(&keys, texts.clone(), 250).unwrap();
    assert_eq!(first["rows"].as_array().unwrap().len(), 2);
    assert_eq!(first["missing"], json!(["k2"]));
    assert_eq!(first["rest"], json!(["k3", "k4"]));
    let rest: Vec<String> = serde_json::from_value(first["rest"].clone()).unwrap();
    let again: Vec<_> = rest.iter().map(|key| text(key[1..].parse().unwrap())).collect();
    let second = super::rows_reply(&rest, again, 250).unwrap();
    assert_eq!(second["rows"].as_array().unwrap().len(), 2);
    assert_eq!(second["rest"], json!([]));
    // A row larger than the bound alone still goes, one a reply.
    let one = super::rows_reply(&keys[..1], texts[..1].to_vec(), 10).unwrap();
    assert_eq!(one["rows"].as_array().unwrap().len(), 1);
}

#[test]
fn a_row_text_that_is_not_a_row_is_an_error_never_a_null_row() {
    let keys = vec!["a".to_owned(), "b".to_owned()];
    for bad in ["", "null", "[1]", "{\"sessionId\""] {
        let texts = vec![Some(Arc::from("{\"sessionId\":\"a\"}")), Some(Arc::from(bad))];
        let error = super::rows_reply(&keys, texts, 1 << 20).expect_err(bad);
        assert_eq!(error.code, crate::rpc::RpcError::internal("").code, "{bad:?}");
    }
}

#[tokio::test]
async fn status_counts_the_closed_rows_the_list_holds() {
    let (hub, _, _, _) = fixture(true);
    let (status, _) = call(&hub, method::MUX_STATUS, json!({})).await;
    let (list, _) = call(&hub, method::MUX_SESSIONS, json!({})).await;
    let list = list.unwrap();
    let closed: Vec<&Value> =
        list["sessions"].as_array().unwrap().iter().filter(|row| row["status"] == "closed").collect();
    assert_eq!(closed.len(), 2);
    let remote = closed.iter().filter(|row| row["peer"].is_string()).count();
    assert_eq!(remote, 1, "the peer's closed row");
    let status = status.unwrap();
    assert_eq!(status["closedListed"], json!(closed.len()));
    assert_eq!(status["closedRemoteListed"], json!(remote));
    assert!(crate::capabilities::ids().contains(&crate::capabilities::INFO_ROWS));
}

fn p95(values: &mut [u128]) -> u128 {
    values.sort_unstable();
    values[((values.len() * 95).div_ceil(100)).saturating_sub(1)]
}

/// A hub with a hundred live chats, and `closed` closed ones beside them: the hundred's keys.
fn batch_hub(closed: usize) -> (Arc<Hub>, Vec<String>) {
    let hub = memory_hub();
    let keys: Vec<String> = (0..100).map(|n| session(&hub, n, "idle")).collect();
    for n in 0..closed {
        session(&hub, 100 + n, "closed");
    }
    (hub, keys)
}

/// One round of 40 reads of `keys`' rows on `hub`, each asking again for a reply's `rest` as a
/// caller does: each read's wall time and reply bytes.
async fn batch_round(hub: &Arc<Hub>, keys: &[String]) -> (Vec<u128>, Vec<u128>) {
    let (mut times, mut bytes) = (Vec::new(), Vec::new());
    for _ in 0..40 {
        let started = Instant::now();
        let (mut ask, mut rows, mut read) = (keys.to_vec(), 0, 0);
        while !ask.is_empty() {
            let (reply, len) =
                call(hub, method::MUX_INFO, json!({"sessionIds": ask, "row": true})).await;
            let reply = reply.unwrap();
            rows += reply["rows"].as_array().unwrap().len();
            read += len;
            ask = serde_json::from_value(reply["rest"].clone()).unwrap();
        }
        times.push(started.elapsed().as_nanos());
        assert_eq!(rows, 100);
        bytes.push(read as u128);
    }
    (times, bytes)
}

fn emit(name: &str, small: &[Vec<u128>], god: &[Vec<u128>], unit: &str) -> (u128, u128) {
    let best = |rounds: &[Vec<u128>]| {
        rounds.iter().map(|round| p95(&mut round.clone())).min().unwrap_or(0)
    };
    let (small_p95, god_p95) = (best(small), best(god));
    let line =
        json!({"name": name, "small_p95": small_p95, "god_p95": god_p95, "unit": unit}).to_string();
    eprintln!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{line}");
        }
    }
    (small_p95, god_p95)
}

#[ignore = "Linux release gate: 100 keys beside 11,000 closed chats against the same 100 alone"]
#[tokio::test]
async fn v2_pr07b_info_rows() {
    // Both hubs first, then their rounds in turn (decision 185): a slow stretch of the machine
    // lands on both sides.
    let (small, small_keys) = batch_hub(0);
    let (god, god_keys) = batch_hub(11_000);
    let (mut small_times, mut small_bytes, mut god_times, mut god_bytes) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for _ in 0..5 {
        let (times, bytes) = batch_round(&small, &small_keys).await;
        small_times.push(times);
        small_bytes.push(bytes);
        let (times, bytes) = batch_round(&god, &god_keys).await;
        god_times.push(times);
        god_bytes.push(bytes);
    }
    for (name, small, god, unit) in [
        ("v2.pr07b.info_rows_wall", &small_times, &god_times, "ns"),
        ("v2.pr07b.info_rows_bytes", &small_bytes, &god_bytes, "bytes"),
    ] {
        let (small, god) = emit(name, small, god, unit);
        assert!(god.saturating_mul(100) <= small.saturating_mul(120), "{name}: {god} vs {small}");
    }
}

/// What `_acpmux/status` costs with 11,000 closed chats of this daemon's and 11,000 a peer
/// mirrors: its p95 wall time, the best of five rounds of 40. The PR runs it at its head and
/// with the `closedListed` line taken out, for the before and after of that count.
#[ignore = "a measure for the PR's body, not a gate: status beside 22,000 closed rows"]
#[tokio::test]
async fn status_cost_beside_closed_rows() {
    let (hub, _) = batch_hub(11_000);
    let mirrored: Vec<Value> = (0..11_000)
        .map(|n| {
            json!({"sessionId": crate::god_fixture::chat_id(20_000 + n), "name": format!("far-{n}"),
                   "status": "closed", "updatedAt": 1_791_000_000_000_u64 + n as u64})
        })
        .collect();
    let peer = hub.seed_down_peer("far", mirrored.clone());
    hub.seed_peer_back(&peer, mirrored);
    let mut rounds = Vec::new();
    for _ in 0..5 {
        let mut round = Vec::new();
        for _ in 0..40 {
            let started = Instant::now();
            let status = hub.status().await;
            round.push(started.elapsed().as_nanos());
            assert!(status.get("version").is_some());
        }
        rounds.push(round);
    }
    let best = rounds.iter_mut().map(|round| p95(round)).min().unwrap_or(0);
    let line = json!({"name": "status.beside_closed_wall", "p95": best, "unit": "ns"}).to_string();
    eprintln!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{line}");
        }
    }
}
