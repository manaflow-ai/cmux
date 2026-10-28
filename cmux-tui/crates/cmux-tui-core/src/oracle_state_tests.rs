//! `oracle-state` after a fixed op script equals the checked-in
//! `oracle_state_expected.json`, and its counts come from the snapshot's cut.
//! The `session` against the wire `session.snapshot` is in
//! server/oracle_state_command_tests.rs.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde_json::{Value, json};

use super::{child_exits, launch_switch_arms, oracle_state, runtime_counts};
use crate::{Mux, SplitDir, SurfaceOptions};

const SESSION: &str = "oracle-state-script";
/// No control connection: `session.clients` is empty.
const NO_CLIENT: u64 = 0;

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
    mux.install_oracle_switches_for_test(BTreeMap::from([("terminal-holder", "old")]));
    run_script(&mux);
    let reply = serde_json::to_value(oracle_state(&mux, NO_CLIENT).unwrap()).unwrap();
    let expected: Value =
        serde_json::from_str(include_str!("oracle_state_expected.json")).expect("expected JSON");
    assert_eq!(comparable(&reply, &mux), expected, "{reply:#}");
}

#[test]
fn the_runtime_counts_are_read_inside_the_snapshot_cut() {
    let mux = Mux::new_for_test("oracle-state-cut", SurfaceOptions::default());
    run_script(&mux);
    // The visitor runs while the projection holds the state lock, so no
    // mutation can land between the session and the counts.
    let (_, _, state_held) = crate::resource_api::public_session_snapshot_at_cut(&mux, |_| {
        mux.state.try_lock().is_err()
    })
    .unwrap();
    assert!(state_held, "the visitor ran outside the projection lock");

    let state = oracle_state(&mux, NO_CLIENT).unwrap();
    let session_len = |key: &str| state.session[key].as_array().map_or(0, Vec::len) as u64;
    for kind in ["browsers", "panes", "screens", "terminals", "workspaces"] {
        assert_eq!(state.live_objects[kind], session_len(kind), "{kind}: {:#}", state.session);
    }
}

#[test]
fn oracle_state_reports_switch_arms_and_sorted_keys() {
    let mux = Mux::new_for_test("oracle-state-switches", SurfaceOptions::default());
    mux.install_oracle_switches_for_test(BTreeMap::from([("zeta", "new"), ("alpha", "old")]));
    let reply = serde_json::to_string(&oracle_state(&mux, NO_CLIENT).unwrap()).unwrap();
    let alpha = reply.find("\"alpha\"").unwrap();
    assert!(alpha < reply.find("\"zeta\"").unwrap(), "{reply}");
    let live = reply.find("\"liveObjects\":{").unwrap();
    let keys = [
        "browsers",
        "holders",
        "panes",
        "screens",
        "subscriptions",
        "terminals",
        "views",
        "workspaces",
    ];
    let found: Vec<_> =
        keys.iter().map(|key| reply[live..].find(&format!("\"{key}\"")).unwrap()).collect();
    assert!(found.windows(2).all(|pair| pair[0] < pair[1]), "{reply}");
}

#[test]
fn the_launch_arms_report_the_holder_model() {
    let mux = Mux::new_for_test("oracle-state-launch", SurfaceOptions::default());
    let holder = if crate::holder_runtime::enabled() { "new" } else { "old" };
    assert_eq!(launch_switch_arms(), BTreeMap::from([("terminal-holder", holder)]));
    assert_eq!(mux.oracle_switches(), &launch_switch_arms(), "the default is the launch value");
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

/// I17's daemon source: `childExits.holder` is the holder
/// exits this owner counted where it logged them. The loss log in the state
/// root is not read: its lines from other sessions sharing the root, an owner
/// stop on a requested signal and a rotation that drops the old file change
/// nothing, and the count never falls while the owner runs.
#[test]
fn child_exits_are_this_owners_counted_holder_exits() {
    let dir = TempDir::new();
    let root = dir.0.join("terminal-hosts-x");
    let line = |value: Value| format!("{value}\n");
    let other_session = [
        line(json!({"terminal_id": "other", "end": {"kind": "host_lost"}})),
        line(json!({"event": "host_replaced", "terminal_id": "other"})),
        line(json!({"event": "daemon_signal", "signal": 15})),
    ]
    .concat();
    std::fs::write(dir.0.join("terminal-losses.jsonl"), &other_session).unwrap();
    let options = SurfaceOptions { terminal_host_root: Some(root), ..SurfaceOptions::default() };
    let mux = Mux::new_for_test("oracle-state-exits", options);
    let exits = |mux: &Mux| oracle_state(mux, NO_CLIENT).unwrap().child_exits;
    assert_eq!(exits(&mux), BTreeMap::from([("holder", 0)]));
    mux.note_holder_exit();
    mux.note_holder_exit();
    assert_eq!(exits(&mux), BTreeMap::from([("holder", 2)]));
    // A rotation renames the current file over the old one.
    std::fs::rename(dir.0.join("terminal-losses.jsonl"), dir.0.join("terminal-losses.jsonl.1"))
        .unwrap();
    assert_eq!(exits(&mux), BTreeMap::from([("holder", 2)]));
    assert_eq!(child_exits(5), BTreeMap::from([("holder", 5)]));
}

/// A state root of one test, removed after it.
struct TempDir(std::path::PathBuf);

impl TempDir {
    fn new() -> Self {
        let mut bytes = [0u8; 8];
        getrandom::fill(&mut bytes).expect("random");
        let name: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let dir = std::env::temp_dir().join(format!("cmux-oracle-state-{name}"));
        std::fs::create_dir_all(&dir).expect("temp dir");
        Self(dir)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
