//! `background_safe.rs`: which adopted Claude Code processes kill background work on interrupt.

use super::background_safe::initialize_spares_background;
use crate::store::EventRecord;
use serde_json::{Value, json};

fn record(seq: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
    serde_json::from_value(json!({"seq": seq, "at": 0, "dir": dir, "kind": kind, "msg": msg}))
        .unwrap()
}

fn initialize(affordance: Option<bool>) -> EventRecord {
    let mut request = json!({"subtype": "initialize", "hooks": {}});
    if let Some(a) = affordance {
        request["perTaskStopAffordance"] = json!(a);
    }
    record(
        2,
        "out",
        "claude.stdin",
        json!({"type": "control_request", "request_id": "init-1", "request": request}),
    )
}

/// The cosmic-gray coordinator's host (a 2026-10-29 build, adopted for twelve days): its
/// `initialize` had no `perTaskStopAffordance`, so its interrupt killed every background subagent.
#[test]
fn an_initialize_without_the_affordance_kills_background_work() {
    let started = record(1, "mux", "host_started", json!({"incarnation": "old"}));
    let records = [started, initialize(None)];
    assert_eq!(initialize_spares_background(&records), Some(false));
    assert_eq!(initialize_spares_background(&[initialize(Some(false))]), Some(false));
}

#[test]
fn an_initialize_with_the_affordance_spares_background_work() {
    assert_eq!(initialize_spares_background(&[initialize(Some(true))]), Some(true));
}

/// Another harness, or a log without the line: unknown is never marked.
#[test]
fn no_claude_initialize_is_unknown() {
    let acp = record(2, "out", "initialize", json!({"method": "initialize", "params": {}}));
    let prompt = record(3, "out", "claude.stdin", json!({"type": "user", "message": {}}));
    assert_eq!(initialize_spares_background(&[acp, prompt]), None);
    assert_eq!(initialize_spares_background(std::iter::empty()), None);
}

/// The first `initialize` after the host's start decides: a later control line never does.
#[test]
fn the_first_initialize_decides() {
    let interrupt = record(
        3,
        "out",
        "claude.stdin",
        json!({"type": "control_request", "request": {"subtype": "interrupt"}}),
    );
    let records = [initialize(None), interrupt, initialize(Some(true))];
    assert_eq!(initialize_spares_background(&records), Some(false));
}
