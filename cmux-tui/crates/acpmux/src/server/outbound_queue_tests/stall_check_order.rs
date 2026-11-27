//! A pane's stall check (`webviews/src/agent-session/acpmux/direct.ts` `checkStall`) asks
//! `_acpmux/events` for the newest record after the one it drew, and reconnects when acpmux holds
//! one the stream has not delivered. Since #55680 an events read is a tool read whose answer goes
//! in the read lane, ahead of the chat's records still queued in bulk: on Leo's NIGHTLY at load
//! 35-75 the page drains bulk slowly, the answer named records that were only queued, and the pane
//! reconnected a healthy chat (19-38 pane reconnects an hour with no app or daemon restart).
//! `inOrder: true` keeps that answer behind them; without it an events read still goes ahead.

use crate::config::{Config, StoreMode};
use crate::server::*;
use std::time::Duration;

const QUEUED: usize = 400;

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn record(seq: usize) -> String {
    Message::notification(
        "session/update",
        json!({
            "sessionId": "stalled-looking",
            "seq": seq,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "r".repeat(2_000)}},
        }),
    )
    .to_line()
}

async fn conn_named(name: &str) -> Arc<Conn> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(conn) = queue_gauge::live()
            .into_iter()
            .find(|c| *c.name.lock().unwrap_or_else(|e| e.into_inner()) == name)
        {
            return conn;
        }
        assert!(tokio::time::Instant::now() < deadline, "no connection named {name}");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

/// How many of the queued records arrive before the answer to one events read.
async fn records_ahead_of_the_answer(in_order: Option<bool>) -> usize {
    let hub = hub();
    let (tx, incoming) = mpsc::channel(16);
    // A small transport: the writer holds the rest in its queue, as a page that drains slowly does.
    let (output, mut rx) = mpsc::channel::<String>(8);
    let scope = cmux_scope::Scope::new("stall-check-order-test");
    scope.spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let name = format!("stall-check-order-{}-{in_order:?}", std::process::id());
    tx.send(
        Message::request(
            0,
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientInfo": {"name": name}}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    let first = tokio::time::timeout(Duration::from_secs(10), rx.recv()).await.unwrap().unwrap();
    assert!(first.contains("\"id\":0"), "{first}");
    let conn = conn_named(&name).await;

    // The chat's records, queued and not yet read: a page that drains slowly.
    for seq in 0..QUEUED {
        conn.send_line(&record(seq));
    }
    let mut params =
        json!({"sessionId": "stalled-looking", "afterSeq": 0, "limit": 1, "kinds": ["transcript"]});
    if let Some(flag) = in_order {
        params["inOrder"] = json!(flag);
    }
    tx.send(Message::request(1, method::MUX_EVENTS, params).to_line()).await.unwrap();

    let mut ahead = 0;
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), rx.recv())
            .await
            .expect("the records and the answer keep coming")
            .expect("the connection stays open");
        let value: Value = serde_json::from_str(&line).unwrap();
        if value.get("method").is_none() && value["id"] == 1 {
            break;
        }
        if value["params"]["sessionId"] == "stalled-looking" {
            assert_eq!(value["params"]["seq"], ahead, "records in order, none dropped");
            ahead += 1;
        }
    }
    drop((tx, conn, scope));
    ahead
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stall_check_asked_in_order_is_answered_after_the_records_queued_before_it() {
    assert_eq!(records_ahead_of_the_answer(Some(true)).await, QUEUED);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_events_read_not_asked_in_order_still_goes_ahead_of_bulk() {
    // The tool-call speedup of #55680 stays: the answer passes most of what was queued.
    let ahead = records_ahead_of_the_answer(None).await;
    assert!(ahead < QUEUED, "an events read waited behind all {QUEUED} queued records");
    let ahead = records_ahead_of_the_answer(Some(false)).await;
    assert!(ahead < QUEUED, "inOrder: false waited behind all {QUEUED} queued records");
}

#[test]
fn only_an_events_read_with_in_order_true_asks_in_order() {
    use super::super::outbound::asks_in_order;
    assert!(asks_in_order(method::MUX_EVENTS, Some(&json!({"inOrder": true}))));
    assert!(!asks_in_order(method::MUX_EVENTS, Some(&json!({"inOrder": false}))));
    assert!(!asks_in_order(method::MUX_EVENTS, Some(&json!({}))));
    assert!(!asks_in_order(method::MUX_EVENTS, None));
    assert!(!asks_in_order(method::MUX_HISTORY, Some(&json!({"inOrder": true}))));
}
