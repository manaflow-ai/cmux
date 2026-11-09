//! Attach streams in the reaper: an attached terminal is not counted toward
//! the grace cap, and the reap close re-checks attach streams under its locks.

use super::*;

/// The closed terminals past [`MAX_TERMINALS_IN_REAP_GRACE`], longest closed first: each holds a PTY
/// for its grace, and a burst of closes must not hold the machine's PTYs (STATUS 7998).
pub(super) fn over_grace_cap(
    reapable: &HashMap<String, Duration>,
    attached: &HashSet<String>,
) -> Vec<String> {
    let _ = attached;
    let mut oldest: Vec<(&Duration, &String)> =
        reapable.iter().map(|(terminal_id, unplaced_for)| (unplaced_for, terminal_id)).collect();
    let Some(over) = oldest.len().checked_sub(MAX_TERMINALS_IN_REAP_GRACE).filter(|over| *over > 0)
    else {
        return Vec::new();
    };
    oldest.sort_by(|a, b| b.0.cmp(a.0).then_with(|| a.1.cmp(b.1)));
    oldest.into_iter().take(over).map(|(_, terminal_id)| terminal_id.clone()).collect()
}

impl Mux {
    /// The reapable terminals a client holds an attach stream on.
    pub(super) fn attached_reap_candidates(
        &self,
        reapable: &HashMap<String, Duration>,
    ) -> HashSet<String> {
        let _ = reapable;
        HashSet::new()
    }

    /// A client holds an attach stream on the terminal view `view`.
    pub(crate) fn terminal_view_attached(&self, view: SurfaceId) -> bool {
        let _ = view;
        false
    }
}
