//! A get of one tab, pane, screen or workspace reads its workspace, not the
//! session (AGENT TRAFFIC 800).
//!
//! `tab.get`, `pane.get`, `screen.get`, `workspace.get` and
//! `pane.neighbor.get` built the whole session snapshot under the registry
//! and state locks to find one item: 70 to 97 ms of lock hold at 826
//! workspaces. An agent's CLI call with a `current` selector makes three of
//! them (`cli/resolve.rs` `caller_path_of`), and the person's split or new
//! tab waits for those locks.
//!
//! The guard runs on an on-disk registry of 60 and of 826 workspaces (the
//! session size rule) and counts, on the reading thread: session snapshots
//! built and whole-topology loads. Counts, not times. Each answer equals the
//! row the session snapshot lists. Then a writer holds the registry lock
//! and each get must still answer.

use std::cell::Cell;
use std::rc::Rc;
use std::sync::mpsc::sync_channel;

use serde_json::{Map, Value, json};

use super::*;
use crate::resource_api::{public_session_snapshot, set_snapshot_before_projection_hook};

/// How long a get may take to answer while the registry lock is held. A get
/// that waits for the lock never answers; one that does not answers in
/// milliseconds, so the bound is generous for a loaded machine.
const HELD_LOCK_ANSWER: Duration = Duration::from_secs(5);

const COLLECTIONS: [&str; 4] = ["workspaces", "screens", "panes", "tabs"];

/// A session of `workspaces` workspaces on an on-disk registry. The last
/// two hold two panes and three tabs; the rest are workspace rows only.
/// Returns the first pane of each of the two.
///
/// The workspace rows come first: `create_empty_workspace` takes the focus
/// and commits the workspace row and the active workspace alone, so a screen
/// made before it would keep `focused: true` in the journal, and the next
/// scoped projection's cross-check (debug builds) panics on that screen.
fn session(workspaces: usize) -> (Arc<Mux>, std::path::PathBuf, Vec<PaneId>) {
    let root = std::env::temp_dir()
        .join(format!("cmux-single-reads-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("single-reads", &root);
    // The worker would checkpoint and seal on its own ticks.
    mux.stop_journal_maintenance();
    let mut panes = Vec::new();
    for index in 0..workspaces {
        if index + 2 < workspaces {
            mux.create_empty_workspace(Some(format!("idle {index}")), None, None).unwrap();
            continue;
        }
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        mux.split(pane, SplitDir::Right, Some((80, 24))).unwrap();
        mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
        panes.push(pane);
    }
    (mux, root, panes)
}

/// The session snapshot's workspaces, screens, panes and tabs.
fn topology(mux: &Mux) -> Value {
    let snapshot = public_session_snapshot(mux).unwrap();
    COLLECTIONS
        .iter()
        .map(|collection| (collection.to_string(), snapshot[*collection].clone()))
        .collect::<Map<_, _>>()
        .into()
}

fn row(topology: &Value, collection: &str, id: &str) -> Value {
    topology[collection]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == id)
        .cloned()
        .unwrap_or_else(|| panic!("the snapshot lists {collection} {id}"))
}

/// One read of one item.
struct SingleRead {
    operation: &'static str,
    params: Value,
    /// The snapshot row it answers (its collection and id); `None` for a
    /// pane with no neighbor.
    answers: Option<(&'static str, String)>,
}

impl SingleRead {
    fn get(operation: &'static str, selector: &str, collection: &'static str, id: &str) -> Self {
        Self { operation, params: json!({selector: id}), answers: Some((collection, id.into())) }
    }

    fn neighbor(pane: &str, direction: &str, neighbor: Option<&str>) -> Self {
        Self {
            operation: "pane.neighbor.get",
            params: json!({"pane": pane, "direction": direction}),
            answers: neighbor.map(|id| ("panes", id.to_string())),
        }
    }

    /// What the session snapshot holds for this read.
    fn expected(&self, topology: &Value) -> Value {
        let listed = self.answers.as_ref().map(|(collection, id)| row(topology, collection, id));
        match self.operation {
            "pane.neighbor.get" => json!({"pane": listed}),
            _ => listed.unwrap(),
        }
    }

    fn request(&self, mux: &Arc<Mux>) -> Value {
        let mut params = self.params.clone();
        params["machine"] = json!("current");
        params["session"] = json!("current");
        public_request(mux, self.operation, self.operation, params, None)
    }
}

/// The reads of the tab, pane, screen and workspace that hold `pane`, and of
/// its neighbor in each direction (the live layout names it; the split put
/// one beside it).
fn reads_of(mux: &Mux, topology: &Value, pane: PaneId) -> Vec<SingleRead> {
    let public = |pane: PaneId| {
        mux.with_state(|state| state.resource_indexes.pane_ids.get(&pane).unwrap().to_string())
    };
    let neighbors = [
        ("left", Direction::Left),
        ("right", Direction::Right),
        ("up", Direction::Up),
        ("down", Direction::Down),
    ]
    .map(|(name, direction)| (name, mux.pane_neighbor(pane, direction).unwrap().map(public)));
    assert!(neighbors.iter().any(|(_, neighbor)| neighbor.is_some()), "setup: a neighbor pane");
    let pane = public(pane);
    let pane = pane.as_str();
    let screen = row(topology, "panes", pane)["screen_id"].as_str().unwrap().to_string();
    let workspace = row(topology, "screens", &screen)["workspace_id"].as_str().unwrap().to_string();
    let rows = |collection: &str| topology[collection].as_array().unwrap().clone();
    let tab = rows("tabs")
        .into_iter()
        .find(|tab| tab["pane_id"] == pane)
        .and_then(|tab| tab["id"].as_str().map(str::to_string))
        .expect("the pane has a tab");
    let mut reads = vec![
        SingleRead::get("tab.get", "tab", "tabs", &tab),
        SingleRead::get("pane.get", "pane", "panes", pane),
        SingleRead::get("screen.get", "screen", "screens", &screen),
        SingleRead::get("workspace.get", "workspace", "workspaces", &workspace),
    ];
    for (direction, neighbor) in &neighbors {
        reads.push(SingleRead::neighbor(pane, direction, neighbor.as_deref()));
    }
    reads
}

/// Runs `read` and records: a session snapshot it built, a whole-topology
/// load, a failure, or an answer that is not the snapshot's row.
///
/// The shells of the session commit on their own (a directory, a progress
/// report), so the read runs between two snapshots and counts only when
/// both list the same topology.
fn check(mux: &Arc<Mux>, read: &SingleRead, failures: &mut Vec<String>) {
    let operation = read.operation;
    for _ in 0..20 {
        let before = topology(mux);
        let topology_reads = WorkspaceRegistry::full_topology_reads_for_test();
        let built = Rc::new(Cell::new(false));
        let flag = built.clone();
        set_snapshot_before_projection_hook(move || flag.set(true));
        let response = read.request(mux);
        // A read that built no snapshot left the hook armed: disarm it.
        set_snapshot_before_projection_hook(|| {});
        let topology_reads = WorkspaceRegistry::full_topology_reads_for_test() - topology_reads;
        if topology(mux) != before {
            continue;
        }
        if built.get() {
            failures.push(format!("{operation} built the whole session snapshot"));
        }
        if topology_reads != 0 {
            failures.push(format!("{operation} loaded the whole topology {topology_reads} times"));
        }
        let expected = read.expected(&before);
        if response["ok"] != true {
            failures.push(format!("{operation} failed: {response}"));
        } else if response["result"] != expected {
            failures.push(format!(
                "{operation} answered {}, the session snapshot holds {expected}",
                response["result"]
            ));
        }
        return;
    }
    failures.push(format!("{operation}: the session topology never held still"));
}

/// The person's model: a writer (a split, a new tab, a state commit) holds
/// the registry lock. A get of one item reads committed rows, so it answers
/// without the lock; a get that builds the session snapshot waits for it.
///
/// `pane.neighbor.get` is not here: it finds the neighbor in the live
/// layout under the registry and state locks (one screen, not the session).
fn check_gets_answer_while_the_registry_lock_is_held(
    mux: &Arc<Mux>,
    reads: Vec<SingleRead>,
    failures: &mut Vec<String>,
) {
    let gets =
        reads.into_iter().filter(|read| read.operation != "pane.neighbor.get").collect::<Vec<_>>();
    let operations = gets.iter().map(|read| read.operation).collect::<Vec<_>>();
    let (entered, entered_receiver) = sync_channel(1);
    let (release, release_receiver) = sync_channel(1);
    let holder = {
        let mux = mux.clone();
        std::thread::spawn(move || mux.hold_workspace_registry_for_test(entered, release_receiver))
    };
    entered_receiver.recv().unwrap();
    let (answered, answered_receiver) = std::sync::mpsc::channel();
    let reader = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            for read in gets {
                let id = read.answers.as_ref().map(|(_, id)| id.clone());
                answered.send((id, read.request(&mux))).unwrap();
            }
        })
    };
    let mut during = Vec::new();
    for _ in &operations {
        match answered_receiver.recv_timeout(HELD_LOCK_ANSWER) {
            Ok(answer) => during.push(answer),
            Err(_) => break,
        }
    }
    release.send(()).unwrap();
    holder.join().unwrap();
    reader.join().unwrap();
    if let Some(waited) = operations.get(during.len()) {
        failures.push(format!(
            "{waited} waited for the held registry lock ({} of {} gets answered)",
            during.len(),
            operations.len()
        ));
    }
    for (operation, (id, response)) in operations.iter().zip(&during) {
        // The values are compared in `check`; the shells commit until the
        // hold, so here only the item's identity.
        if response["ok"] != true || response["result"]["id"].as_str() != id.as_deref() {
            failures.push(format!("{operation} under the held registry lock: {response}"));
        }
    }
}

fn single_reads(workspaces: usize) {
    let (mux, root, panes) = session(workspaces);
    let listed = topology(&mux);
    assert_eq!(listed["workspaces"].as_array().map(Vec::len), Some(workspaces), "setup");
    let mut failures = Vec::new();
    for pane in &panes {
        for read in reads_of(&mux, &listed, *pane) {
            check(&mux, &read, &mut failures);
        }
    }
    check_gets_answer_while_the_registry_lock_is_held(
        &mux,
        reads_of(&mux, &listed, panes[0]),
        &mut failures,
    );
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(failures.is_empty(), "{workspaces} workspaces: {failures:#?}");
}

#[test]
fn a_get_of_one_item_builds_no_session_snapshot_on_60_workspaces() {
    single_reads(60);
}

#[test]
fn a_get_of_one_item_builds_no_session_snapshot_on_826_workspaces() {
    single_reads(826);
}
