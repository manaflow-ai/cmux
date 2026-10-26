//! `oracle-state` after a fixed op script equals the checked-in
//! `oracle_state_expected.json`, and its session is the `session.snapshot`
//! builder's own value at the same journal head.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde_json::{Value, json};

use super::{oracle_state, runtime_counts};
use crate::{Mux, SplitDir, SurfaceOptions};

const SESSION: &str = "oracle-state-script";

/// Two workspaces; the first split once, the second with a second tab.
fn run_script(mux: &Arc<Mux>) {
    let first = mux.new_workspace(Some("one".into()), Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    mux.split(pane, SplitDir::Right, None).unwrap();
    let second = mux.new_workspace(Some("two".into()), Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
    mux.new_tab(Some(pane), None, None).unwrap();
}

/// The reply with what varies by host replaced: the session by its object
/// counts (ids and times are random), the journal head by whether it is the
/// cut's, the panic log path by the core path rule's.
fn comparable(reply: &Value, mux: &Mux) -> Value {
    let session = reply["session"].as_object().expect("session is an object");
    let counts: BTreeMap<_, _> = session
        .iter()
        .filter_map(|(key, value)| value.as_array().map(|items| (key.clone(), items.len())))
        .collect();
    let (_, head) = crate::resource_api::public_session_snapshot_with_journal_head(mux).unwrap();
    let path = crate::diagnostics::owner_panic_log_path(SESSION).map(|p| p.display().to_string());
    assert_eq!(reply["panicLog"]["path"], json!(path), "the owner's panic log path");
    let mut out = reply.clone();
    out["session"] = json!({ "keys": session.keys().collect::<Vec<_>>(), "counts": counts });
    out["journal_head"] = json!(reply["journal_head"].as_u64() == Some(head));
    out["panicLog"]["path"] = json!("$STATE/owner-panics-oracle-state-script.jsonl");
    out
}

#[test]
fn oracle_state_after_a_fixed_script_equals_the_checked_in_json() {
    let mux = Mux::new_for_test(SESSION, SurfaceOptions::default());
    run_script(&mux);
    let reply = serde_json::to_value(oracle_state(&mux, BTreeMap::new()).unwrap()).unwrap();
    let expected: Value =
        serde_json::from_str(include_str!("oracle_state_expected.json")).expect("expected JSON");
    assert_eq!(comparable(&reply, &mux), expected, "{reply:#}");
}

#[test]
fn oracle_state_session_is_the_session_snapshot_at_its_head() {
    let mux = Mux::new_for_test("oracle-state-cut", SurfaceOptions::default());
    run_script(&mux);
    let state = oracle_state(&mux, BTreeMap::new()).unwrap();
    let (snapshot, head) =
        crate::resource_api::public_session_snapshot_with_journal_head(&mux).unwrap();
    assert_eq!(state.journal_head, head);
    let strip = |mut value: Value| {
        // `connected_seconds` ticks between the two reads.
        for client in value["clients"].as_array_mut().into_iter().flatten() {
            client.as_object_mut().unwrap().remove("connected_seconds");
        }
        value
    };
    assert_eq!(strip(state.session), strip(snapshot));
}

#[test]
fn oracle_state_reports_switch_arms_and_sorted_keys() {
    let mux = Mux::new_for_test("oracle-state-switches", SurfaceOptions::default());
    let switches = BTreeMap::from([("zeta", "new"), ("alpha", "old")]);
    let reply = serde_json::to_string(&oracle_state(&mux, switches).unwrap()).unwrap();
    let alpha = reply.find("\"alpha\"").unwrap();
    assert!(alpha < reply.find("\"zeta\"").unwrap(), "{reply}");
    let live = reply.find("\"liveObjects\":{").unwrap();
    let keys =
        ["browsers", "panes", "screens", "subscriptions", "terminals", "views", "workspaces"];
    let found: Vec<_> =
        keys.iter().map(|key| reply[live..].find(&format!("\"{key}\"")).unwrap()).collect();
    assert!(found.windows(2).all(|pair| pair[0] < pair[1]), "{reply}");
}

#[test]
fn a_dead_terminal_counts_as_dead_not_attached() {
    let mux = Mux::new_for_test("oracle-state-dead", SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let before = mux.with_state(runtime_counts).0;
    assert_eq!((before.attached, before.detached, before.dead), (1, 0, 0));
    surface.mark_dead_for_test();
    let after = mux.with_state(runtime_counts).0;
    assert_eq!((after.attached, after.detached, after.dead), (0, 0, 1));
}
