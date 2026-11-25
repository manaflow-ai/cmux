//! A wait (`terminal_wait`, up to five minutes) no longer holds the calls sent after it.
//! `cmux mcp serve` answers one line at a time; a wait now runs on its own thread
//! (`Server::detached_wait`), so a ping or a list sent behind it is answered at once and
//! the wait's answer follows when it comes.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{Fake, SharedBuffer};
use crate::cli::mcp::{Server, watch};

const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";
const WAIT: Duration = Duration::from_millis(400);

/// A `terminal_wait` then `pings` pings; how long until the last ping was answered, and
/// the ids in the order they were answered (the wait's answer awaited first).
fn wait_then_pings(fake: Fake, pings: usize) -> (Duration, Vec<String>) {
    let mut server = Server::new(fake, None);
    let mut input = json!({
        "jsonrpc": "2.0", "id": "wait", "method": "tools/call",
        "params": {"name": "terminal_wait",
                   "arguments": {"terminal": TERMINAL, "pattern": "ready", "timeout_ms": "5000"}},
    })
    .to_string();
    input.push('\n');
    for index in 0..pings {
        input.push_str(
            &json!({"jsonrpc": "2.0", "id": format!("p{index}"), "method": "ping"}).to_string(),
        );
        input.push('\n');
    }
    let buffer = SharedBuffer::default();
    let started = Instant::now();
    assert_eq!(server.run(input.as_bytes(), &watch::Output::new(buffer.clone())), 0);
    let pinged = started.elapsed();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !buffer.text().contains("\"id\":\"wait\"") {
        assert!(Instant::now() < deadline, "the wait never answered: {}", buffer.text());
        std::thread::sleep(Duration::from_millis(5));
    }
    let ids = buffer
        .text()
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap()["id"].as_str().unwrap().to_owned())
        .collect();
    (pinged, ids)
}

#[test]
fn calls_after_a_wait_are_answered_while_it_waits() {
    let matched = json!({"matched": true, "text": "ready"});
    let fake = Fake { resource_result: Some(matched), wait_job: Some(WAIT), ..Fake::default() };
    let (pinged, ids) = wait_then_pings(fake, 3);
    assert_eq!(ids, ["p0", "p1", "p2", "wait"], "the pings first, then the wait");
    assert!(pinged < WAIT / 2, "the pings waited {pinged:?} behind a {WAIT:?} wait");
}

#[test]
fn the_waits_answer_is_unchanged_on_its_own_thread() {
    let missed = json!({"matched": false, "text": "$ "});
    let fake =
        Fake { resource_result: Some(missed), wait_job: Some(Duration::ZERO), ..Fake::default() };
    let mut server = Server::new(fake, None);
    let line = json!({
        "jsonrpc": "2.0", "id": 7, "method": "tools/call",
        "params": {"name": "terminal_wait",
                   "arguments": {"terminal": TERMINAL, "pattern": "ready", "timeout_ms": "500"}},
    });
    let buffer = SharedBuffer::default();
    let input = format!("{line}\n");
    assert_eq!(server.run(input.as_bytes(), &watch::Output::new(buffer.clone())), 0);
    let deadline = Instant::now() + Duration::from_secs(10);
    while buffer.text().is_empty() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    let answer: Value = serde_json::from_str(buffer.text().lines().next().unwrap()).unwrap();
    assert_eq!(answer["id"], 7);
    let content = &answer["result"]["structuredContent"];
    assert_eq!(content["timed_out"], true, "{answer}");
    assert_eq!(content["waited_ms"], "500", "{answer}");
}

/// The numbers for the PR: a ping's latency behind one `terminal_wait` on the server's
/// thread (before: the Fake's own `resource`, as a backend with no job) and on its own
/// (after); and duress: N waits sent at once with N pings behind them.
#[test]
fn wait_head_of_line_numbers() {
    let serial = Fake { fail_after: Some(("terminal.wait", WAIT)), ..Fake::default() };
    let (before, ids) = wait_then_pings(serial, 1);
    assert_eq!(ids, ["wait", "p0"], "on one thread the ping is answered after the wait");
    let matched = json!({"matched": true, "text": "ready"});
    let fake =
        Fake { resource_result: Some(matched.clone()), wait_job: Some(WAIT), ..Fake::default() };
    let (after, _) = wait_then_pings(fake, 1);
    eprintln!(
        "head-of-line: ping behind a {WAIT:?} terminal_wait: before {before:?}, after {after:?}"
    );
    assert!(before >= WAIT && after < WAIT / 4, "before {before:?}, after {after:?}");

    const N: usize = 64;
    let mut server = Server::new(
        Fake { resource_result: Some(matched), wait_job: Some(WAIT), ..Fake::default() },
        None,
    );
    let mut input = String::new();
    for index in 0..N {
        input.push_str(&json!({
            "jsonrpc": "2.0", "id": format!("w{index}"), "method": "tools/call",
            "params": {"name": "terminal_wait",
                       "arguments": {"terminal": TERMINAL, "pattern": "ready", "timeout_ms": "5000"}},
        }).to_string());
        input.push('\n');
        input.push_str(
            &json!({"jsonrpc": "2.0", "id": format!("p{index}"), "method": "ping"}).to_string(),
        );
        input.push('\n');
    }
    let buffer = SharedBuffer::default();
    let started = Instant::now();
    assert_eq!(server.run(input.as_bytes(), &watch::Output::new(buffer.clone())), 0);
    let pinged = started.elapsed();
    let deadline = Instant::now() + Duration::from_secs(20);
    while buffer.text().lines().count() < 2 * N {
        assert!(
            Instant::now() < deadline,
            "{} of {} answered",
            buffer.text().lines().count(),
            2 * N
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    let all = started.elapsed();
    eprintln!(
        "Duress: {N} terminal_waits of {WAIT:?} interleaved with {N} pings: every ping answered \
         in {pinged:?} (on one thread: {:?}), every wait in {all:?}",
        WAIT * N as u32
    );
    assert!(pinged < WAIT && all < WAIT * 4, "pings {pinged:?}, all {all:?}");
}
