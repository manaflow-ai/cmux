//! The size bound of a stored frontend projection (P-AUSTIN B9 row 15).
//!
//! A frontend keeps a whole document in one projection: the app's window
//! state (`WindowStateStore`, subject `windows`) lists every window with its
//! workspaces, selected tab per pane and focused pane per workspace, so it
//! grows with the session. A fixed 1 MiB cap refused a large session's save,
//! and the next launch restored an older layout.

/// Largest stored projection, in bytes of canonical JSON. Every native
/// projection also goes into the launch snapshot, which the app reads before
/// it connects to draw the last layout at once; a snapshot over its bound
/// drops all projections and the first frame shows the connecting state. So
/// the bound comes from the snapshot's: half of it, which leaves the other
/// half for the workspace tree, the personal state and the sidebar document.
/// It is far below the transport's message bound, so one request carries
/// any projection the daemon stores. A larger projection is refused with an
/// error that names its size; nothing is cut.
pub(super) const MAX_PROJECTION_BYTES: usize = crate::server::MAX_LAUNCH_SNAPSHOT_BYTES / 2;

/// Logs when a projection's size passes half of [`MAX_PROJECTION_BYTES`]
/// (from below, so a document that stays large logs once, not on each
/// save). The log names the projection and both sizes, so the growth is seen
/// long before a save is refused.
pub(super) fn note_projection_size(
    frontend: &str,
    scope: &str,
    subject_key: &str,
    previous_bytes: Option<usize>,
    bytes: usize,
) {
    if crosses_half_of_the_bound(previous_bytes, bytes) {
        eprintln!(
            "cmux-tui: frontend projection {frontend}/{scope}/{subject_key} is {bytes} bytes, \
             over half of the {MAX_PROJECTION_BYTES}-byte limit"
        );
    }
}

fn crosses_half_of_the_bound(previous_bytes: Option<usize>, bytes: usize) -> bool {
    let half = MAX_PROJECTION_BYTES / 2;
    bytes > half && previous_bytes.is_none_or(|previous| previous <= half)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_half_bound_warning_fires_once_when_the_size_crosses_it() {
        let half = MAX_PROJECTION_BYTES / 2;
        assert!(crosses_half_of_the_bound(None, half + 1));
        assert!(crosses_half_of_the_bound(Some(half), half + 1));
        assert!(!crosses_half_of_the_bound(Some(half + 1), half + 2));
        assert!(!crosses_half_of_the_bound(Some(10), half));
    }
}
