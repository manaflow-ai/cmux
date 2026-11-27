use super::*;
use serde_json::json;

const NOW: u64 = 1_790_000_000_000;
const MIN: u64 = 60_000;

/// A ready local chat idle `idle_min` minutes, in the shape a `session-idle-facts-v1` daemon lists.
fn idle(id: &str, idle_min: u64) -> Value {
    json!({"sessionId": id, "name": id, "status": "ready", "updatedAt": NOW - idle_min * MIN,
           "queued": 0, "pendingPermissions": 0, "turn": null, "peer": null, "bgTasksRunning": 0})
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
    assert_eq!(
        conf(Some(&reg)),
        Conf { enabled: true, max_moves: 2, min_idle_secs: 60, ..Conf::default() }
    );
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

#[test]
fn the_switch_is_on_per_host_when_hosts_are_listed() {
    let reg = json!({"lane_overflow": {"rebalance": {"enabled": true,
        "hosts": ["gcp-agent-lane-8", "fs-agent-lane-27"]}}});
    let c = conf(Some(&reg));
    assert!(c.on_for("gcp-agent-lane-8") && c.on_for("fs-agent-lane-27"));
    assert!(!c.on_for("gcp-agent-lane-13"));
    assert!(on().on_for("anything"), "no hosts list: every host");
    let off = json!({"lane_overflow": {"rebalance": {"hosts": ["gcp-agent-lane-8"]}}});
    assert!(!conf(Some(&off)).on_for("gcp-agent-lane-8"), "a listed host still needs enabled");
}

#[test]
fn own_machine_sends_each_move_to_a_machine_of_its_own() {
    let rows: Vec<Value> = (0..9).map(|i| idle(&format!("s{i}"), 10 + i)).collect();
    let c = Conf { own_machine: true, ..on() };
    let p = plan(&rows, true, Some(6), vec![target("b", 8.0)], &c, NOW);
    assert!(p.moves.is_empty(), "a host with room is not used: {:?}", p.moves);
    assert_eq!((p.spill, p.fresh.len()), (3, 3));
    assert!(p.fresh.iter().all(|m| m.target.is_empty()));
    assert_eq!(p.fresh[0].session_id, "s8", "longest idle first");
}

#[test]
fn a_session_asleep_past_awake_secs_stays_until_it_wakes() {
    let rows = vec![
        idle("asleep", 120),
        idle("woke", 6),
        idle("a", 7),
        idle("b", 8),
        idle("c", 9),
        idle("d", 10),
        idle("e", 11),
    ];
    let c = Conf { awake_secs: Some(15 * 60), ..on() };
    let p = plan(&rows, true, Some(6), vec![target("b", 8.0)], &c, NOW);
    assert_eq!(p.moves.len(), 1);
    assert_ne!(p.moves[0].session_id, "asleep");
    assert!(p.held.iter().any(|(id, why)| id == "asleep" && why.starts_with("asleep")));
}

#[test]
fn a_peer_info_becomes_a_row_with_work_below_read() {
    let quiet_info = json!({"sessionId": "p1", "status": "ready", "peer": "gcp-agent-lane-13",
        "queued": 0, "pendingPermissions": 0, "turn": null, "updatedAt": NOW - 20 * MIN,
        "backgroundsWork": true, "commandsRunning": 0, "subagentsRunning": 0,
        "subagentsWorkingSince": null, "bgTasksRunning": 0});
    let row = peer_row(&quiet_info);
    assert!(row.get("peer").is_none());
    // backgroundsWork says Claude Code can background a turn (Ctrl-B), not that work runs: a
    // quiet Claude session on a peer may move.
    assert_eq!(row["workingBelow"], json!(false));
    assert_eq!(held(&row, false, NOW, 0), None);
    for (key, v) in [
        ("commandsRunning", json!(1)),
        ("subagentsRunning", json!(2)),
        ("subagentsWorkingSince", json!(NOW - MIN)),
    ] {
        let mut info = quiet_info.clone();
        info[key] = v;
        let row = peer_row(&info);
        assert_eq!(row["workingBelow"], json!(true), "{key}");
        assert_eq!(held(&row, false, NOW, 0), Some("work runs below it"), "{key}");
    }
    let unknown = peer_row(&json!({"sessionId": "p3", "status": "ready", "queued": 0,
        "pendingPermissions": 0, "updatedAt": NOW - 20 * MIN, "backgroundsWork": true,
        "bgTasksRunning": 0}));
    assert!(unknown.get("workingBelow").is_none(), "backgroundsWork alone says nothing");
    assert!(held(&unknown, false, NOW, 0).is_some(), "no facts: unknown, never moved");
}

#[test]
fn a_running_background_task_holds_the_session() {
    // A bg task (bg_start, run_wait, a backgrounded shell: a pr-wait, a sleep, a build) stays
    // on this host when the session moves, and its wake with it: the session stays.
    let mut rows: Vec<Value> = (0..6).map(|i| running(&format!("r{i}"))).collect();
    let mut waits = idle("waits", 60);
    waits["bgTasksRunning"] = json!(1);
    let free = idle("free", 60);
    rows.extend([waits, free]);
    let p = plan(&rows, true, Some(6), vec![target("b", 10.0)], &on(), NOW);
    let moved: Vec<&str> = p.moves.iter().map(|m| m.session_id.as_str()).collect();
    assert_eq!(moved, ["free"]);
    assert!(p.held.iter().any(|(id, why)| id == "waits" && why.contains("background task runs")));
}

#[test]
fn an_old_peer_without_bg_facts_keeps_its_sessions_held_and_a_new_one_moves() {
    // Old daemon (before session-bg-facts-v1): its row has no bgTasksRunning. The pass cannot
    // tell a session with a wait running from one without, so it holds every one.
    let old_info = json!({"sessionId": "o1", "status": "ready", "queued": 0,
        "pendingPermissions": 0, "turn": null, "updatedAt": NOW - 20 * MIN,
        "backgroundsWork": true, "commandsRunning": 0, "subagentsRunning": 0,
        "subagentsWorkingSince": null});
    let old = peer_row(&old_info);
    assert_eq!(
        held(&old, true, NOW, 0),
        Some("its background tasks are unknown (its daemon predates session-bg-facts-v1)")
    );
    let mut rows: Vec<Value> = (0..6).map(|i| running(&format!("r{i}"))).collect();
    let mut stale = idle("stale", 60);
    stale.as_object_mut().unwrap().remove("bgTasksRunning");
    rows.push(stale);
    let p = plan(&rows, true, Some(6), vec![target("b", 10.0)], &on(), NOW);
    assert!(p.moves.is_empty(), "{:?}", p.moves);
    // New daemon: the same session says it runs none, and moves.
    let mut new_info = old_info.clone();
    new_info["bgTasksRunning"] = json!(0);
    assert_eq!(held(&peer_row(&new_info), true, NOW, 0), None);
}
