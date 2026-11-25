use super::*;
use serde_json::json;

const NOW: u64 = 1_790_000_000_000;
const MIN: u64 = 60_000;

/// A ready local chat idle `idle_min` minutes, in the shape a `session-idle-facts-v1` daemon lists.
fn idle(id: &str, idle_min: u64) -> Value {
    json!({"sessionId": id, "name": id, "status": "ready", "updatedAt": NOW - idle_min * MIN,
           "queued": 0, "pendingPermissions": 0, "turn": null, "peer": null})
}

fn running(id: &str) -> Value {
    json!({"sessionId": id, "name": id, "status": "running", "updatedAt": NOW, "queued": 0,
           "pendingPermissions": 0, "turn": {"id": "t1"}, "peer": null})
}

fn target(name: &str, room: f64) -> Target {
    Target { name: name.into(), room }
}

fn on() -> Conf {
    Conf { enabled: true, ..Conf::default() }
}

#[test]
fn under_the_cap_moves_nothing() {
    let rows: Vec<Value> = (0..6).map(|i| idle(&format!("s{i}"), 60)).collect();
    let p = plan(&rows, true, Some(6), vec![target("b", 4.0)], &on(), NOW);
    assert_eq!((p.live, p.excess, p.moves.len()), (6, 0, 0));
}

#[test]
fn no_cap_is_never_over() {
    let rows: Vec<Value> = (0..20).map(|i| idle(&format!("s{i}"), 60)).collect();
    let p = plan(&rows, true, None, vec![target("b", 4.0)], &on(), NOW);
    assert!(p.moves.is_empty() && p.excess == 0);
}

#[test]
fn excess_moves_longest_idle_first_bounded_per_pass() {
    // gcp-agent-lane-8: 21 live against a cap of 6.
    let rows: Vec<Value> = (0..21).map(|i| idle(&format!("s{i}"), 10 + i)).collect();
    let p = plan(&rows, true, Some(6), vec![target("b", 10.0)], &on(), NOW);
    assert_eq!(p.excess, 15);
    assert_eq!(p.moves.len(), MAX_MOVES);
    let ids: Vec<&str> = p.moves.iter().map(|m| m.session_id.as_str()).collect();
    assert_eq!(ids, ["s20", "s19", "s18", "s17"]);
    let c = Conf { max_moves: 2, ..on() };
    assert_eq!(plan(&rows, true, Some(6), vec![target("b", 10.0)], &c, NOW).moves.len(), 2);
}

#[test]
fn never_moves_more_than_the_excess() {
    let rows: Vec<Value> = (0..7).map(|i| idle(&format!("s{i}"), 60)).collect();
    let p = plan(&rows, true, Some(6), vec![target("b", 10.0)], &on(), NOW);
    assert_eq!(p.moves.len(), 1);
}

#[test]
fn mid_turn_and_working_below_never_move() {
    let mut rows: Vec<Value> = (0..6).map(|i| running(&format!("r{i}"))).collect();
    let mut below = idle("below", 60);
    below["workingBelow"] = json!(true);
    let mut queued = idle("queued", 60);
    queued["queued"] = json!(1);
    let mut asks = idle("asks", 60);
    asks["pendingPermissions"] = json!(2);
    let mut turn = idle("turn", 60);
    turn["turn"] = json!({"id": "t"});
    let mut held_by_person = idle("held", 60);
    held_by_person["personHold"] = json!({"by": "leo"});
    let mut shown = idle("shown", 60);
    shown["shown"] = json!(true);
    let mut child = idle("child", 60);
    child["parent"] = json!("p");
    let fresh = idle("fresh", 1);
    rows.extend([below, queued, asks, turn, held_by_person, shown, child, fresh]);
    let p = plan(&rows, true, Some(6), vec![target("b", 10.0)], &on(), NOW);
    assert_eq!(p.excess, 8);
    assert!(p.moves.is_empty(), "{:?}", p.moves);
    assert_eq!(p.held.len(), 14);
}

#[test]
fn old_daemon_without_idle_facts_moves_nothing() {
    // An absent workingBelow is unknown unless the daemon lists session-idle-facts-v1.
    let rows: Vec<Value> = (0..8).map(|i| idle(&format!("s{i}"), 60)).collect();
    let old = plan(&rows, false, Some(6), vec![target("b", 10.0)], &on(), NOW);
    assert!(old.moves.is_empty());
    assert!(old.held.iter().all(|(_, why)| why.contains("session-idle-facts-v1")));
    let new = plan(&rows, true, Some(6), vec![target("b", 10.0)], &on(), NOW);
    assert_eq!(new.moves.len(), 2);
    // An old daemon that does say workingBelow false outright is believed.
    let said: Vec<Value> = rows
        .iter()
        .cloned()
        .map(|mut r| {
            r["workingBelow"] = json!(false);
            r
        })
        .collect();
    assert_eq!(plan(&said, false, Some(6), vec![target("b", 10.0)], &on(), NOW).moves.len(), 2);
}

#[test]
fn an_older_rows_missing_fields_are_unknown_not_zero() {
    let mut rows: Vec<Value> = (0..6).map(|i| running(&format!("r{i}"))).collect();
    let mut no_queue = idle("nq", 60);
    no_queue.as_object_mut().unwrap().remove("queued");
    let mut no_asks = idle("na", 60);
    no_asks.as_object_mut().unwrap().remove("pendingPermissions");
    rows.extend([no_queue, no_asks]);
    let p = plan(&rows, true, Some(6), vec![target("b", 10.0)], &on(), NOW);
    assert!(p.moves.is_empty());
}

#[test]
fn filler_and_peers_neither_count_nor_move() {
    let mut rows: Vec<Value> = (0..6).map(|i| idle(&format!("s{i}"), 60)).collect();
    let mut filler = idle("f", 60);
    filler["tags"] = json!({"filler": "true"});
    let mut peer = idle("p", 60);
    peer["peer"] = json!("gcp-agent-lane-2");
    rows.extend([filler, peer]);
    let p = plan(&rows, true, Some(6), vec![target("b", 10.0)], &on(), NOW);
    assert_eq!((p.live, p.excess), (6, 0));
}

#[test]
fn moves_spread_over_targets_and_spill_past_their_room() {
    let rows: Vec<Value> = (0..12).map(|i| idle(&format!("s{i}"), 60 + i)).collect();
    let c = Conf { max_moves: 6, ..on() };
    let p = plan(&rows, true, Some(6), vec![target("a", 2.0), target("b", 1.5)], &c, NOW);
    let to: Vec<&str> = p.moves.iter().map(|m| m.target.as_str()).collect();
    assert_eq!(to, ["a", "a", "b"]);
    assert_eq!(p.spill, 3);
    let none = plan(&rows, true, Some(6), vec![], &c, NOW);
    assert_eq!((none.moves.len(), none.spill), (0, 6));
}

#[test]
fn targets_skip_here_refused_full_and_local() {
    let verdict = json!({"hosts": [
        {"name": "here", "local": true, "room": 9.0},
        {"name": "gcp-agent-lane-8", "room": 9.0},
        {"name": "full", "room": 0.5},
        {"name": "refused", "room": 5.0, "refused": "disk"},
        {"name": "small", "room": 1.0},
        {"name": "big", "room": 4.0},
    ]});
    let t = targets(&verdict, None, "gcp-agent-lane-8");
    let names: Vec<&str> = t.iter().map(|t| t.name.as_str()).collect();
    assert_eq!(names, ["big", "small"]);
}

#[test]
fn conf_is_off_unless_the_registry_says_on() {
    assert!(!conf(None).enabled);
    let reg = json!({"lane_overflow": {"rebalance": {"enabled": true, "max_moves": 2,
                                                      "min_idle_secs": 60}}});
    assert_eq!(conf(Some(&reg)), Conf { enabled: true, max_moves: 2, min_idle_secs: 60 });
    let off = json!({"lane_overflow": {"rebalance": {"enabled": "yes"}}});
    assert!(!conf(Some(&off)).enabled);
}

#[test]
fn receipt_round_trips_to_its_undo() {
    let d = Done {
        source: "gcp-agent-lane-8".into(),
        session_id: "s1".into(),
        name: "fix-x".into(),
        target: "gcp-agent-lane-3".into(),
        there: Some(("gcp-agent-lane-3".into(), "s9".into())),
        unavailable_ms: 4200,
        ..Done::default()
    };
    let r = receipt("rb-1-0", NOW, &d, "over cap");
    assert_eq!(r["kind"], "move");
    assert_eq!(undo_of(&r).unwrap(), ("gcp-agent-lane-3".into(), "s9".into()));
    let failed = receipt("rb-1-1", NOW, &Done { error: Some("x".into()), there: None, ..d }, "");
    assert!(undo_of(&failed).is_err());
    assert!(failed["undo"].is_null());
}

#[test]
fn a_newer_receipt_is_refused_not_half_read() {
    let mut r = json!({"schema": SCHEMA, "version": VERSION + 1, "ok": true,
                       "there": {"host": "h", "sessionId": "s"}});
    assert!(undo_of(&r).unwrap_err().contains("newer"));
    r["version"] = json!(VERSION);
    assert!(undo_of(&r).is_ok());
    r["schema"] = json!("other/v1");
    assert!(undo_of(&r).is_err());
}

#[test]
fn moved_to_reads_session_moves_json() {
    let ok = json!({"moves": [{"sessionId": "s1", "host": "h", "moved": true,
                               "targetSessionId": "s9", "error": null}], "failed": 0});
    assert_eq!(moved_to(&ok).unwrap(), ("h".into(), "s9".into()));
    let bad = json!({"moves": [{"sessionId": "s1", "host": "h", "moved": false,
                                "error": "turn did not end"}], "failed": 1});
    assert_eq!(moved_to(&bad).unwrap_err(), "turn did not end");
    assert!(moved_to(&json!({})).is_err());
}
