//! `usage_answer.rs`: Session Info's Usage at 1,000 and 10,000 chats, read the way the pane read it
//! before (every page of `_acpmux/sessions {usage: true}`) and by `_acpmux/usage`, on one seeded
//! daemon and one wire handler: a first open, a second open of the same chat, and an open after a
//! chat's usage changed.

use super::*;
use crate::protocol::session::UsageStats;
use std::time::Instant;

/// Chats of this daemon and of one peer that report usage (the last day's), whatever the total.
const WITH_USAGE: usize = 100;
/// What the pane asks per page (`webviews/.../sessionPages.ts` `SESSION_PAGE`).
const PAGE: u64 = 200;

fn stats(tokens: u64) -> UsageStats {
    serde_json::from_value(json!({
        "launcher": "claude", "autocompact": "none", "contextTokens": 1_000,
        "contextWindow": 200_000, "tokens24h": tokens, "updatedAt": 1,
    }))
    .unwrap()
}

/// One peer row; the first `WITH_USAGE` are live (idle) and carry `usageStats` of `tokens`, the
/// rest closed long ago. A chat with the last day's usage is live, as on this daemon, and the hub
/// keeps a peer's live rows and only its newest closed ones (`peer_closed_bound.rs`).
fn peer_row(i: usize, tokens: u64) -> Value {
    let mut row = json!({"sessionId": format!("remote-{i}"), "name": format!("remote-{i}"),
        "harness": "claude", "cwd": "/remote/work", "status": "closed", "updatedAt": i + 1});
    if i < WITH_USAGE {
        row["status"] = json!("idle");
        row["usageStats"] = serde_json::to_value(stats(tokens + i as u64)).unwrap();
    }
    row
}

/// A daemon with `total` chats: half its own (all closed long ago but `WITH_USAGE` open today
/// with stats) and half a peer's (likewise, `WITH_USAGE` of them live with stats).
fn seeded(total: usize) -> (Arc<Hub>, Arc<crate::peer::Peer>) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let now = crate::store::now_ms();
    let own = total / 2;
    for i in 0..own {
        let recent = i < WITH_USAGE;
        let meta = json!({"schema": crate::store::META_SCHEMA, "id": format!("local-{i}"),
            "name": format!("local-{i}"), "harness": "claude", "cwd": "/work",
            "status": if recent { "idle" } else { "closed" }, "createdAt": 1,
            "updatedAt": if recent { now - 1_000 } else { 1 + i as u64 },
            "family": "claude", "agentSessionId": format!("no-transcript-{i}")});
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    }
    let hub = Hub::new(cfg, store);
    for i in 0..WITH_USAGE {
        hub.set_usage_stats_for_test(&format!("local-{i}"), stats(5_000 + i as u64));
    }
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("remote", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("remote".into(), peer.clone());
    let rows = (0..total - own).map(|i| peer_row(i, 7_000)).collect();
    hub.apply_peer_notice(
        "remote",
        peer.generation,
        crate::peer::PeerNotice::sessions_from_values(rows),
    );
    (hub, peer)
}

/// One request on a fresh local connection: its result, its reply's bytes and its milliseconds.
async fn call(hub: &Arc<Hub>, method: &str, params: Value) -> (Value, usize, f64) {
    let (tx, input) = tokio::sync::mpsc::channel(8);
    let (output, mut rx) = tokio::sync::mpsc::channel(8);
    let task = tokio::spawn(crate::server::serve_connection(hub.clone(), input, output));
    tx.send(crate::rpc::Message::request(1, "initialize", json!({"protocolVersion": 1})).to_line())
        .await
        .unwrap();
    let start = Instant::now();
    tx.send(crate::rpc::Message::request(2, method, params).to_line()).await.unwrap();
    let result = loop {
        let line = tokio::time::timeout(std::time::Duration::from_secs(30), rx.recv())
            .await
            .unwrap()
            .unwrap();
        let frame: Value = serde_json::from_str(&line).unwrap();
        if frame["id"] == 2 {
            assert!(frame.get("error").is_none(), "{frame}");
            break (frame["result"].clone(), line.len(), start.elapsed().as_secs_f64() * 1000.0);
        }
    };
    task.abort();
    let _ = task.await;
    result
}

/// One open's cost: requests, reply bytes, milliseconds, and the stats it read by chat.
struct Open {
    requests: usize,
    bytes: usize,
    ms: f64,
    usage: BTreeMap<String, Value>,
}

/// The pane before: every page of the list with `usage: true`, keeping each row's `usageStats`.
async fn open_by_pages(hub: &Arc<Hub>) -> Open {
    let mut open = Open { requests: 0, bytes: 0, ms: 0.0, usage: BTreeMap::new() };
    let mut params = json!({"usage": true, "limit": PAGE});
    loop {
        let (page, bytes, ms) = call(hub, "_acpmux/sessions", params.clone()).await;
        (open.requests, open.bytes, open.ms) =
            (open.requests + 1, open.bytes + bytes, open.ms + ms);
        for row in page["sessions"].as_array().into_iter().flatten() {
            if let (Some(id), Some(stats)) = (row["sessionId"].as_str(), row.get("usageStats"))
                && !stats.is_null()
            {
                open.usage.insert(id.to_owned(), stats.clone());
            }
        }
        match page["nextCursor"].as_str() {
            Some(cursor) => params["cursor"] = json!(cursor),
            None => break open,
        }
    }
}

/// The pane now: one `_acpmux/usage`, sending the digest it holds.
async fn open_by_usage(hub: &Arc<Hub>, known: Option<&str>) -> (Open, Value) {
    let (reply, bytes, ms) = call(hub, "_acpmux/usage", json!({"known": known})).await;
    let usage = reply["usage"]
        .as_object()
        .map(|m| m.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
        .unwrap_or_default();
    (Open { requests: 1, bytes, ms, usage }, reply)
}

fn row(n: usize, step: &str, how: &str, open: &Open, builds: Option<u64>) {
    let builds = builds.map_or("-".to_owned(), |b| b.to_string());
    eprintln!(
        "usage-open | {n:>6} chats | {step:<14} | {how:<14} | {:>3} requests | {:>10} bytes | {:>8.2} ms | {:>3} chats with usage | builds {builds}",
        open.requests,
        open.bytes,
        open.ms,
        open.usage.len()
    );
}

/// The harness and its gate, at `total` chats: `_acpmux/usage` answers what the pages answered,
/// a second open builds nothing and sends no stats, and a change is in the very next open.
async fn usage_open_at(total: usize) {
    let (hub, peer) = seeded(total);
    // Warm the closed rows' cached bytes for both paths alike.
    let _ = call(&hub, "_acpmux/sessions", json!({"limit": 1})).await;

    let pages = open_by_pages(&hub).await;
    row(total, "first open", "list pages", &pages, None);
    assert_eq!(pages.usage.len(), 2 * WITH_USAGE, "the pages carry both machines' stats");

    let builds = hub.usage_answer_builds_for_test();
    let (first, reply) = open_by_usage(&hub, None).await;
    row(
        total,
        "first open",
        "_acpmux/usage",
        &first,
        Some(hub.usage_answer_builds_for_test() - builds),
    );
    assert_eq!(first.usage, pages.usage, "the same stats as every page's rows");
    let digest = reply["digest"].as_str().unwrap().to_owned();

    let pages_again = open_by_pages(&hub).await;
    row(total, "second open", "list pages", &pages_again, None);
    let builds = hub.usage_answer_builds_for_test();
    let (second, reply) = open_by_usage(&hub, Some(&digest)).await;
    let built = hub.usage_answer_builds_for_test() - builds;
    row(total, "second open", "_acpmux/usage", &second, Some(built));
    assert_eq!(built, 0, "a second open at the same list position reads no chat");
    assert_eq!(reply["unchanged"], true, "{reply}");
    assert!(reply.get("usage").is_none(), "an unchanged answer carries no stats: {reply}");
    assert!(second.bytes < 256, "an unchanged answer is a few bytes, not {}", second.bytes);

    // A pass found new usage for one of this daemon's chats and one peer chat changed its own.
    hub.set_usage_stats_for_test("local-3", stats(99_999));
    let rows = (0..total - total / 2)
        .map(|i| peer_row(i, if i == 5 { 1_000_000 } else { 7_000 }))
        .collect();
    hub.apply_peer_notice(
        "remote",
        peer.generation,
        crate::peer::PeerNotice::sessions_from_values(rows),
    );
    let pages_changed = open_by_pages(&hub).await;
    row(total, "after a change", "list pages", &pages_changed, None);
    let builds = hub.usage_answer_builds_for_test();
    let (changed, reply) = open_by_usage(&hub, Some(&digest)).await;
    row(
        total,
        "after a change",
        "_acpmux/usage",
        &changed,
        Some(hub.usage_answer_builds_for_test() - builds),
    );
    assert_ne!(reply["digest"], json!(digest), "the change is a new answer");
    assert_eq!(changed.usage["local-3"]["tokens24h"], 99_999, "the new own stats");
    assert_eq!(changed.usage["remote-5"]["tokens24h"], 1_000_005, "the peer's new stats");
    assert_eq!(changed.usage, pages_changed.usage, "the same stats as every page's rows");

    // The kept answer is one, whatever the total: its size is the chats with usage.
    let kept = hub.usage_answers.last.lock().unwrap().clone().expect("an answer is kept");
    assert_eq!(
        kept.usage.as_ref().and_then(Value::as_object).map(|m| m.len()),
        Some(2 * WITH_USAGE)
    );
}

/// Stats larger than a reply page are never sent or kept whole: the reply is the digest alone,
/// which the pane reads as "use the list's pages" (`sessionPages.ts` `usageByDigest`), and a
/// client holding that digest is not told `unchanged`.
#[tokio::test]
async fn stats_past_a_reply_page_send_the_client_to_the_pages() {
    let (hub, peer) = seeded(2);
    let pad = "x".repeat(600);
    let rows = (0..3_000)
        .map(|i| {
            let mut row = peer_row(i, 7_000);
            // Live, so the peer's closed-row bound keeps every one (`peer_closed_bound.rs`).
            row["status"] = json!("idle");
            row["usageStats"] = json!({"tokens24h": i, "pad": pad});
            row
        })
        .collect();
    hub.apply_peer_notice(
        "remote",
        peer.generation,
        crate::peer::PeerNotice::sessions_from_values(rows),
    );
    let (open, reply) = open_by_usage(&hub, None).await;
    assert!(reply["digest"].is_string(), "{reply}");
    assert!(reply.get("usage").is_none() && reply.get("unchanged").is_none(), "{reply}");
    assert!(open.bytes < 256, "{}", open.bytes);
    let (_, again) = open_by_usage(&hub, reply["digest"].as_str()).await;
    assert!(again.get("unchanged").is_none(), "{again}");
    let kept = hub.usage_answers.last.lock().unwrap().clone().expect("an answer is kept");
    assert!(kept.usage.is_none(), "the kept answer holds no stats past a page");
}

#[tokio::test]
async fn usage_open_at_1k_chats() {
    usage_open_at(1_000).await;
}

#[tokio::test]
async fn usage_open_at_10k_chats() {
    usage_open_at(10_000).await;
}

/// An ask during a change never keeps an answer as current for a position past its build.
#[tokio::test]
async fn an_answer_is_kept_at_the_position_read_before_its_build() {
    let (hub, _peer) = seeded(40);
    let first = hub.usage_answer(None, false);
    let digest = first["digest"].as_str().unwrap().to_owned();
    hub.set_usage_stats_for_test("local-1", stats(42));
    let after = hub.usage_answer(Some(&digest), false);
    assert_eq!(after["usage"]["local-1"]["tokens24h"], 42, "{after}");
    // Unchanged since: the same answer, built once.
    let builds = hub.usage_answer_builds_for_test();
    let again = hub.usage_answer(after["digest"].as_str(), false);
    assert_eq!(again["unchanged"], true);
    assert_eq!(hub.usage_answer_builds_for_test(), builds);
}

/// A peer's link reads only this daemon's chats, as its list does.
#[tokio::test]
async fn a_peer_link_reads_only_this_daemons_chats() {
    let (hub, _peer) = seeded(40);
    let reply = hub.usage_answer(None, true);
    let usage = reply["usage"].as_object().unwrap();
    assert!(usage.keys().all(|id| id.starts_with("local-")), "{reply}");
    assert_eq!(usage.len(), 20.min(WITH_USAGE));
}
