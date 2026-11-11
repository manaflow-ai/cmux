//! Journal write budget: a write that changes one tab or one screen journals
//! that change, not the session.
//!
//! Lawrence's session (2026-11-10): 826 workspaces, 5713 live resources. Each
//! `tab.update` (a browser tab's back list, a zoom, an attention mark)
//! journaled an upsert of all 5713 resources: 2.5 MB of `payload_json` for a
//! change to one tab, 15 times in 6 minutes (37.6 MB of 79 MB of live journal
//! rows). Each such row is written to the WAL, checkpointed into the registry,
//! sealed into a compressed segment and then kept for ever: about 64 GB
//! written in 9 hours and a 10 GB `workspace-registry.sqlite3`.
//!
//! The resource rows were already pruned (`prune_unchanged_resource_changes`),
//! but the public deltas of the full projection were journaled whole by every
//! plan that did not ask for pruning (`ResourceMutationPlan::prunes_stated`):
//! the tab strip (`tab.update`, `tab.pin`, tab groups), screen rows
//! (`screen.update`), tab drag, pane move, column move, dock columns and row
//! heights.
//!
//! Counted, not timed, at 4 and at 40 workspaces: the changes one write
//! journals are few, and they do not grow with the session.

use serde_json::json;

use super::tests::{empty_workspace, mutate, revision, snapshot, tab_id, terminal_tabs};
use crate::mux::*;
use crate::surface::SurfaceOptions;

/// The most changes one of these writes may journal: the tab or screen it
/// changes and the state rows that ride with it.
const CHANGES_BUDGET: usize = 4;
/// The most journal payload one of these writes may cost.
const BYTES_BUDGET: usize = 8 * 1024;

/// The changes journaled after `revision` and their JSON bytes.
fn journaled_after(mux: &Mux, revision: u64) -> (usize, usize) {
    let (mut changes, mut bytes) = (0, 0);
    for batch in mux.resource_events_after(revision).unwrap().batches {
        changes += batch.changes.as_array().map_or(0, Vec::len);
        bytes += batch.changes.to_string().len();
    }
    (changes, bytes)
}

/// What each write journaled in a session of `workspaces` empty workspaces
/// beside the one that holds the two tabs written to.
fn write_costs(workspaces: usize) -> Vec<(&'static str, usize, usize)> {
    let mux = Mux::new_for_test(
        format!("state-journal-write-budget-{workspaces}"),
        SurfaceOptions::default(),
    );
    let tabs = terminal_tabs(&mux, 2);
    for index in 0..workspaces {
        empty_workspace(&mux, &format!("budget-{index}"));
    }
    let tab = tab_id(&mux, tabs[0]);
    let screen = snapshot(&mux)["screens"][0]["id"].as_str().unwrap().to_string();
    // A session's first full projection may restate it: it is what the
    // journal's public fold is seeded from. Every later write is budgeted.
    mutate(&mux, "tab.update", json!({"tab": tab, "zoom": 1.1}), "budget-warm");
    let writes = [
        ("tab.update", json!({"tab": tab, "zoom": 1.5}), "zoom"),
        ("tab.update", json!({"tab": tab, "attention": "Confirm access"}), "attention"),
        ("tab.update", json!({"tab": tab, "marked_unread": true}), "unread"),
        ("tab.pin", json!({"tab": tab}), "pin"),
        ("tab.unpin", json!({"tab": tab}), "unpin"),
        ("screen.update", json!({"screen": screen, "color": "red"}), "screen-color"),
    ];
    writes
        .into_iter()
        .map(|(operation, params, key)| {
            let before = revision(&mux);
            mutate(&mux, operation, params, &format!("budget-{key}"));
            let (changes, bytes) = journaled_after(&mux, before);
            (key, changes, bytes)
        })
        .collect()
}

#[test]
fn a_tab_or_screen_write_journals_its_change_not_the_session() {
    let small = write_costs(4);
    let large = write_costs(40);
    for ((key, small_changes, small_bytes), (_, large_changes, large_bytes)) in
        small.iter().zip(&large)
    {
        eprintln!(
            "journal write budget: {key}: {small_changes} changes ({small_bytes} B) at 4 \
             workspaces, {large_changes} changes ({large_bytes} B) at 40"
        );
    }
    for ((key, small_changes, _), (_, large_changes, large_bytes)) in small.iter().zip(&large) {
        assert!(*large_changes >= 1, "{key} journaled no change: a replaying client never sees it");
        assert!(
            *large_changes <= CHANGES_BUDGET,
            "{key} journaled {large_changes} changes at 40 workspaces (budget {CHANGES_BUDGET}): \
             it restates the session"
        );
        assert_eq!(
            large_changes, small_changes,
            "{key} journaled {small_changes} changes at 4 workspaces and {large_changes} at 40: \
             its journal cost grows with the session"
        );
        assert!(
            *large_bytes <= BYTES_BUDGET,
            "{key} journaled {large_bytes} bytes at 40 workspaces (budget {BYTES_BUDGET})"
        );
    }
}
