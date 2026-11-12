//! Final bench row (e), 2026-11-12: the daemon's reply to `workspace.list` at 50 workspaces went
//! from 0.753 to 1.14 ms at 2e5a10e4. That commit made the state fields of ONE workspace a read of
//! the 7 bulk statements of `state/workspace_extras.rs` with one id, and `workspace.list` (and the
//! session snapshot) decorated each workspace with it: 7 statements per workspace. The person's
//! session has about 826 workspaces.
//!
//! The check is a count with no clock: `workspace.list` and `session.snapshot` compile the same
//! number of statements at any number of workspaces, on a registry in memory and on a file
//! registry.

use super::tab_state_fields::{close_file_session, file_session_of, selects_of};
use super::*;

/// The statements `operation` compiles, and how many workspaces the session lists.
fn statements_of(mux: &Arc<Mux>, operation: &str) -> (usize, usize) {
    let statements = selects_of(mux, || {
        resource(mux, operation, json!({}));
    });
    let listed = resource(mux, "workspace.list", json!({}));
    (statements, listed.as_array().map_or(0, Vec::len))
}

/// The statements of one read of the sidebar document (`state/sidebar_doc_store.rs`: its
/// revision, the table check, the sections and the items). A request reads the document when the
/// process's one cached copy is of another registry, and the tests that run at the same time take
/// that copy for their own registries; the read is the same at any number of workspaces.
const SIDEBAR_DOCUMENT_READ: usize = 4;

fn check_statements(
    operation: &str,
    (few, few_workspaces): (usize, usize),
    (many, many_workspaces): (usize, usize),
) {
    assert!(
        few_workspaces >= 4 && many_workspaces >= few_workspaces * 4,
        "workspaces listed: {few_workspaces}, then {many_workspaces}"
    );
    assert!(few > 0, "the count sees the statements of {operation}");
    assert!(
        many.abs_diff(few) <= SIDEBAR_DOCUMENT_READ,
        "{operation} compiled {few} statements for {few_workspaces} workspaces and {many} for \
         {many_workspaces} workspaces: it reads state fields with statements of each value; one \
         statement set reads them for the whole session"
    );
}

/// `workspace.list` reads the workspaces' state fields with one statement set, at any size.
#[test]
fn a_workspace_list_runs_one_statement_set_at_any_number_of_workspaces() {
    let few = statements_of(&session_of(4), "workspace.list");
    let many = statements_of(&session_of(32), "workspace.list");
    check_statements("workspace.list", few, many);
}

/// The same count on a file registry (the list reads a pooled read-only connection).
#[test]
fn a_workspace_list_runs_one_statement_set_on_a_file_registry() {
    let (few_mux, few_root) = file_session_of("workspace-statements-few", 4);
    let (many_mux, many_root) = file_session_of("workspace-statements-many", 32);
    let few = statements_of(&few_mux, "workspace.list");
    let many = statements_of(&many_mux, "workspace.list");
    close_file_session(few_mux, few_root);
    close_file_session(many_mux, many_root);
    check_statements("workspace.list", few, many);
}

/// The session snapshot decorates its workspaces, screens and tabs with one statement set, at
/// any size (a registry in memory builds the snapshot on each read).
#[test]
fn a_session_snapshot_runs_one_statement_set_at_any_number_of_workspaces() {
    let few = statements_of(&session_of(4), "session.snapshot");
    let many = statements_of(&session_of(32), "session.snapshot");
    check_statements("session.snapshot", few, many);
}
