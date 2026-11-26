//! Attach streams in the reaper: an attached terminal is not counted toward
//! the grace cap, and the reap close re-checks attach streams under its locks
//! (port of feat #39574).

use super::*;

/// The closed terminals past [`MAX_TERMINALS_IN_REAP_GRACE`], longest closed first: each holds a
/// PTY for its grace, and a burst of closes must not hold the machine's PTYs (feat STATUS 7998). An
/// attached terminal is neither counted nor picked: the reaper cannot end it, so counting it ended
/// a detached terminal inside its grace, and picking it tried it again on every pass.
pub(super) fn over_grace_cap(
    reapable: &HashMap<String, Duration>,
    attached: &HashSet<String>,
) -> Vec<String> {
    let mut oldest: Vec<(&Duration, &String)> = reapable
        .iter()
        .filter(|(terminal_id, _)| !attached.contains(*terminal_id))
        .map(|(terminal_id, unplaced_for)| (unplaced_for, terminal_id))
        .collect();
    let Some(over) = oldest.len().checked_sub(MAX_TERMINALS_IN_REAP_GRACE).filter(|over| *over > 0)
    else {
        return Vec::new();
    };
    oldest.sort_by(|a, b| b.0.cmp(a.0).then_with(|| a.1.cmp(b.1)));
    oldest.into_iter().take(over).map(|(_, terminal_id)| terminal_id.clone()).collect()
}

impl Mux {
    /// The reapable terminals a client holds an attach stream on. Read only
    /// past the cap: within it the reap close checks each terminal itself.
    pub(super) fn attached_reap_candidates(
        &self,
        reapable: &HashMap<String, Duration>,
    ) -> HashSet<String> {
        if reapable.len() <= MAX_TERMINALS_IN_REAP_GRACE {
            return HashSet::new();
        }
        // The client registry is read after the state lock is released.
        let views: Vec<(String, SurfaceId)> = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            state
                .terminal_catalog
                .values()
                .filter_map(|runtime| {
                    let identity = self.resource_terminal_host_identity(runtime)?;
                    reapable
                        .contains_key(&identity.terminal_id)
                        .then_some((identity.terminal_id, runtime.id))
                })
                .collect()
        };
        views
            .into_iter()
            .filter(|(_, view)| self.terminal_view_attached(*view))
            .map(|(terminal_id, _)| terminal_id)
            .collect()
    }

    /// A client holds an attach stream on the terminal view `view`. The
    /// client registry's lock is a leaf: it may be taken under the registry
    /// and state locks, as the reap close does.
    pub(crate) fn terminal_view_attached(&self, view: SurfaceId) -> bool {
        self.control_clients.attach_observation(&[view]).0
    }
}
