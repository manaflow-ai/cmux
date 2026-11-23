//! The byte-bounded outbound queue (`outbound.rs`): nothing dropped from the middle, a reader
//! past its bound disconnected with a typed reason, and replies counted like every other line.

use super::Message;
use super::outbound::{Limits, OVERRUNS, TOTAL_OVERRUNS, start_bounded, start_limited};
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

fn row(n: usize) -> String {
    row_of(n, 400)
}

fn row_of(n: usize, pad: usize) -> String {
    let session = json!({"sessionId": format!("s{}", n % 7), "pad": "r".repeat(pad)});
    let line = Message::notification(
        "_acpmux/session_changed",
        json!({"sessionId": format!("s{}", n % 7), "session": session, "listSeq": n}),
    )
    .to_line();
    assert!(line.starts_with(super::outbound::LIST_NOTICE_PREFIX), "{line}");
    line
}

/// cosmic-gray, 2026-11-22 22:05-22:11Z: the app's watchers (`cmux-tui-agent-chat-notices`,
/// `cmux-next-turn-states`) held 64 MiB of rows of up to 82 KB each and were cut ten times while
/// Leo's chat pane showed "reconnecting". A reader that reads the list is spared its list notices
/// instead: every other line comes in order, then one `_acpmux/lagged` that says to read the list
/// again, and the connection stays.
#[tokio::test]
async fn a_lagging_list_reader_is_spared_its_rows_instead_of_disconnected() {
    // Past the pump's window (`BULK_WINDOW`), which it takes out of the queue at once.
    const BIG: usize = 2 << 20;
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, mut rx) = mpsc::channel(1);
    let (out, _) = start_bounded(&scope, None, transport, BIG);
    out.describe("local test-watcher".into(), true);
    let (mut rows, mut updates) = (0, 0);
    // About six bounds' worth of 8 KB rows, one update for every 24 rows, and the reader reads
    // nothing.
    for n in 0..1500 {
        if n % 25 == 24 {
            assert!(out.push(note(updates)), "the stream is kept");
            updates += 1;
        } else {
            assert!(out.push(row_of(n, 8 << 10)), "a lagging list reader is not disconnected");
            rows += 1;
        }
        assert!(out.held() <= BIG, "held {} past the bound", out.held());
    }
    // Not `OVERRUNS`: other tests' queues overrun beside this one.
    assert!(!out.is_closed(), "no connection was ended");
    assert!(out.push(Message::ok(json!("end"), json!({})).to_line()));
    // The reader reads again: every update in order, the rows it was spared counted by the lag
    // markers (one queued at a time), which name the list to read again.
    let (mut n, mut got_rows, mut dropped, mut markers) = (0, 0, 0, 0);
    loop {
        let line = next(&mut rx).await.expect("a line");
        if line["id"] == "end" {
            break;
        }
        match line["method"].as_str() {
            Some("session/update") => {
                assert_eq!(line["params"]["n"], n, "in order, none skipped");
                n += 1;
            }
            Some("_acpmux/session_changed") => got_rows += 1,
            Some("_acpmux/lagged") => {
                assert_eq!(line["params"]["watch"], true, "{line}");
                assert_eq!(line["params"]["reason"], "reader.too_slow", "{line}");
                dropped += line["params"]["dropped"].as_u64().unwrap();
                markers += 1;
            }
            _ => panic!("unexpected {line}"),
        }
    }
    assert_eq!(n, updates, "every update came");
    assert!(dropped > 0, "rows were left out");
    assert_eq!(got_rows + dropped, rows as u64, "every row came or was counted as left out");
    assert!(markers <= 2, "lag markers fold into one while queued: {markers}");
    assert!(!out.is_closed());
}

/// A peer daemon's link (or a queue never described) is not spared: it mirrors the list and
/// reads it again only when it links again, so past its bound it ends as before.
#[tokio::test]
async fn a_peer_link_past_its_bound_still_ends() {
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, _rx) = mpsc::channel(1);
    let (out, _) = start_bounded(&scope, None, transport, BOUND);
    out.describe("peer acpmux-peer test".into(), false);
    let mut n = 0;
    while out.push(row(n)) {
        n += 1;
        assert!(n < 1000, "the queue never overran");
    }
    assert!(out.is_closed());
}

/// A queue of lines that may not be left out ends at its bound even when it reads the list.
#[tokio::test]
async fn a_list_reader_whose_queue_is_not_rows_still_ends() {
    let scope = cmux_scope::Scope::new("outbound-test");
    let (transport, _rx) = mpsc::channel(1);
    let (out, _) = start_bounded(&scope, None, transport, BOUND);
    out.describe("local test-attach".into(), true);
    let mut n = 0;
    while out.push(note(n)) {
        n += 1;
        assert!(n < 1000, "the queue never overran");
    }
    assert!(out.is_closed());
}

mod flood_bulk;
