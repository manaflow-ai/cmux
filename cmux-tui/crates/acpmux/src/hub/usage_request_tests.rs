use super::*;
use crate::config::Config;
use crate::hub::Session;
use crate::protocol::session::UsageStats;
use crate::store::{MemoryStore, SessionStatus};
use std::sync::{Arc, atomic::Ordering};

fn hub() -> Arc<Hub> {
    Hub::new(Config::default(), Box::new(MemoryStore::default()))
}
fn stats(cost: Option<f64>, context: Option<u64>) -> UsageStats {
    serde_json::from_value(json!({"autocompact": "unknown", "updatedAt": 1,
        "costUsd24h": cost, "contextTokens": context, "subagentsLive": 2, "tokens24h": 100}))
    .unwrap()
}
fn chat(hub: &Hub, id: &str, cost: Option<f64>, context: Option<u64>) -> Arc<Session> {
    let session = hub.insert_test_session(
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
            "cwd": "/nonexistent", "status": "running", "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap(),
    );
    hub.seed_usage_for_test(&session, stats(cost, context));
    session
}
fn ids(reply: &Value) -> Vec<&str> {
    reply["rows"].as_array().unwrap().iter().map(|r| r["key"].as_str().unwrap()).collect()
}
fn walks(hub: &Hub) -> (u64, u64, u64, (u64, usize)) {
    (
        hub.session_map_walks.load(Ordering::Relaxed),
        hub.remote_rows_copied.load(Ordering::Relaxed),
        hub.summaries_built.load(Ordering::Relaxed),
        hub.usage_passes_for_test(),
    )
}

#[tokio::test]
async fn usage_rank_matches_v1_order_and_totals_include_rows_after_first_page() {
    let hub = hub();
    for n in 0..125 {
        chat(&hub, &format!("s{n:03}"), Some(n as f64), Some((125 - n) as u64));
    }
    chat(&hub, "unknown", None, None);
    let before = walks(&hub);
    let first = hub.usage_reply(&json!({})).unwrap();
    assert_eq!(ids(&first).len(), 20);
    assert_eq!(ids(&first)[0], "s124");
    assert_eq!(first["count"], 126);
    assert_eq!(first["totals"]["costUsd24h"], json!({"value": 7750.0, "known": 125}));
    let second = hub.usage_reply(&json!({"cursor": first["nextCursor"]})).unwrap();
    assert_eq!(ids(&second).len(), 100);
    assert_eq!(ids(&second)[0], "s104");
    let last = hub.usage_reply(&json!({"cursor": second["nextCursor"]})).unwrap();
    assert_eq!(ids(&last), ["s004", "s003", "s002", "s001", "s000", "unknown"]);
    assert!(last["nextCursor"].is_null());
    let context = hub.usage_reply(&json!({"sort": "context"})).unwrap();
    assert_eq!(ids(&context)[0], "s000");
    assert_eq!(walks(&hub), before, "request does no session, peer, summary or usage pass walk");
}

#[tokio::test]
async fn usage_ties_unknowns_and_key_reads_keep_v1_semantics() {
    let hub = hub();
    for (id, cost, context) in [
        ("b", Some(1.0), Some(20)),
        ("a", Some(1.0), Some(20)),
        ("c", Some(1.0), Some(10)),
        ("zero", Some(0.0), None),
        ("unknown", None, Some(100)),
    ] {
        chat(&hub, id, cost, context);
    }
    assert_eq!(ids(&hub.usage_reply(&json!({})).unwrap()), ["a", "b", "c", "zero", "unknown"]);
    let reply = hub.usage_reply(&json!({"sessionIds": ["c", "absent", "a"]})).unwrap();
    assert_eq!(ids(&reply), ["c", "a"]);
    assert_eq!(reply["missing"], json!(["absent"]));
    assert_eq!(reply["rest"], json!([]));
    assert_eq!(reply["count"], 5);
    let empty = self::hub().usage_reply(&json!({})).unwrap();
    assert_eq!(empty["totals"]["costUsd24h"], json!({"value": null, "known": 0}));
}

#[tokio::test]
async fn usage_updates_follow_close_context_replacement_and_purge_fence() {
    let hub = hub();
    let session = chat(&hub, "chat", Some(2.0), Some(30));
    hub.on_update(
        &session,
        Some(&json!({"update": {"sessionUpdate": "usage_update", "used": 40, "size": 900}})),
        false,
    );
    let row = hub.usage_reply(&json!({"sessionIds": ["chat"]})).unwrap()["rows"][0].clone();
    assert_eq!(row["usageStats"]["contextWindow"], 900);
    // The request uses the same overlays as v1; contextTokens remains the harness transcript's.
    assert_eq!(
        row["usageStats"],
        serde_json::to_value(hub.usage_stats_of(&session, &session.meta())).unwrap()
    );
    hub.set_status(&session, SessionStatus::Closed);
    assert_eq!(hub.usage_reply(&json!({})).unwrap()["rows"][0]["usageStats"]["subagentsLive"], 0);
    hub.seed_usage_for_test(&session, stats(Some(7.0), Some(80)));
    assert_eq!(hub.usage_reply(&json!({})).unwrap()["totals"]["costUsd24h"]["value"], 7.0);
    session.purged.store(true, Ordering::SeqCst);
    hub.forget_usage(&session);
    // A transcript pass finishing after purge cannot resurrect its entry.
    hub.seed_usage_for_test(&session, stats(Some(99.0), Some(99)));
    let reply = hub.usage_reply(&json!({})).unwrap();
    assert_eq!(reply["count"], 0);
    assert_eq!(reply["totals"]["costUsd24h"]["known"], 0);
    let replacement = chat(&hub, "chat", Some(3.0), Some(10));
    hub.project_usage(&session); // late old metadata save cannot delete the new incarnation
    assert_eq!(hub.usage_reply(&json!({})).unwrap()["totals"]["costUsd24h"]["value"], 3.0);
    assert!(!replacement.purged.load(Ordering::SeqCst));
}

#[tokio::test]
async fn usage_peer_table_writes_are_atomic_and_status_only_changes_keep_cursor() {
    let hub = hub();
    for n in 0..25 {
        chat(&hub, &format!("local-{n}"), Some(1.0), Some(1));
    }
    let receipt = crate::session_identity::SessionReceipt::new("far", "remote", None, 1);
    let key = receipt.qualified_id();
    let row = |status| crate::hub::RemoteSession {
        peer: "far".into(),
        receipt: receipt.clone(),
        summary:
            json!({"sessionId": "remote", "peer": "far", "name": "far/remote", "status": status,
            "usageStats": stats(Some(50.0), Some(9))})
            .into(),
    };
    hub.remote_sessions.write().insert(key.clone(), row("running"));
    let first = hub.usage_reply(&json!({})).unwrap();
    assert_eq!(ids(&first)[0], "far/remote");
    assert_eq!(first["totals"]["costUsd24h"]["value"], 75.0);
    hub.remote_sessions.write().insert(key.clone(), row("waiting"));
    assert!(hub.usage_reply(&json!({"cursor": first["nextCursor"]})).is_ok());
    let held = hub.remote_sessions.snapshot();
    hub.remote_sessions.write().remove(&key);
    assert_eq!(held.usage.len(), 1, "published snapshots retain their own usage index");
    assert_eq!(hub.usage_reply(&json!({})).unwrap()["count"], 25);
    assert_eq!(
        hub.usage_reply(&json!({"cursor": first["nextCursor"]})).unwrap_err().data.unwrap()["reason"],
        "usage.cursor_stale"
    );
}

#[tokio::test]
async fn usage_request_rejects_bad_keys_cursors_and_bounds_every_reply() {
    let hub = hub();
    chat(&hub, "chat", Some(1.0), Some(2));
    for params in [
        json!({"sessionIds": []}),
        json!({"sessionIds": vec!["chat";101]}),
        json!({"sessionIds": [3]}),
        json!({"sessionIds": ["chat"], "sort": "cost"}),
        json!({"cursor": "no"}),
        json!({"cursor": 2}),
        json!({"sort": "other"}),
        json!({"limit": 11000}),
        json!({"sessionIds": ["a".repeat(1025)]}),
    ] {
        assert!(hub.usage_reply(&params).is_err());
    }
    assert_eq!(ids(&hub.usage_reply(&json!({"sessionIds": vec!["chat";100]})).unwrap()).len(), 100);
    let mut table = hub.usage_stats.order.lock().unwrap();
    for n in 0..100 {
        let key = format!("large-{n:03}");
        let entry = super::super::usage_order::Entry::new(
            key.clone(),
            &json!({"sessionId":key,
            "name": "x".repeat(16_000), "usageStats": stats(Some(2.0), None)}),
        );
        table.replace(&key, entry);
    }
    drop(table);
    let first = hub.usage_reply(&json!({})).unwrap();
    assert!(serde_json::to_vec(&first).unwrap().len() < MAX_BYTES);
    assert!(ids(&first).len() < 20);
    assert!(first["nextCursor"].is_string());
    let keys: Vec<String> = (0..100).map(|n| format!("large-{n:03}")).collect();
    let by_key = hub.usage_reply(&json!({"sessionIds": keys})).unwrap();
    assert!(serde_json::to_vec(&by_key).unwrap().len() < MAX_BYTES);
    assert_eq!(ids(&by_key).len() + by_key["rest"].as_array().unwrap().len(), 100);
}

#[tokio::test]
async fn usage_cursor_cannot_cross_daemon_or_sort() {
    let (a, b) = (hub(), hub());
    for hub in [&a, &b] {
        for n in 0..21 {
            chat(hub, &format!("s{n}"), Some(1.0), None);
        }
    }
    let first = a.usage_reply(&json!({})).unwrap();
    assert!(b.usage_reply(&json!({"cursor": first["nextCursor"]})).is_err());
    assert!(a.usage_reply(&json!({"cursor": first["nextCursor"], "sort": "context"})).is_err());
}

#[tokio::test]
async fn usage_wire_advertises_the_request_and_keeps_legacy_sessions() {
    use crate::rpc::{Message, method};
    use crate::server::{Origin, serve_connection_with};
    let hub = hub();
    let (input, incoming) = tokio::sync::mpsc::channel(8);
    let (output, mut outgoing) = tokio::sync::mpsc::channel(64);
    let task = tokio::spawn(serve_connection_with(hub, incoming, output, Origin::Local));
    for (id, method, params) in [
        (1, method::INITIALIZE, json!({"protocolVersion": 1})),
        (2, method::MUX_USAGE, json!({})),
        (3, method::MUX_SESSIONS, json!({"usage": true})),
    ] {
        input.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(std::time::Duration::from_secs(10), outgoing.recv())
                .await
                .unwrap()
                .unwrap();
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] != id {
                continue;
            }
            assert!(reply.get("error").is_none(), "{reply}");
            if id == 1 {
                assert!(
                    reply
                        .pointer("/result/_meta/acpmux/extensions")
                        .unwrap()
                        .as_array()
                        .unwrap()
                        .contains(&json!(method::MUX_USAGE))
                );
                assert!(
                    reply
                        .pointer("/result/_meta/acpmux/capabilities")
                        .unwrap()
                        .as_array()
                        .unwrap()
                        .contains(&json!("usage-rows-v1"))
                );
            } else if id == 2 {
                assert!(line.len() <= MAX_BYTES);
                assert_eq!(reply["result"]["ready"], false);
                assert_eq!(reply["result"]["count"], 0);
            } else {
                assert!(reply["result"]["sessions"].is_array());
            }
            break;
        }
    }
    drop(input);
    task.abort();
}

fn usage_scale_hub(closed: usize) -> Arc<Hub> {
    let hub = hub();
    for n in 0..20 {
        chat(&hub, &format!("shown-{n:02}"), Some(100.0), Some(100));
    }
    for n in 0..closed {
        let session = chat(&hub, &format!("closed-{n:05}"), Some(0.0), Some(0));
        hub.edit_test_meta(&session, |m| m.status = SessionStatus::Closed);
        hub.project_usage(&session);
    }
    hub
}

#[ignore = "Linux release gate: rank first 20 with 11,000 closed usage rows, cmux-ci only"]
#[tokio::test]
async fn v2_pr07f_usage_request() {
    use acpmux_book::gate_rounds::{self, best_p95};
    let (small, god) = (usage_scale_hub(0), usage_scale_hub(11_000));
    let round = |hub: &Hub| {
        let before = walks(hub);
        let mut times = Vec::new();
        let mut sizes = Vec::new();
        for _ in 0..100 {
            let at = std::time::Instant::now();
            let reply = hub.usage_reply(&json!({})).unwrap();
            let bytes = serde_json::to_vec(&reply).unwrap();
            times.push(at.elapsed().as_nanos());
            sizes.push(bytes.len() as u128);
            assert_eq!(ids(&reply).len(), 20);
            assert!(ids(&reply).iter().all(|id| id.starts_with("shown-")));
            assert!(bytes.len() <= MAX_BYTES);
        }
        assert_eq!(walks(hub), before, "no request-time session/peer/summary/usage pass walk");
        (times, sizes)
    };
    let (mut small_times, mut god_times, mut small_bytes, mut god_bytes) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for _ in 0..5 {
        let (times, bytes) = round(&small);
        small_times.push(times);
        small_bytes.push(bytes);
        let (times, bytes) = round(&god);
        god_times.push(times);
        god_bytes.push(bytes);
    }
    for (name, a, b, unit) in [
        ("v2.pr07f.usage_request", &small_times, &god_times, "ns"),
        ("v2.pr07f.usage_request_bytes", &small_bytes, &god_bytes, "bytes"),
    ] {
        gate_rounds::report(name, &[("small", a), ("god", b)]);
        let (small_p95, god_p95) = (best_p95(a), best_p95(b));
        let line = json!({"name": name, "small_p95": small_p95, "god_p95": god_p95, "unit": unit})
            .to_string();
        eprintln!("{line}");
        if let Some(path) = std::env::var_os("V2_GATE_OUT") {
            use std::io::Write;
            let mut file =
                std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
            writeln!(file, "{line}").unwrap();
        }
        assert!(
            god_p95.saturating_mul(100) <= small_p95.saturating_mul(120),
            "{name}: {god_p95} vs {small_p95}"
        );
    }
}
