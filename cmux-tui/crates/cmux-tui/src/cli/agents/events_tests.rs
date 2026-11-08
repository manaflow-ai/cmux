//! A wait (`--until` / `--match`) on `agents events` against its answer
//! buffer, without a daemon: what fills it and what does not.

use std::time::Instant;

use serde_json::json;

use super::{Poll, parse};

#[test]
fn a_reset_does_not_fill_a_wait_before_its_match() {
    let request = match parse(&["--until", "agent.state", "--limit", "1", "--timeout", "5s"]) {
        Ok(request) => request,
        Err(error) => panic!("{error:?}"),
    };
    let mut poll = Poll::new(&request, Instant::now());
    // An expired cursor's reset comes first and is kept.
    assert!(poll.push("reset", None, json!({"source": "daemon", "reason": "cursor_invalid"})));
    assert!(!poll.full(), "a reset filled the wait");
    // A change that does not match is passed over, not answered.
    assert!(poll.push("workspace", None, json!({"change": "changed", "name": "w"})));
    assert!(!poll.full());
    // The match still fits, and ends the wait.
    assert!(poll.push("agent", None, json!({"change": "state", "state": "idle"})));
    assert!(poll.full());
    let kinds: Vec<_> = poll.events.iter().map(|event| event["kind"].clone()).collect();
    assert_eq!(kinds, [json!("reset"), json!("agent")]);
}

#[test]
fn a_plain_poll_still_fills_at_its_limit() {
    let request = match parse(&["--limit", "1", "--timeout", "5"]) {
        Ok(request) => request,
        Err(error) => panic!("{error:?}"),
    };
    let mut poll = Poll::new(&request, Instant::now());
    assert!(poll.push("reset", None, json!({"source": "daemon", "reason": "cursor_invalid"})));
    assert!(poll.full());
    assert!(!poll.push("agent", None, json!({"change": "state", "state": "idle"})));
}
