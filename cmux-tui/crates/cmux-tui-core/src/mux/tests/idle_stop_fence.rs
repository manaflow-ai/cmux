//! The idle-stop fence (`WorkspaceRegistry::set_idle_stop_fence`, raised by
//! `shutdown-daemon` with `if_idle`) holds on every path that writes a
//! terminal row, not only the terminal commit: a respawn of a lost host and
//! a raw write to `terminal_hosts` (as the resource projection makes) are
//! refused while it is raised, and work again once it is lowered.

use super::*;
use crate::terminal_end::TerminalEnd;

const TERMINAL: &str = "00000000000040008000000000417001";
const LOST: &str = "10000000000040008000000000417001";

#[test]
fn the_idle_stop_fence_refuses_a_respawn_and_a_raw_write_that_makes_a_terminal_live() {
    let root = std::env::temp_dir().join(format!(
        "cmux-idle-stop-fence-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux = open_persistent_test_mux("idle-stop-fence", &root);
    mux.stop_journal_maintenance();
    let workspace_key = mux.create_empty_workspace(Some("fence".into()), None, None).unwrap().key;
    mux.seed_running_terminal_for_test(TERMINAL, LOST, &workspace_key).unwrap();
    let end = TerminalEnd::host_lost("terminal host ended without a durable exit sidecar");
    assert!(
        mux.persist_terminal_exit(TERMINAL, Some(LOST), &end).unwrap(),
        "setup: the exit commits"
    );
    {
        let mut registry = mux.workspace_registry.lock().unwrap();
        registry.set_idle_stop_fence(Some(1)).unwrap();
        let error = registry.begin_terminal_respawn(TERMINAL, Some(LOST), false).unwrap_err();
        assert!(format!("{error:#}").contains("stopping because it was idle"), "{error:#}");
        let error = registry
            .connection
            .get()
            .execute(
                "UPDATE terminal_hosts SET lifecycle = 'running' WHERE terminal_id = ?1",
                [TERMINAL],
            )
            .unwrap_err();
        assert!(error.to_string().contains("stopping because it was idle"), "{error}");

        registry.set_idle_stop_fence(None).unwrap();
        let revision = registry.begin_terminal_respawn(TERMINAL, Some(LOST), false).unwrap();
        assert!(revision.is_some(), "the respawn works again once the fence is lowered");
    }
    mux.shutdown();
    let _ = std::fs::remove_dir_all(root);
}
