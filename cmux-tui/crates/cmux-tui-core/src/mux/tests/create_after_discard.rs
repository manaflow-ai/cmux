//! A create after a staged workspace left memory but not the store.
//!
//! When the store refuses a staged create's rollback (a full disk), the workspace leaves memory
//! and its stored row stays for the recovery or the next workspace commit
//! (`discard_unpublished_workspace_from_memory`). A create appends at the in-memory count, which
//! is then shorter than the stored order. The append commit writes only its own row, so it would
//! shift the leftover row instead of dropping it, and the saved list would differ from the live
//! one. The create sees the leftover (one read of the live position index) and takes the full
//! commit, which restates the order from memory.

use std::path::PathBuf;

use super::*;

fn temp_root(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-create-after-discard-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ))
}

fn memory_keys(mux: &Mux) -> Vec<String> {
    mux.state.lock().unwrap().workspaces.iter().map(|workspace| workspace.key.clone()).collect()
}

fn stored_keys(mux: &Mux) -> Vec<String> {
    let snapshot = mux.workspace_registry.lock().unwrap().snapshot().unwrap();
    snapshot.workspaces.into_iter().map(|workspace| workspace.key).collect()
}

#[test]
fn a_create_after_a_discarded_staged_workspace_leaves_the_stored_order_as_memory() {
    let name = "create-after-discard";
    let root = temp_root(name);
    let mux = open_persistent_test_mux(name, &root);
    mux.stop_journal_maintenance();
    for _ in 0..3 {
        mux.create_empty_workspace(None, None, None).unwrap();
    }
    let discarded = mux.state.lock().unwrap().workspaces.last().unwrap().id;
    assert!(matches!(mux.discard_unpublished_workspace_from_memory(discarded), Ok(true)));
    assert_eq!(stored_keys(&mux).len(), memory_keys(&mux).len() + 1, "the store keeps the row");

    mux.create_empty_workspace(None, None, None).unwrap();

    assert_eq!(stored_keys(&mux), memory_keys(&mux));
    // And the append path is back once the lists agree.
    mux.create_empty_workspace(None, None, None).unwrap();
    assert_eq!(stored_keys(&mux), memory_keys(&mux));
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}
