//! `shutdown-daemon end_terminals`: end every live terminal in one durable
//! commit (nx-scale step 1b).

#[cfg(test)]
mod tests {
    use super::super::*;

    fn host_id(mux: &Arc<Mux>, surface: &Arc<Surface>) -> String {
        mux.resource_terminal_host_identity(surface).expect("test terminal is hosted").terminal_id
    }

    fn lifecycle(mux: &Arc<Mux>, terminal_id: &str) -> TerminalLifecycle {
        mux.resolve_terminal(terminal_id).unwrap().unwrap().terminal.lifecycle
    }

    /// Ending N terminals one close at a time rebuilt and committed the whole
    /// session projection N times: O(N^2) teardown (1,000 terminals took
    /// 147 s). The teardown is one projection and one commit.
    #[test]
    fn end_all_terminals_commits_one_resource_revision() {
        const TERMINALS: usize = 4;
        let mux = Mux::new_for_test("terminal-end-batch", SurfaceOptions::default());
        let mut terminal_ids = (0..TERMINALS)
            .map(|index| {
                let surface =
                    mux.new_workspace(Some(format!("batch-{index}")), Some((80, 24))).unwrap();
                host_id(&mux, &surface)
            })
            .collect::<Vec<_>>();
        terminal_ids.sort();
        let before = mux.with_state(|state| state.resource_revision);

        let mut ended = mux.end_all_terminals().unwrap();

        ended.sort();
        assert_eq!(ended, terminal_ids);
        let revisions = mux.with_state(|state| state.resource_revision) - before;
        assert_eq!(
            revisions, 1,
            "ending {TERMINALS} terminals must commit one resource revision, got {revisions}"
        );
        for terminal_id in &terminal_ids {
            assert_eq!(lifecycle(&mux, terminal_id), TerminalLifecycle::Tombstoned);
        }
        mux.with_state(|state| {
            assert_eq!(state.workspaces.len(), TERMINALS, "emptied workspaces stay");
            assert!(state.terminal_catalog.is_empty());
            assert!(state.surfaces.is_empty());
        });
        assert_eq!(mux.terminal_host_closes.pending(), 0);
    }
}
