//! The daemon advertises `workspace-checklist-v1`, the `workspace_checklist.*`
//! operations (state/workspace_checklist_tests.rs), so the app offers its
//! checklist actions only to a daemon that keeps the records.

use super::*;

#[test]
fn the_workspace_checklist_capability_is_advertised() {
    assert!(advertised_capabilities(false).contains(&"workspace-checklist-v1"));
}
