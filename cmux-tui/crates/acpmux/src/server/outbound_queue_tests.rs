//! The byte-bounded outbound queue (`outbound.rs`): nothing dropped from the middle, a reader
//! past its bound disconnected with a typed reason, and replies counted like every other line.

use super::Message;
use super::outbound::{
    BULK_WINDOW, COALESCE_FROM, Lane, Limits, OUTBOUND_BYTE_BOUND, OVERRUNS, ROW_BYTE_BOUND, Row,
    TOTAL_OVERRUNS, start_bounded, start_limited, start_rows_bounded,
};
use serde_json::{Value, json};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
use tokio::sync::mpsc;

const BOUND: usize = 4 << 10;

/// A daemon-wide sum of its own for one test's queues.
fn own_pool() -> &'static AtomicUsize {
    Box::leak(Box::new(AtomicUsize::new(0)))
}

fn note(n: usize) -> String {
    Message::notification("session/update", json!({"n": n, "pad": "x".repeat(200)})).to_line()
}

async fn next(rx: &mut mpsc::Receiver<String>) -> Option<Value> {
    let line = tokio::time::timeout(Duration::from_secs(10), rx.recv()).await.expect("a line")?;
    Some(serde_json::from_str(&line).unwrap())
}

#[tokio::test]
async fn a_stopped_reader_past_its_bound_is_disconnected_with_a_typed_reason() {
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, mut rx) = mpsc::channel(4096);
    let (out, _) = start_bounded(&scope, None, transport, BOUND);
    let before = OVERRUNS.load(Ordering::Relaxed);
    let mut queued = 0;
    while out.push(note(queued)) {
        queued += 1;
        assert!(queued < 1000, "the queue never overran");
    }
    assert!(queued * 200 <= BOUND, "it overran past its bound: {queued} lines");
    assert!(!out.push(note(0)), "nothing is queued once it overran");
    assert!(out.is_closed());
    tokio::time::timeout(Duration::from_secs(5), out.closed()).await.expect("closed resolves");
    // Whatever reached the transport before comes in order, then the reason, then the end.
    let mut n = 0;
    loop {
        let Some(line) = next(&mut rx).await else { panic!("the reason comes before the end") };
        if line["method"] == "session/update" {
            assert_eq!(line["params"]["n"], n, "in order, none skipped");
            n += 1;
            continue;
        }
        assert_eq!(line["error"]["data"]["reason"], "reader.too_slow", "{line}");
        assert_eq!(line["error"]["data"]["limit"], BOUND);
        assert!(line["id"].is_null());
        break;
    }
    assert!(n <= queued);
    assert!(next(&mut rx).await.is_none(), "the transport closes after the reason");
    assert!(OVERRUNS.load(Ordering::Relaxed) > before);
}

/// C1: replies to a client that asks and does not read used to wait in a task each, with no cap.
#[tokio::test]
async fn replies_to_a_client_that_does_not_read_count_against_the_same_bound() {
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, _rx) = mpsc::channel(8);
    let (out, _) = start_bounded(&scope, None, transport, BOUND);
    let reply = |id: usize| Message::ok(json!(id), json!({"pad": "y".repeat(200)})).to_line();
    let mut sent = 0;
    while out.push(reply(sent)) {
        sent += 1;
        assert!(sent < 1000, "replies were never bounded");
    }
    assert!(out.held() <= BOUND, "held {} past the bound", out.held());
}

#[tokio::test]
async fn a_reader_that_keeps_reading_gets_every_line_in_order_however_many() {
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, mut rx) = mpsc::channel(4);
    let (out, _) = start_bounded(&scope, None, transport, BOUND);
    let total = 2_000; // about 100 times the bound
    let reader = tokio::spawn(async move {
        for n in 0..total {
            let line = next(&mut rx).await.expect("every line");
            assert_eq!(line["params"]["n"], n);
        }
        rx
    });
    for n in 0..total {
        // A producer faster than the reader waits for it here only in this test, by its bound.
        while out.held() + 300 > BOUND {
            tokio::task::yield_now().await;
        }
        assert!(out.push(note(n)), "a reader that reads is never disconnected");
    }
    let _rx = reader.await.unwrap();
    assert!(!out.is_closed());
}

/// Review of #26784 at 0a57249: a GitHub request must go after the watch answer queued before
/// it. One queue keeps them in order, however full the transport is.
#[tokio::test]
async fn a_request_goes_after_every_answer_queued_before_it() {
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, mut rx) = mpsc::channel(1);
    let (out, _) = start_bounded(&scope, None, transport, BOUND);
    assert!(out.push("queued-before-reader-catches-up\n".to_owned()));
    assert!(out.push(Message::ok(json!(7), json!({"sessions": []})).to_line()));
    let request = Message::request(json!("acpmux-0"), "_acpmux/github_action", json!({}));
    assert!(out.push(request.to_line()));
    assert_eq!(rx.recv().await.as_deref(), Some("queued-before-reader-catches-up\n"));
    assert!(matches!(next(&mut rx).await, Some(v) if v["id"] == 7));
    assert!(matches!(next(&mut rx).await, Some(v) if v["method"] == "_acpmux/github_action"));
}

#[tokio::test]
async fn a_queue_whose_reader_is_gone_is_closed() {
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, rx) = mpsc::channel(4);
    let (out, _) = start_bounded(&scope, None, transport, BOUND);
    drop(rx);
    assert!(out.is_closed());
    tokio::time::timeout(Duration::from_secs(5), out.closed()).await.expect("closed resolves");
}

/// The bytes the transport's reader took leave the count: a reader that caught up is never
/// disconnected for what it already read.
#[tokio::test]
async fn what_the_reader_took_leaves_the_count() {
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, mut rx) = mpsc::channel(64);
    let (out, _) = start_bounded(&scope, None, transport, BOUND);
    for n in 0..10 {
        assert!(out.push(note(n)));
    }
    for _ in 0..10 {
        next(&mut rx).await.expect("a line");
    }
    assert_eq!(out.held(), 0);
}

/// `gauges.queues` in `daemon status` (`queue_gauge.rs`): the bytes a slow reader has not read,
/// replies among them, and what it read leaves the gauge.
#[tokio::test]
async fn the_queue_gauge_counts_the_bytes_a_slow_reader_has_not_read() {
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, mut rx) = mpsc::channel(64);
    let (out, _) = start_bounded(&scope, None, transport, BOUND);
    let reply = Message::ok(json!(1), json!({"answer": "x".repeat(100)})).to_line();
    let lines = [note(0), reply, note(1)];
    for line in &lines {
        assert!(out.push(line.clone()));
    }
    let gauge = out.gauge();
    assert_eq!(gauge.bytes, lines.iter().map(String::len).sum::<usize>());
    assert_eq!(gauge.bound, BOUND);
    assert!(!gauge.overrun);
    next(&mut rx).await.expect("a line");
    let after = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let gauge = out.gauge();
            if gauge.bytes == lines[1].len() + lines[2].len() {
                return gauge;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("what the reader took leaves the gauge");
    assert_eq!(after.lines, 2);
}

/// huge-blue, 2026-11-20: every connection under its own bound, 16.5 GB together. Past the
/// daemon-wide bound, a reader over its fair share is disconnected; a small one is still served.
#[tokio::test]
async fn past_the_daemon_wide_bound_a_reader_over_its_fair_share_is_disconnected() {
    const FAIR: usize = 8 << 10;
    const OWN: usize = 1 << 20;
    let scope = cmux_scope::Scope::new("outbound-test");
    // Its own pool: other tests' queues, filling and draining beside it, never move its bound.
    let pool = own_pool();
    let limits =
        || Limits { pool, total_bound: 32 << 10, fair_share: FAIR, reader_stall: Duration::ZERO };
    let (t1, _rx1) = mpsc::channel(1);
    let (t2, _rx2) = mpsc::channel(1);
    let (t3, _rx3) = mpsc::channel(1);
    let (big, _) = start_limited(&scope, None, t1, OWN, limits());
    let (other, _) = start_limited(&scope, None, t2, OWN, limits());
    let (small, _) = start_limited(&scope, None, t3, OWN, limits());
    let cuts = TOTAL_OVERRUNS.load(Ordering::Relaxed);
    let mut queued = 0;
    while big.push(note(queued)) {
        queued += 1;
        assert!(queued * 200 < OWN, "the daemon-wide bound never tripped");
    }
    assert!(big.is_closed(), "the reader over its share is disconnected");
    assert!(TOTAL_OVERRUNS.load(Ordering::Relaxed) > cuts, "counted as a daemon-wide cut");
    // Another reader holding the rest of the bound, then one under its share: still served.
    let mut n = 0;
    while other.push(note(n)) {
        n += 1;
        assert!(n * 200 < OWN, "the daemon-wide bound never tripped");
    }
    for i in 0..5 {
        assert!(small.push(note(i)), "a reader under its fair share is served");
    }
    assert!(!small.is_closed());
}

/// cosmic-gray, 2026-11-21 (ask-0e0d5a479b): past the daemon-wide bound, the cut fell on the app's
/// coordinator chats while they read a huge replay, and each cut cost a whole re-attach. A reader
/// that is taking lines keeps its connection up to its own bound; one that took nothing for the
/// stall bound is still disconnected.
#[tokio::test]
async fn past_the_daemon_wide_bound_a_reader_taking_lines_keeps_its_connection() {
    const FAIR: usize = 8 << 10;
    const OWN: usize = 1 << 20;
    const STALL: Duration = Duration::from_millis(300);
    let scope = cmux_scope::Scope::new("outbound-test");
    let pool = own_pool();
    let limits = || Limits { pool, total_bound: 16 << 10, fair_share: FAIR, reader_stall: STALL };
    let (t1, mut reading) = mpsc::channel(4);
    let (t2, _stuck) = mpsc::channel(1);
    let (pane, _) = start_limited(&scope, None, t1, OWN, limits());
    let (cli, _) = start_limited(&scope, None, t2, OWN, limits());
    // The stuck reader fills the daemon-wide bound; it is new, so not yet stalled.
    let mut n = 0;
    while cli.push(note(n)) && n * 200 < OWN / 2 {
        n += 1;
    }
    assert!(!cli.is_closed(), "a reader within its stall bound is kept");
    // The pane reads a little every third of the stall bound while its queue keeps growing: far
    // past its fair share and the total, over several stall bounds, it is served.
    let mut sent = 0;
    for _round in 0..10 {
        for _ in 0..10 {
            assert!(pane.push(note(sent)), "a reader taking lines is served past its fair share");
            sent += 1;
        }
        tokio::task::yield_now().await;
        for _ in 0..2 {
            let _ = reading.try_recv();
        }
        tokio::time::sleep(STALL / 3).await;
    }
    assert!(pane.held() > FAIR, "the pane's queue grew past its fair share");
    assert!(!pane.is_closed());
    // The stuck one, past its stall bound, is disconnected at its next line.
    tokio::time::sleep(STALL + Duration::from_millis(50)).await;
    let mut more = 0;
    while cli.push(note(n + more)) {
        more += 1;
        assert!(more < 10, "the stalled reader over its share is disconnected");
    }
    assert!(cli.is_closed());
}

/// A watcher's row of chat `chat` at change `n`, a few KB as a list row is.
fn row(chat: usize, n: usize) -> String {
    let session =
        json!({"sessionId": format!("s{chat}"), "status": "running", "pad": "r".repeat(4 << 10)});
    Message::notification(
        "_acpmux/session_changed",
        json!({"sessionId": format!("s{chat}"), "session": session, "listSeq": n}),
    )
    .to_line()
}

fn key(chat: usize) -> Row {
    Row::Latest(format!("s{chat}").into())
}

/// Leo's Mac, 2026-11-22: a watcher that fell behind held 62.8 MB of rows (6,041 lines), under its
/// 64 MiB bound. A row is the chat's whole state, so the queue keeps the latest per chat: 10,000
/// changes of 20 chats to a reader that never reads hold 20 rows, and the reader gets each chat's
/// latest, in the order of their last change.
#[tokio::test]
async fn a_reader_that_never_reads_holds_one_row_per_chat_and_gets_the_latest() {
    const CHATS: usize = 20;
    const CHANGES: usize = 10_000;
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, mut rx) = mpsc::channel(1);
    let (out, _) = start_bounded(&scope, None, transport, OUTBOUND_BYTE_BOUND);
    let mut all = 0;
    for n in 0..CHANGES {
        let line = row(n % CHATS, n);
        all += line.len();
        assert!(out.lock().push_row(line, Lane::Bulk, key(n % CHATS)), "never disconnected");
    }
    let held = out.held();
    eprintln!("rows held: {held} bytes for {CHANGES} changes of {CHATS} chats ({all} bytes sent)");
    // Rows up to the point the reader counts as behind, then one row of each chat; the pump may
    // hold up to its window besides.
    let bound = COALESCE_FROM + BULK_WINDOW + (CHATS + 1) * row(0, CHANGES).len();
    assert!(held <= bound, "held {held} bytes, over {bound}");
    assert!(held < ROW_BYTE_BOUND);
    assert!(!out.is_closed());
    let mut latest = std::collections::HashMap::new();
    while let Ok(Some(line)) = tokio::time::timeout(Duration::from_millis(500), rx.recv()).await {
        let line: Value = serde_json::from_str(&line).unwrap();
        let chat = line["params"]["sessionId"].as_str().unwrap().to_owned();
        let seq = line["params"]["listSeq"].as_u64().unwrap();
        let prior = latest.insert(chat, seq);
        assert!(prior.is_none_or(|p| p < seq), "a chat's rows come in order");
    }
    assert_eq!(latest.len(), CHATS);
    for (chat, seq) in latest {
        let n: usize = chat[1..].parse().unwrap();
        assert_eq!(seq as usize, CHANGES - CHATS + n, "{chat} ends on its latest row");
    }
    assert_eq!(out.held(), 0);
}

/// A line that must follow a chat's row (its permission ask, its purge) keeps the row before it:
/// a newer row queues after it.
#[tokio::test]
async fn a_row_before_a_line_that_follows_it_is_kept() {
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, mut rx) = mpsc::channel(1);
    let (out, _) = start_bounded(&scope, None, transport, OUTBOUND_BYTE_BOUND);
    // The first line goes to the transport, the second to the pump: neither is queued.
    assert!(out.push("filler-0\n".to_owned()));
    assert!(out.push("filler-1\n".to_owned()));
    tokio::time::sleep(Duration::from_millis(50)).await;
    // The reader is behind: what it has not read is past the point rows are replaced.
    assert!(out.push(format!("filler-behind {}\n", "f".repeat(COALESCE_FROM))));
    let ask = Message::notification("_acpmux/permission_pending", json!({"sessionId": "s0"}));
    assert!(out.lock().push_row(row(0, 1), Lane::Bulk, key(0)));
    assert!(out.lock().push_row(ask.to_line(), Lane::Bulk, Row::After("s0".into())));
    assert!(out.lock().push_row(row(0, 2), Lane::Bulk, key(0)));
    assert!(out.lock().push_row(row(0, 3), Lane::Bulk, key(0)));
    let mut got = Vec::new();
    while let Ok(Some(line)) = tokio::time::timeout(Duration::from_millis(500), rx.recv()).await {
        if line.starts_with("filler") {
            continue;
        }
        let line: Value = serde_json::from_str(&line).unwrap();
        got.push(line["params"]["listSeq"].as_u64().map_or("ask".to_owned(), |n| n.to_string()));
    }
    assert_eq!(got, ["1", "ask", "3"]);
}

/// A reader that keeps up gets every row of a chat: each names what changed (a queued, then a
/// dequeued prompt), and a watcher waits on that (`queued_prompts_are_accepted_queued_and_watchers_see_the_queue`).
#[tokio::test]
async fn a_reader_that_keeps_up_gets_every_row() {
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, mut rx) = mpsc::channel(1);
    let (out, _) = start_bounded(&scope, None, transport, OUTBOUND_BYTE_BOUND);
    for n in 1..=3 {
        assert!(out.lock().push_row(row(0, n), Lane::Bulk, key(0)));
    }
    let mut got = Vec::new();
    while let Ok(Some(line)) = tokio::time::timeout(Duration::from_millis(500), rx.recv()).await {
        let line: Value = serde_json::from_str(&line).unwrap();
        got.push(line["params"]["listSeq"].as_u64().unwrap());
    }
    assert_eq!(got, [1, 2, 3]);
}

/// Rows of more chats than [`ROW_BYTE_BOUND`] holds end the connection, as its own bound would:
/// the client follows once from its cursor.
#[tokio::test]
async fn rows_past_their_bound_end_the_connection_once() {
    const ROWS: usize = 64 << 10;
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, mut rx) = mpsc::channel(1);
    let out = start_rows_bounded(&scope, transport, OUTBOUND_BYTE_BOUND, ROWS);
    let mut chat = 0;
    while out.lock().push_row(row(chat, chat), Lane::Bulk, key(chat)) {
        chat += 1;
        assert!(chat < 100, "the rows' bound never tripped");
    }
    assert!(out.is_closed());
    assert!(out.held() <= ROWS + BULK_WINDOW);
    let reason = loop {
        let Some(line) = next(&mut rx).await else { panic!("the reason comes before the end") };
        if line["error"].is_object() {
            break line;
        }
    };
    assert_eq!(reason["error"]["data"]["reason"], "reader.too_slow");
    assert_eq!(reason["error"]["data"]["limit"], ROWS);
}

mod flood_bulk;
