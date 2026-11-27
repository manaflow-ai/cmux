use serde_json::{Value, json};

use super::*;
use crate::autosize_row::{Kind, MAX_ROWS};

/// A `cloud.machine.autosize` frame as cmux-platform `autoSizeEventFrame` sends it.
fn frame(kind: &str, machine: &str, record: &str, at: u64) -> Value {
    let mut data = json!({
        "v": 1, "machine": machine, "record": record, "team": "t1", "creator": "u1",
        "kind": kind, "reason": "memory", "reason_text": "it ran out of memory",
        "from": {"vcpu": 2, "mem_gib": 4, "disk_gib": 20, "hourly_usd": 0.148},
        "hourly_usd": 0.296,
        "line": "Machine grew to 4 vCPU / 8 GiB (it ran out of memory), now $0.296 an hour",
        "at": at
    });
    match kind {
        "hold" => data["hold"] = json!("at_plan_limit"),
        _ => data["to"] = json!({"vcpu": 4, "mem_gib": 8, "disk_gib": 20, "hourly_usd": 0.296}),
    }
    json!({"t": "ephemeral", "stream": "cloud:t1", "event": "cloud.machine.autosize", "data": data})
}

#[test]
fn only_an_autosize_frame_of_the_sockets_team_is_read() {
    let grow = frame("grow", "vm_a", "rec_1", 1);
    assert_eq!(wire_event(&grow, Some("t1")).map(|event| event.kind), Some(Kind::Grow));
    assert!(wire_event(&grow, None).is_some(), "no team named reads any team");
    assert!(wire_event(&grow, Some("")).is_some());
    assert_eq!(wire_event(&grow, Some("t2")), None, "another team's stream");

    let mut other_data_team = grow.clone();
    other_data_team["stream"] = Value::Null;
    other_data_team["data"]["team"] = json!("t2");
    assert_eq!(wire_event(&other_data_team, Some("t1")), None, "another team's data");

    let mut pausing = grow.clone();
    pausing["event"] = json!("cloud.machine.pausing");
    assert_eq!(wire_event(&pausing, Some("t1")), None);
    let mut snapshot = grow.clone();
    snapshot["t"] = json!("snapshot");
    assert_eq!(wire_event(&snapshot, Some("t1")), None);
    let mut broken = grow.clone();
    broken["data"]["kind"] = json!("explode");
    assert_eq!(wire_event(&broken, Some("t1")), None, "a data this build cannot read");
    assert_eq!(wire_event(&json!("text"), Some("t1")), None);
}

#[test]
fn a_frame_becomes_its_machines_row_and_a_resend_changes_nothing() {
    let mut feed = Feed::default();
    let grow = frame("grow", "vm_a", "rec_1", 10);
    assert_eq!(feed.add_frame(&grow, Some("t1"), None), Some("vm_a".to_owned()));
    assert_eq!(feed.add_frame(&grow, Some("t1"), None), None, "a resend");
    let rows = feed.rows("vm_a");
    assert_eq!(rows.len(), 1);
    assert_eq!((rows[0].kind, rows[0].key.as_str()), (Kind::Grow, "rec_1:grow:10"));
    assert!(feed.rows("vm_other").is_empty());
}

#[test]
fn a_newer_wire_version_or_another_team_adds_no_record() {
    let mut feed = Feed::default();
    let mut newer = frame("grow", "vm_a", "rec_1", 10);
    newer["data"]["v"] = json!(2);
    assert_eq!(feed.add_frame(&newer, Some("t1"), None), None);
    assert_eq!(feed.add_frame(&frame("grow", "vm_a", "rec_1", 10), Some("t9"), None), None);
    assert!(feed.is_empty());
}

#[test]
fn a_repeated_hold_folds_and_counts_as_a_change() {
    let mut feed = Feed::default();
    for at in [10, 20, 30] {
        assert!(feed.add_frame(&frame("hold", "vm_a", "rec_1", at), Some("t1"), None).is_some());
    }
    let rows = feed.rows("vm_a");
    assert_eq!(rows.len(), 1);
    assert_eq!((rows[0].count, rows[0].last_at_ms), (3, 30));
}

#[test]
fn a_shrink_onto_a_new_machine_keeps_one_record_under_both_ids() {
    let mut feed = Feed::default();
    feed.add_frame(&frame("grow", "vm_a", "rec_1", 10), Some("t1"), None);
    let mut shrink = frame("shrink", "vm_b", "rec_1", 20);
    shrink["data"]["reason"] = json!("idle");
    assert_eq!(feed.add_frame(&shrink, Some("t1"), None), Some("vm_b".to_owned()));
    assert_eq!(feed.len(), 1);
    assert_eq!(feed.rows("vm_a").len(), 2, "a chat still bound to the old id");
    assert_eq!(feed.rows("vm_b"), feed.rows("vm_a"));
}

#[test]
fn records_and_rows_stay_bounded() {
    let mut feed = Feed::default();
    for n in 0..(MAX_RECORDS + 3) {
        feed.add_frame(&frame("grow", &format!("vm_{n}"), &format!("rec_{n}"), 1), None, None);
    }
    assert_eq!(feed.len(), MAX_RECORDS);
    assert!(feed.rows("vm_0").is_empty(), "the stalest record went first");
    assert_eq!(feed.rows(&format!("vm_{}", MAX_RECORDS + 2)).len(), 1);

    let mut one = Feed::default();
    for at in 1..=(MAX_ROWS as u64 + 5) {
        let kind = if at % 2 == 0 { "grow" } else { "shrink" };
        one.add_frame(&frame(kind, "vm_a", "rec_1", at), None, None);
    }
    assert_eq!(one.rows("vm_a").len(), MAX_ROWS);

    let mut many = Feed::default();
    for n in 0..(MAX_MACHINES + 2) {
        many.add_frame(&frame("grow", &format!("vm_{n}"), "rec_1", n as u64 + 1), None, None);
    }
    assert!(many.rows("vm_0").is_empty(), "the oldest machine id is let go");
    assert_eq!(many.rows(&format!("vm_{}", MAX_MACHINES + 1)).len(), MAX_MACHINES + 2);
}
