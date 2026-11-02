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

fn peer_lane(id: &str, peer: &str, state: &str) -> Lane {
    let mut row = summary(id, state, 1);
    row["peer"] = json!(peer);
    Lane::of(&row, None).expect("a lane")
}

fn spec(params: Value) -> WindowSpec {
    WindowSpec::from_params(&params).expect("a spec")
}

fn keys(message: &Value) -> Vec<&str> {
    message["keys"].as_array().into_iter().flatten().filter_map(Value::as_str).collect()
}

fn none() -> Marks {
    Marks::default()
}

fn pinned(ids: &[&str]) -> Marks {
    Marks { pinned: ids.iter().map(|id| (*id).to_owned()).collect(), ..Marks::default() }
}

fn set_lane(set: &mut LaneSet, id: &str, lane: Option<Lane>) -> bool {
    set.apply(LaneChange { id: id.to_owned(), lane, from_peer: false })
}

#[test]
fn a_spec_needs_its_window_name_and_reads_its_inputs() {
    assert!(WindowSpec::from_params(&json!({})).is_err());
    assert!(WindowSpec::from_params(&json!({"window": "w", "failing": "x"})).is_err());
    assert!(WindowSpec::from_params(&json!({"window": "w", "shown": 1})).is_err());
    assert!(WindowSpec::from_params(&json!({"window": "w", "kind": "other"})).is_err());
    assert!(
        WindowSpec::from_params(&json!({"window": "w", "importMarks": {"pinned": "a"}})).is_err()
    );
    assert!(WindowSpec::from_params(&json!({"window": "w", "peerNames": {"mini": 1}})).is_err());
    assert!(WindowSpec::from_params(&json!({"window": "w", "localMachine": ""})).is_err());
    assert_eq!(spec(json!({"window": "w", "gen": 7})).generation, 7);
    let links = spec(json!({"window": "t", "kind": "links", "keys": ["a", "b"]}));
    assert_eq!(links.kind, WindowKind::Links { keys: vec!["a".into(), "b".into()] });
    let import = spec(json!({"window": "p", "importMarks": {"pinned": ["a"]}}));
    let WindowKind::Priority(priority) = &import.kind else { panic!("a priority window") };
    assert_eq!(priority.import(), Some(&pinned(&["a"])));
}

/// The view ranks this daemon's lanes with the lanes another owner reports; this daemon's lane
/// wins an id both list (the Mac app's stores, this Mac's first).
#[test]
fn the_view_ranks_this_daemons_lanes_with_the_clients_and_this_daemons_win() {
    let set = LaneSet::from_lanes([lane("asks", "input", 5), lane("idle", "idle", 3)]);
    let window = spec(json!({"window": "p", "lanes": [
        summary("asks", "idle", 1), summary("sub", "input", 1), summary("sub", "idle", 0)
    ]}));
    let view = view(&window, &set, &none(), NOW);
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

/// A row names its machine as the app named it: a peer's display name (else its name), this
/// Mac's tag for its own lanes while the app shows one, and the client's own tag for a lane it
/// read from another machine.
#[test]
fn a_row_names_its_machine_as_the_app_did() {
    let set = LaneSet::from_lanes([
        lane("here", "idle", 1),
        peer_lane("named", "mini", "idle"),
        peer_lane("bare", "box", "idle"),
    ]);
    let mut remote = summary("remote", "idle", 1);
    remote["machine"] = json!("Cloud VM");
    let window =
        spec(json!({"window": "p", "localMachine": "Studio", "peerNames": {"mini": "Mac mini"},
                             "lanes": [remote]}));
    let view = view(&window, &set, &none(), NOW);
    let machine = |id: &str| {
        view.rows.iter().find(|(key, _)| key == id).map(|(_, row)| row["machine"].clone())
    };
    assert_eq!(machine("here"), Some(json!("Studio")));
    assert_eq!(machine("named"), Some(json!("Mac mini")));
    assert_eq!(machine("bare"), Some(json!("box")));
    assert_eq!(machine("remote"), Some(json!("Cloud VM")));
    let untagged = super::view(&spec(json!({"window": "p"})), &set, &none(), NOW);
    assert_eq!(
        untagged.rows.iter().find(|(key, _)| key == "here").map(|(_, r)| r["machine"].clone()),
        Some(Value::Null)
    );
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
    let rows = |params: Value, marks: &Marks| -> Vec<String> {
        view(&spec(params), &set, marks, NOW).rows.into_iter().map(|(key, _)| key).collect()
    };
    assert_eq!(rows(json!({"window": "p"}), &none()), ["busy"]);
    assert_eq!(rows(json!({"window": "p", "opened": ["started"]}), &none()), ["started", "busy"]);
    assert_eq!(rows(json!({"window": "p"}), &pinned(&["started"])), ["started", "busy"]);
    assert_eq!(
        rows(json!({"window": "p", "opened": ["started"], "shown": false}), &none()),
        ["started"]
    );
    // Go to Next Agent Needing Input still visits it.
    assert_eq!(
        view(&spec(json!({"window": "p"})), &set, &none(), NOW).extra["needingInput"],
        json!(["started"])
    );
}

#[test]
fn the_first_message_is_full_and_later_ones_carry_only_changed_rows() {
    let mut set = LaneSet::from_lanes([lane("a", "idle", 2), lane("b", "idle", 1)]);
    let window = spec(json!({"window": "p"}));
    let mut state = WindowState::new(window.clone(), 0);
    let full = state.next(view(&window, &set, &none(), NOW)).expect("the first message");
    assert_eq!(full["full"], true);
    assert_eq!(full["revision"], 1);
    assert_eq!(keys(&full), ["b", "a"]);
    assert_eq!(full["rows"].as_array().map(Vec::len), Some(2));
    assert_eq!(state.next(view(&window, &set, &none(), NOW)), None, "nothing new, nothing sent");

    // One lane asks: it moves to the top, and only its row is sent.
    assert!(set_lane(&mut set, "a", Some(lane("a", "input", 0))));
    assert!(!set_lane(&mut set, "a", Some(lane("a", "input", 0))), "the same lane changes nothing");
    let diff = state.next(view(&window, &set, &none(), NOW)).expect("a diff");
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
    assert!(set_lane(&mut set, "a", None));
    let gone = state.next(view(&window, &set, &none(), NOW)).expect("a diff");
    assert_eq!(keys(&gone), ["b"]);
    assert_eq!(gone["rows"], json!([]));
}

/// A peer's row never replaces or removes this daemon's own lane of the same id, as the full
/// read keeps this daemon's first.
#[test]
fn a_peers_row_never_replaces_this_daemons_lane() {
    let mut set =
        LaneSet::from_lanes([lane("same", "input", 1), peer_lane("same", "mini", "idle")]);
    assert_eq!(set.get("same").map(|l| l.peer.clone()), Some(None));
    let from_peer = |lane: Option<Lane>| LaneChange { id: "same".into(), lane, from_peer: true };
    assert!(!set.apply(from_peer(Some(peer_lane("same", "mini", "working")))));
    assert!(!set.apply(from_peer(None)));
    assert_eq!(set.get("same").map(|l| l.state), Some(super::super::priority::LaneState::Input));
    assert!(set.apply(LaneChange {
        id: "p".into(),
        lane: Some(peer_lane("p", "mini", "idle")),
        from_peer: true
    }));
    assert!(set.apply(LaneChange { id: "p".into(), lane: None, from_peer: true }));
}

/// The marks are the daemon's, not the spec's: a window with other marks shows them at once.
#[test]
fn the_view_reads_the_daemons_marks() {
    let set = LaneSet::from_lanes([lane("a", "idle", 2), lane("b", "idle", 1)]);
    let window = spec(json!({"window": "p"}));
    let mut state = WindowState::new(window.clone(), 0);
    state.next(view(&window, &set, &none(), NOW));
    let diff = state.next(view(&window, &set, &pinned(&["a"]), NOW)).expect("a diff");
    assert_eq!(keys(&diff), ["a", "b"]);
    assert_eq!(diff["rows"][0]["pinned"], true);
}

#[test]
fn a_replaced_spec_sends_every_row_again_with_a_later_revision() {
    let set = LaneSet::from_lanes([lane("a", "idle", 2)]);
    let window = spec(json!({"window": "p"}));
    let mut state = WindowState::new(window.clone(), 0);
    state.next(view(&window, &set, &none(), NOW));
    let shown = spec(json!({"window": "p", "gen": 1, "shown": false}));
    let mut replaced = WindowState::new(shown.clone(), state.revision());
    let full = replaced.next(view(&shown, &set, &none(), NOW)).expect("the first message");
    assert_eq!(full["full"], true);
    assert_eq!(full["revision"], 2);
    assert_eq!(full["gen"], 1);
    assert_eq!(full["rows"], json!([]), "hidden: only rows that need the person");
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
    let full = state.next(view(&window, &set, &none(), NOW)).expect("the first message");
    assert_eq!(keys(&full), ["busy"]);
    assert_eq!(full["rows"][0]["cwd"], "/Users/me/cmux");
    assert!(full.get("needingInput").is_none());

    busy["lane"]["step"] = json!("Running tests");
    assert!(set_lane(&mut set, "busy", Lane::of(&busy, None)));
    assert_eq!(state.next(view(&window, &set, &none(), NOW)), None, "a step is not a link");
    busy["lane"]["state"] = json!("input");
    set_lane(&mut set, "busy", Lane::of(&busy, None));
    let diff = state.next(view(&window, &set, &none(), NOW)).expect("a diff");
    assert_eq!(diff["rows"][0]["state"], "input");
    assert_eq!(diff["rows"][0]["needsAttention"], true);
}

/// A mark is checked against the window's lanes (a chat it does not list is refused) and then
/// applied to the daemon's marks: each mark's rule is acpmux's.
#[test]
fn a_mark_is_checked_against_the_windows_lanes_then_applied() {
    let set = LaneSet::from_lanes([lane("done", "idle", 20), lane("asks", "input", 5)]);
    let window = spec(json!({"window": "p", "lanes": [summary("remote", "idle", 1)]}));
    let WindowKind::Priority(priority) = &window.kind else { panic!("a priority window") };
    let op = |params: Value| MarkOp::from_params(&params).expect("an op");
    let apply = |marks: &mut Marks, params: Value| -> Result<(), String> {
        priority.mark(op(params), &set).map(|mark| mark.apply(marks, NOW))
    };
    let mut marks = Marks::default();
    apply(&mut marks, json!({"op": "snooze", "id": "asks"})).expect("snoozed");
    apply(&mut marks, json!({"op": "pin", "id": "remote"})).expect("pinned");
    assert!(apply(&mut marks, json!({"op": "read", "id": "nobody"})).is_err());
    assert!(
        apply(&mut marks, json!({"op": "archive", "id": "nobody"})).is_err(),
        "no owner lists it"
    );
    apply(&mut marks, json!({"op": "unarchive", "id": "gone"})).expect("names no chat");
    let mut ranked = WindowState::new(window.clone(), 0);
    let message = ranked.next(view(&window, &set, &marks, NOW)).expect("a message");
    assert_eq!(keys(&message), ["remote", "done"]);
    assert_eq!(message["needingInput"], json!([]));
    assert_eq!(marks.snoozed["asks"].until_ms, NOW + 3_600_000);
    assert_eq!(marks.snoozed["asks"].stamp, format!("input@{}", NOW - 5 * 60_000));

    marks.archived.insert("gone".into());
    apply(&mut marks, json!({"op": "prune"})).expect("pruned");
    assert!(marks.archived.is_empty(), "a mark of a chat nobody lists goes");
    assert!(marks.pinned.contains("remote"), "the client's lanes are listed too");
    assert!(MarkOp::from_params(&json!({"op": "snooze", "id": "a", "durationMs": 0})).is_err());
    assert!(MarkOp::from_params(&json!({"op": "fly"})).is_err());
}

/// Go to Next Agent Needing Input reads the window's lanes and the marks: the client's lanes
/// too, pinned first, wrapping.
#[test]
fn next_needing_input_cycles_the_windows_waiting_chats() {
    let set = LaneSet::from_lanes([lane("here", "input", 10), lane("busy", "working", 1)]);
    let window = spec(json!({"window": "p", "lanes": [summary("there", "input", 2)]}));
    let next = |after: Option<&str>| next_needing_input(&window, &set, &none(), NOW, after);
    assert_eq!(next(None).as_deref(), Some("there"));
    assert_eq!(next(Some("there")).as_deref(), Some("here"));
    assert_eq!(next(Some("here")).as_deref(), Some("there"));
    assert_eq!(next(Some("busy")).as_deref(), Some("there"), "a chat that does not wait");
    assert_eq!(
        next_needing_input(&window, &set, &pinned(&["here"]), NOW, None).as_deref(),
        Some("here")
    );
    let links = spec(json!({"window": "t", "kind": "links", "keys": ["here"]}));
    assert_eq!(next_needing_input(&links, &set, &none(), NOW, None), None);
}

fn peer_event(kind: &str, summary: Value) -> HubEvent {
    HubEvent {
        session_id: "s1".into(),
        record: std::sync::Arc::new(crate::store::EventRecord {
            seq: 1,
            at: 0,
            dir: "peer".into(),
            kind: kind.into(),
            msg: Value::Null,
            host_seq: None,
        }),
        remote: Some(super::super::RemoteRef { peer: "mini".into(), summary }),
    }
}

fn memory_hub() -> std::sync::Arc<Hub> {
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["true"]}}, "defaultHarness": "fake",
    }))
    .expect("a config");
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store =
        crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).expect("a store");
    Hub::new(cfg, store)
}

/// A peer's purge carries the row it removed, lane and all: the lane is gone, not written back.
/// A peer's change writes its lane, under the row's id and with its peer.
#[tokio::test]
async fn a_peers_purge_removes_its_lane_and_a_change_writes_it() {
    let hub = memory_hub();
    let row = summary("s1", "input", 1);
    let change = hub.lane_after(&peer_event("purged", row.clone()));
    assert_eq!(change, LaneChange { id: "s1".into(), lane: None, from_peer: true });
    let change = hub.lane_after(&peer_event("status", row));
    assert_eq!(change.id, "s1");
    assert_eq!(change.lane.and_then(|lane| lane.peer).as_deref(), Some("mini"));
}

/// Archive is a request to the acpmux that owns the chat: the app refused it for a chat no
/// acpmux socket of its own lists (another machine's chat tab), and kept it for this daemon's
/// chats and the Chief home's (`AgentPriorityChats.archive`). A reported lane says the client
/// has its owner's socket with `archivable`.
#[test]
fn archive_is_refused_for_a_chat_no_owning_acpmux_lists() {
    let set = LaneSet::from_lanes([lane("here", "idle", 1)]);
    let mut chief = summary("chief-sub", "idle", 1);
    chief["archivable"] = json!(true);
    let window =
        spec(json!({"window": "p", "lanes": [chief, summary("other-machine", "idle", 1)]}));
    let WindowKind::Priority(priority) = &window.kind else { panic!("a priority window") };
    let archive = |id: &str| priority.mark(MarkOp::Archive(id.to_owned()), &set);
    assert!(archive("here").is_ok(), "this daemon's chat");
    assert!(archive("chief-sub").is_ok(), "a chat the client's own acpmux socket lists");
    assert!(archive("other-machine").is_err(), "another machine's chat: no acpmux to archive it");
    // Other marks stay with any chat the window lists.
    assert!(priority.mark(MarkOp::TogglePin("other-machine".into()), &set).is_ok());
}
