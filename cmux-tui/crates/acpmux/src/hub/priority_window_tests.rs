//! `_acpmux/priority_window` (`priority_window.rs`): the spec, the view and the row diffs.

use serde_json::{Value, json};

use super::*;

const NOW: i64 = 1_760_000_000_000;

fn summary(id: &str, state: &str, ago_minutes: i64) -> Value {
    json!({"sessionId": id, "name": id, "status": "idle",
           "lane": {"state": state, "since": NOW - ago_minutes * 60_000}})
}

fn lane(id: &str, state: &str, ago_minutes: i64) -> Lane {
    Lane::of(&summary(id, state, ago_minutes), None).expect("a lane")
}

fn spec(params: Value) -> WindowSpec {
    WindowSpec::from_params(&params).expect("a spec")
}

fn keys(message: &Value) -> Vec<&str> {
    message["keys"].as_array().into_iter().flatten().filter_map(Value::as_str).collect()
}

#[test]
fn a_spec_needs_its_window_name_and_reads_its_inputs() {
    assert!(WindowSpec::from_params(&json!({})).is_err());
    assert!(WindowSpec::from_params(&json!({"window": "w", "failing": "x"})).is_err());
    assert!(WindowSpec::from_params(&json!({"window": "w", "shown": 1})).is_err());
    assert!(WindowSpec::from_params(&json!({"window": "w", "kind": "other"})).is_err());
    assert!(WindowSpec::from_params(&json!({"window": "w", "marks": {"pinned": "a"}})).is_err());
    assert_eq!(spec(json!({"window": "w", "gen": 7})).generation, 7);
    let links = spec(json!({"window": "t", "kind": "links", "keys": ["a", "b"]}));
    assert_eq!(links.kind, WindowKind::Links { keys: vec!["a".into(), "b".into()] });
}

/// The view ranks this daemon's lanes with the lanes another owner reports; this daemon's lane
/// wins an id both list (the Mac app's stores, this Mac's first).
#[test]
fn the_view_ranks_this_daemons_lanes_with_the_clients_and_this_daemons_win() {
    let set = LaneSet::from_lanes([lane("asks", "input", 5), lane("idle", "idle", 3)]);
    let window = spec(json!({"window": "p", "lanes": [
        summary("asks", "idle", 1), summary("sub", "input", 1), summary("sub", "idle", 0)
    ]}));
    let view = view(&window, &set, NOW);
    let order: Vec<&str> = view.rows.iter().map(|(key, _)| key.as_str()).collect();
    assert_eq!(order, ["sub", "asks", "idle"]);
    assert_eq!(
        view.rows[1].1["state"], "needsYou",
        "this daemon's lane, not the client's idle copy"
    );
    assert_eq!(view.extra["needingInput"], json!(["sub", "asks"]));
    assert_eq!(view.extra["attentionCount"], 2);
    // idle (3 minutes ago) ages out in 24 hours less 3 minutes.
    assert_eq!(view.next_change, Some(NOW + 24 * 3_600_000 - 3 * 60_000));
}

/// An agent-started chat shows only once a tab opened it, or while pinned; with the view hidden
/// only the rows that need the person are kept (the bell's dot reads them).
#[test]
fn the_view_keeps_agent_started_chats_out_until_opened_and_hidden_keeps_only_attention() {
    let mut started = summary("started", "input", 1);
    started["lane"]["requiresOpen"] = json!(true);
    let set = LaneSet::from_lanes([
        Lane::of(&started, None).expect("a lane"),
        lane("busy", "working", 2),
    ]);
    let rows = |params: Value| -> Vec<String> {
        view(&spec(params), &set, NOW).rows.into_iter().map(|(key, _)| key).collect()
    };
    assert_eq!(rows(json!({"window": "p"})), ["busy"]);
    assert_eq!(rows(json!({"window": "p", "opened": ["started"]})), ["started", "busy"]);
    assert_eq!(rows(json!({"window": "p", "marks": {"pinned": ["started"]}})), ["started", "busy"]);
    assert_eq!(rows(json!({"window": "p", "opened": ["started"], "shown": false})), ["started"]);
    // Go to Next Agent Needing Input still visits it.
    assert_eq!(
        view(&spec(json!({"window": "p"})), &set, NOW).extra["needingInput"],
        json!(["started"])
    );
}

#[test]
fn the_first_message_is_full_and_later_ones_carry_only_changed_rows() {
    let mut set = LaneSet::from_lanes([lane("a", "idle", 2), lane("b", "idle", 1)]);
    let window = spec(json!({"window": "p"}));
    let mut state = WindowState::new(window.clone(), 0);
    let full = state.next(view(&window, &set, NOW)).expect("the first message");
    assert_eq!(full["full"], true);
    assert_eq!(full["revision"], 1);
    assert_eq!(keys(&full), ["b", "a"]);
    assert_eq!(full["rows"].as_array().map(Vec::len), Some(2));
    assert_eq!(state.next(view(&window, &set, NOW)), None, "nothing new, nothing sent");

    // One lane asks: it moves to the top, and only its row is sent.
    assert!(set.set("a".into(), Some(lane("a", "input", 0))));
    assert!(!set.set("a".into(), Some(lane("a", "input", 0))), "the same lane changes nothing");
    let diff = state.next(view(&window, &set, NOW)).expect("a diff");
    assert_eq!(diff["full"], false);
    assert_eq!(diff["revision"], 2);
    assert_eq!(keys(&diff), ["a", "b"]);
    assert_eq!(
        diff["rows"]
            .as_array()
            .map(|rows| rows.iter().map(|r| r["id"].clone()).collect::<Vec<Value>>()),
        Some(vec![json!("a")])
    );
    assert_eq!(diff["needingInput"], json!(["a"]));

    // It ends: its key leaves and no row is sent.
    assert!(set.set("a".into(), None));
    let gone = state.next(view(&window, &set, NOW)).expect("a diff");
    assert_eq!(keys(&gone), ["b"]);
    assert_eq!(gone["rows"], json!([]));
}

#[test]
fn a_replaced_spec_sends_every_row_again_with_a_later_revision() {
    let set = LaneSet::from_lanes([lane("a", "idle", 2)]);
    let window = spec(json!({"window": "p"}));
    let mut state = WindowState::new(window.clone(), 0);
    state.next(view(&window, &set, NOW));
    let pinned = spec(json!({"window": "p", "gen": 1, "marks": {"pinned": ["a"]}}));
    let mut replaced = WindowState::new(pinned.clone(), state.revision());
    let full = replaced.next(view(&pinned, &set, NOW)).expect("the first message");
    assert_eq!(full["full"], true);
    assert_eq!(full["revision"], 2);
    assert_eq!(full["gen"], 1);
    assert_eq!(full["rows"][0]["pinned"], true);
}

/// The session tree's window sends a session's links only when they change: a new step of a
/// working agent sends nothing.
#[test]
fn a_links_window_ignores_a_new_step() {
    let mut busy = summary("busy", "working", 1);
    busy["cwd"] = json!("/Users/me/cmux");
    let mut set = LaneSet::from_lanes([Lane::of(&busy, None).expect("a lane")]);
    let window = spec(json!({"window": "t", "kind": "links", "keys": ["busy", "missing"]}));
    let mut state = WindowState::new(window.clone(), 0);
    let full = state.next(view(&window, &set, NOW)).expect("the first message");
    assert_eq!(keys(&full), ["busy"]);
    assert_eq!(full["rows"][0]["cwd"], "/Users/me/cmux");
    assert!(full.get("needingInput").is_none());

    busy["lane"]["step"] = json!("Running tests");
    assert!(set.set("busy".into(), Lane::of(&busy, None)));
    assert_eq!(state.next(view(&window, &set, NOW)), None, "a step is not a link");
    busy["lane"]["state"] = json!("input");
    set.set("busy".into(), Lane::of(&busy, None));
    let diff = state.next(view(&window, &set, NOW)).expect("a diff");
    assert_eq!(diff["rows"][0]["state"], "input");
    assert_eq!(diff["rows"][0]["needsAttention"], true);
}

/// The person's marks go through the window: each mark's rule is acpmux's, and the next message
/// shows it at once. A mark on a chat the window does not list is refused.
#[test]
fn a_mark_changes_the_windows_marks_and_its_rows() {
    let set = LaneSet::from_lanes([lane("done", "idle", 20), lane("asks", "input", 5)]);
    let mut window = spec(json!({"window": "p", "lanes": [summary("remote", "idle", 1)]}));
    let mut state = WindowState::new(window.clone(), 0);
    state.next(view(&window, &set, NOW));
    let WindowKind::Priority(priority) = &mut window.kind else { panic!("a priority window") };
    let op = |params: Value| MarkOp::from_params(&params).expect("an op");
    priority.apply(&op(json!({"op": "snooze", "id": "asks"})), &set, NOW).expect("snoozed");
    priority.apply(&op(json!({"op": "pin", "id": "remote"})), &set, NOW).expect("pinned");
    assert!(priority.apply(&op(json!({"op": "read", "id": "nobody"})), &set, NOW).is_err());
    assert_eq!(priority.marks().snoozed["asks"].until_ms, NOW + 3_600_000);
    assert_eq!(priority.marks().snoozed["asks"].stamp, format!("input@{}", NOW - 5 * 60_000));
    state.spec = window.clone();
    let diff = state.next(view(&window, &set, NOW)).expect("a diff");
    assert_eq!(keys(&diff), ["remote", "done"]);
    assert_eq!(diff["needingInput"], json!([]));

    let WindowKind::Priority(priority) = &mut window.kind else { panic!("a priority window") };
    priority.apply(&op(json!({"op": "archive", "id": "gone"})), &set, NOW).expect("archived");
    priority.apply(&op(json!({"op": "prune"})), &set, NOW).expect("pruned");
    assert!(priority.marks().archived.is_empty(), "a mark of a chat nobody lists goes");
    assert!(priority.marks().pinned.contains("remote"), "the client's lanes are listed too");
    assert!(MarkOp::from_params(&json!({"op": "snooze", "id": "a", "durationMs": 0})).is_err());
    assert!(MarkOp::from_params(&json!({"op": "fly"})).is_err());
}

/// Go to Next Agent Needing Input reads the window's lanes and marks: the client's lanes too,
/// pinned first, a snoozed chat skipped, wrapping.
#[test]
fn next_needing_input_cycles_the_windows_waiting_chats() {
    let set = LaneSet::from_lanes([lane("here", "input", 10), lane("busy", "working", 1)]);
    let window = spec(json!({"window": "p", "lanes": [summary("there", "input", 2)]}));
    let next = |after: Option<&str>| next_needing_input(&window, &set, NOW, after);
    assert_eq!(next(None).as_deref(), Some("there"));
    assert_eq!(next(Some("there")).as_deref(), Some("here"));
    assert_eq!(next(Some("here")).as_deref(), Some("there"));
    assert_eq!(next(Some("busy")).as_deref(), Some("there"), "a chat that does not wait");
    let pinned = spec(json!({"window": "p", "marks": {"pinned": ["here"]}}));
    assert_eq!(next_needing_input(&pinned, &set, NOW, None).as_deref(), Some("here"));
    let links = spec(json!({"window": "t", "kind": "links", "keys": ["here"]}));
    assert_eq!(next_needing_input(&links, &set, NOW, None), None);
}
