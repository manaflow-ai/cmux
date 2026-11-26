//! `workspace-list-delta-v1`: the ring of changed ids, and a daemon that answers one rename with
//! one entry.

use super::super::tests::captured_writer;
use super::*;
use crate::SurfaceOptions;
use crate::server::{Command, handle_command};

fn cursor(ring: &WorkspaceDeltaRing, seq: u64) -> DeltaCursor {
    DeltaCursor { epoch: ring.epoch().to_string(), seq }
}

fn ids(delta: &Delta) -> Vec<u64> {
    delta.ids.iter().copied().collect()
}

#[test]
fn the_first_read_is_the_baseline_and_a_change_moves_only_its_id() {
    let mut ring = WorkspaceDeltaRing::new("e".into(), 8);
    assert_eq!(ring.since(&cursor(&ring, 0)), None, "no tree read yet");
    let base = ring.record(&[(1, 10), (2, 20), (3, 30)], 0);
    assert_eq!(base, 1);
    assert_eq!(ring.since(&cursor(&ring, base)), Some(Delta::default()));
    // The same tree again moves nothing.
    assert_eq!(ring.record(&[(1, 10), (2, 20), (3, 30)], 0), base);
    let renamed = ring.record(&[(1, 10), (2, 21), (3, 30)], 0);
    assert_eq!(renamed, 2);
    let delta = ring.since(&cursor(&ring, base)).unwrap();
    assert_eq!(ids(&delta), vec![2]);
    assert!(!delta.order && !delta.groups);
    assert_eq!(ring.since(&cursor(&ring, renamed)), Some(Delta::default()));
}

#[test]
fn a_removed_or_added_id_and_a_new_order_or_groups_say_so() {
    let mut ring = WorkspaceDeltaRing::new("e".into(), 8);
    let base = ring.record(&[(1, 10), (2, 20)], 0);
    ring.record(&[(2, 20), (3, 30)], 0);
    let delta = ring.since(&cursor(&ring, base)).unwrap();
    assert_eq!(ids(&delta), vec![1, 3], "1 went away, 3 came");
    assert!(delta.order);
    let moved = ring.seq();
    ring.record(&[(3, 30), (2, 20)], 0);
    let delta = ring.since(&cursor(&ring, moved)).unwrap();
    assert!(delta.ids.is_empty() && delta.order && !delta.groups);
    let reordered = ring.seq();
    ring.record(&[(3, 30), (2, 20)], 7);
    let delta = ring.since(&cursor(&ring, reordered)).unwrap();
    assert!(delta.ids.is_empty() && !delta.order && delta.groups);
}

#[test]
fn the_ring_wraps_and_a_cursor_older_than_it_gets_none() {
    let mut ring = WorkspaceDeltaRing::new("e".into(), 4);
    let base = ring.record(&[(1, 0), (2, 0)], 0);
    // Six one-id changes into a ring of four ids: the two oldest seqs leave it.
    for round in 1..=6u64 {
        ring.record(&[(1, round), (2, 0)], 0);
    }
    assert_eq!(ring.seq(), base + 6);
    assert_eq!(ring.since(&cursor(&ring, base)), None, "older than the ring");
    assert_eq!(ring.since(&cursor(&ring, base + 1)), None, "still older than the ring");
    let delta = ring.since(&cursor(&ring, base + 2)).unwrap();
    assert_eq!(ids(&delta), vec![1]);
    // A change bigger than the whole ring leaves no seq before it answerable.
    let before = ring.seq();
    ring.record(&[(1, 99), (2, 99), (3, 99), (4, 99), (5, 99)], 0);
    assert_eq!(ring.since(&cursor(&ring, before)), None);
    assert_eq!(ring.since(&cursor(&ring, ring.seq())), Some(Delta::default()));
}

#[test]
fn another_epoch_or_a_seq_never_given_gets_none() {
    let mut ring = WorkspaceDeltaRing::new("e".into(), 8);
    let base = ring.record(&[(1, 0)], 0);
    assert_eq!(ring.since(&DeltaCursor { epoch: "other".into(), seq: base }), None);
    assert_eq!(ring.since(&cursor(&ring, base + 1)), None, "a seq from the future");
}

fn run(mux: &Arc<Mux>, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    let (writer, _) = captured_writer();
    handle_command(mux, mux.local_test_client(0), command, &writer).unwrap()
}

fn list_since(mux: &Arc<Mux>, epoch: &Value, seq: &Value) -> Value {
    run(mux, json!({"cmd": "list-workspaces", "since": {"epoch": epoch, "seq": seq}}))
}

#[test]
fn one_rename_after_since_is_one_changed_entry_far_smaller_than_the_tree() {
    let mux = Mux::new_for_test("workspace-delta", SurfaceOptions::default());
    let mut workspaces = Vec::new();
    for index in 0..40 {
        let created =
            mux.create_empty_workspace(Some(format!("workspace {index}")), None, None).unwrap();
        workspaces.push(created.workspace);
    }

    // No cursor yet: the whole tree, and a cursor.
    let whole = list_since(&mux, &json!(""), &json!(0));
    assert!(whole.get("delta").is_none(), "{whole}");
    assert_eq!(whole["workspaces"].as_array().unwrap().len(), 40);
    let (epoch, seq) = (whole["epoch"].clone(), whole["seq"].clone());
    assert!(epoch.is_string() && seq.is_u64(), "{whole}");

    // Nothing changed: an empty delta.
    let same = list_since(&mux, &epoch, &seq);
    assert_eq!(same["delta"], json!(true), "{same}");
    assert_eq!(same["changed"], json!([]));
    assert_eq!(same["removed"], json!([]));
    assert_eq!(same["seq"], seq);

    assert!(mux.rename_workspace(workspaces[17], "renamed".into()));
    let delta = list_since(&mux, &epoch, &seq);
    assert_eq!(delta["delta"], json!(true), "{delta}");
    let changed = delta["changed"].as_array().unwrap();
    assert_eq!(changed.len(), 1, "{delta}");
    assert_eq!(changed[0]["id"], json!(workspaces[17]));
    assert_eq!(changed[0]["name"], json!("renamed"));
    assert_eq!(delta["removed"], json!([]));
    assert_eq!(delta["workspaces"], json!([]));
    assert!(delta.get("order").is_none() && delta.get("groups").is_none(), "{delta}");
    assert!(delta["seq"].as_u64() > seq.as_u64());
    // The entry is the one the whole tree renders.
    let tree = run(&mux, json!({"cmd": "list-workspaces"}));
    let rendered =
        tree["workspaces"].as_array().unwrap().iter().find(|w| w["id"] == changed[0]["id"]);
    assert_eq!(Some(&changed[0]), rendered);

    let tree_bytes = serde_json::to_vec(&tree).unwrap().len();
    let delta_bytes = serde_json::to_vec(&delta).unwrap().len();
    println!("one rename: delta {delta_bytes} bytes, whole tree {tree_bytes} bytes");
    assert!(delta_bytes * 10 < tree_bytes, "delta {delta_bytes} vs tree {tree_bytes}");

    // A closed workspace is a removed id, and the order says so.
    let seq = delta["seq"].clone();
    assert!(mux.close_workspace(workspaces[3]));
    let closed = list_since(&mux, &epoch, &seq);
    assert_eq!(closed["removed"], json!([workspaces[3]]), "{closed}");
    assert_eq!(closed["order"].as_array().unwrap().len(), 39);

    // Another daemon run's cursor: the whole tree again.
    let restarted = list_since(&mux, &json!("0000000000000000"), &seq);
    assert!(restarted.get("delta").is_none());
    assert_eq!(restarted["workspaces"].as_array().unwrap().len(), 39);
    mux.shutdown();
}

#[test]
fn a_list_without_since_is_byte_identical_and_the_capability_is_advertised() {
    let mux = Mux::new_for_test("workspace-delta-absent", SurfaceOptions::default());
    mux.create_empty_workspace(Some("one".into()), None, None).unwrap();
    let listed = run(&mux, json!({"cmd": "list-workspaces"}));
    let mut expected = super::super::list_workspaces_reply(&mux).unwrap();
    expected.set("lines_written_before_read", json!(0));
    assert_eq!(listed.to_string(), expected.to_string());
    let null = run(&mux, json!({"cmd": "list-workspaces", "since": null}));
    assert_eq!(null.to_string(), expected.to_string());
    let identify = run(&mux, json!({"cmd": "identify"}));
    assert!(
        identify["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == WORKSPACE_LIST_DELTA_CAPABILITY),
        "{identify}"
    );
    mux.shutdown();
}
