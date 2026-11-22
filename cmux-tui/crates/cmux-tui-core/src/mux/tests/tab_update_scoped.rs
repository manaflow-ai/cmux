//! `tab.update` writes one tab's record: its cost does not follow the size
//! of the session (AGENT TRAFFIC 800).
//!
//! `tab.update` (an unread mark, an agent's attention request, a zoom, an
//! icon) committed through the tab strip commit: under the registry and
//! state locks it cloned the whole session state, projected every workspace,
//! loaded the whole stored topology and read the whole presentation again.
//! At 826 workspaces a launch snapshot waited 1.35 s behind one such commit.
//!
//! The guard runs on an on-disk registry of 60 and of 826 workspaces (the
//! session size rule) and counts, on the requesting thread: whole-session
//! state clones, full projections, workspaces projected, whole-topology
//! loads and whole presentation reads. Counts, not times. The reply, the
//! tab's row in the session snapshot and the published change stay the same.

use serde_json::{Value, json};

use super::*;
use crate::resource_api::public_session_snapshot;

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
        .join(format!("cmux-tab-update-scoped-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("tab-update-scoped", &root);
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

/// The public id of the first tab of `pane`.
fn first_tab(mux: &Mux, pane: PaneId) -> String {
    mux.with_state(|state| {
        let surface = state.panes[&pane].tabs[0];
        state.resource_indexes.tab_ids[&surface].to_string()
    })
}

/// The session snapshot's row of `tab`, and the revision the snapshot shows.
fn listed_tab(mux: &Mux, tab: &str) -> (Value, Value) {
    let snapshot = public_session_snapshot(mux).unwrap();
    let row = snapshot["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == tab)
        .cloned()
        .unwrap_or_else(|| panic!("the snapshot lists tab {tab}"));
    (row, snapshot["cursor"]["revision"].clone())
}

/// The work one request did on this thread.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Work {
    state_clones: u64,
    full_projections: u64,
    workspaces_projected: u64,
    topology_loads: u64,
    presentation_reads: u64,
}

impl Work {
    fn now() -> Self {
        Self {
            state_clones: Mux::strip_state_clones_for_test(),
            full_projections: Mux::full_projections_for_test(),
            workspaces_projected: Mux::workspaces_projected_for_test(),
            topology_loads: WorkspaceRegistry::full_topology_reads_for_test(),
            presentation_reads: WorkspaceRegistry::presentation_reads_for_test(),
        }
    }

    fn since(self, before: Self) -> Self {
        Self {
            state_clones: self.state_clones - before.state_clones,
            full_projections: self.full_projections - before.full_projections,
            workspaces_projected: self.workspaces_projected - before.workspaces_projected,
            topology_loads: self.topology_loads - before.topology_loads,
            presentation_reads: self.presentation_reads - before.presentation_reads,
        }
    }

    /// Each count that grows with the session, as a failure of `update`.
    fn failures(self, update: &str, failures: &mut Vec<String>) {
        let Self {
            state_clones,
            full_projections,
            workspaces_projected,
            topology_loads,
            presentation_reads,
        } = self;
        if state_clones != 0 {
            failures.push(format!(
                "tab.update {update} cloned the whole session state {state_clones} times"
            ));
        }
        if full_projections != 0 {
            failures.push(format!(
                "tab.update {update} projected the whole session {full_projections} times"
            ));
        }
        if workspaces_projected > 1 {
            failures.push(format!(
                "tab.update {update} projected {workspaces_projected} workspaces (at most 1)"
            ));
        }
        if topology_loads != 0 {
            failures.push(format!(
                "tab.update {update} loaded the whole stored topology {topology_loads} times"
            ));
        }
        if presentation_reads != 0 {
            failures.push(format!(
                "tab.update {update} read the whole presentation {presentation_reads} times"
            ));
        }
    }
}

/// One field of a tab's record and where the tab's public value shows it.
struct Update {
    name: &'static str,
    field: &'static str,
    value: Value,
    /// Whether `extra` of the tab's public value holds the update.
    shown: fn(&Value) -> bool,
}

fn updates() -> Vec<Update> {
    vec![
        Update {
            name: "marked_unread",
            field: "marked_unread",
            value: json!(true),
            shown: |extra: &Value| extra["marked_unread"] == true,
        },
        Update {
            name: "attention",
            field: "attention",
            value: json!("Approve the plan"),
            shown: |extra: &Value| extra["attention"]["reason"] == "Approve the plan",
        },
        Update {
            name: "zoom",
            field: "zoom",
            value: json!(1.5),
            shown: |extra: &Value| extra["zoom"] == 1.5,
        },
    ]
}

fn request(mux: &Arc<Mux>, tab: &str, update: &Update, key: &str) -> Value {
    let mut params = json!({"machine": "current", "session": "current", "tab": tab});
    params[update.field] = update.value.clone();
    public_request(mux, "tab.update", "tab.update", params, Some(key))
}

/// Sends `update` to `tab` and records: work that grows with the session, a
/// failure, and a reply, a snapshot row or a published change that does not
/// hold the update.
///
/// The shells of the session commit on their own (a directory, a title), so
/// the reply is compared with the snapshot only when no other commit came
/// between the two; the counts are of this thread and hold on every try.
fn check(mux: &Arc<Mux>, tab: &str, update: &Update, failures: &mut Vec<String>) {
    let name = update.name;
    for attempt in 0..20 {
        let key = format!("{name}-{tab}-{attempt}");
        let before = Work::now();
        let response = request(mux, tab, update, &key);
        Work::now().since(before).failures(name, failures);
        if response["ok"] != true {
            failures.push(format!("tab.update {name} failed: {response}"));
            return;
        }
        let result = &response["result"];
        let committed: u64 = result["revision"].as_str().unwrap().parse().unwrap();
        if result["replayed"] != false {
            failures.push(format!("tab.update {name} replayed a new key: {response}"));
        }
        if result["value"]["id"] != tab || !(update.shown)(&result["value"]["extra"]) {
            failures.push(format!("tab.update {name} answered {}", result["value"]));
        }
        // The change every `session.events` reader gets for this commit.
        let page = mux.resource_events_after(committed - 1).unwrap();
        let published = page
            .batches
            .iter()
            .find(|batch| batch.revision == committed)
            .and_then(|batch| batch.changes.as_array())
            .and_then(|changes| {
                changes.iter().find(|change| {
                    change["kind"] == "upsert" && change["resource"] == "tab" && change["id"] == tab
                })
            })
            .map(|change| change["value"].clone());
        if published.as_ref() != Some(&result["value"]) {
            failures.push(format!(
                "tab.update {name} published {published:?}, the reply holds {}",
                result["value"]
            ));
        }
        // A retry under the same key replays the first answer and commits nothing.
        let replay = request(mux, tab, update, &key);
        if replay["result"]["replayed"] != true
            || replay["result"]["value"] != result["value"]
            || replay["result"]["revision"] != result["revision"]
        {
            failures.push(format!("tab.update {name} retried under its key answered {replay}"));
        }
        let (listed, shown_revision) = listed_tab(mux, tab);
        if shown_revision != result["revision"] {
            // Another commit came between the reply and the snapshot.
            continue;
        }
        if listed != result["value"] {
            failures.push(format!(
                "tab.update {name} answered {}, the session snapshot holds {listed}",
                result["value"]
            ));
        }
        return;
    }
    failures.push(format!("tab.update {name}: the session never held still"));
}

fn tab_updates(workspaces: usize) -> Vec<String> {
    let (mux, root, panes) = session(workspaces);
    let listed = public_session_snapshot(&mux).unwrap();
    assert_eq!(listed["workspaces"].as_array().map(Vec::len), Some(workspaces), "setup");
    let mut failures = Vec::new();
    for pane in &panes {
        let tab = first_tab(&mux, *pane);
        for update in updates() {
            check(&mux, &tab, &update, &mut failures);
        }
    }
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    failures
}

#[test]
fn a_tab_update_does_no_session_sized_work_on_60_workspaces() {
    let failures = tab_updates(60);
    assert!(failures.is_empty(), "60 workspaces: {failures:#?}");
}

#[test]
fn a_tab_update_does_no_session_sized_work_on_826_workspaces() {
    let failures = tab_updates(826);
    assert!(failures.is_empty(), "826 workspaces: {failures:#?}");
}
