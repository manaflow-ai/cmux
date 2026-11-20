//! The size bound of a stored frontend projection (P-AUSTIN B9 row 15).
//!
//! A frontend keeps a whole document in one projection (the app's window
//! state, subject `windows`), and every native projection also goes into the
//! launch snapshot, so the bound is a share of the snapshot's.

/// Launch-snapshot bytes kept for the workspace tree and the personal state,
/// which every snapshot carries before any projection. Estimate: 4,096 tabs
/// x ~1 KiB; not measured. Nothing bounds the tree itself; a snapshot whose
/// projections do not fit drops the largest ones first and reports them
/// (`launch_snapshot`).
pub(super) const LAUNCH_SNAPSHOT_TREE_RESERVE_BYTES: usize = 4 * 1024 * 1024;
/// The native projections the app keeps, each in the launch snapshot:
/// `windows`, `history.hidden`, `history.locations`, `icon-picker.prefs` and
/// `ssh-hosts`.
pub(super) const LAUNCH_SNAPSHOT_PROJECTION_SLOTS: usize = 5;
/// The bound before it was derived, and its floor.
const PROJECTION_FLOOR_BYTES: usize = 1024 * 1024;

/// Largest stored native projection, in bytes of canonical JSON: an even
/// share of what the launch snapshot leaves after the tree reserve, never
/// below the old 1 MiB. With today's numbers ((8 - 4) MiB / 5 = 819 KiB) the
/// floor applies. A realistic window state is about 30 KB. A larger
/// projection is refused with an error that names its size; nothing is cut.
pub(super) const MAX_PROJECTION_BYTES: usize = {
    let share = (crate::server::MAX_LAUNCH_SNAPSHOT_BYTES - LAUNCH_SNAPSHOT_TREE_RESERVE_BYTES)
        / LAUNCH_SNAPSHOT_PROJECTION_SLOTS;
    if share > PROJECTION_FLOOR_BYTES { share } else { PROJECTION_FLOOR_BYTES }
};

/// Largest resource-API projection, in bytes: the bound older daemons check
/// when they read these rows at start (`public_projections`), so a larger row
/// written here would stop an older daemon after a rollback or handoff. Its
/// writers (the resource API, 4 MiB messages) keep it.
pub(super) const MAX_RESOURCE_API_PROJECTION_BYTES: usize = PROJECTION_FLOOR_BYTES;

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

/// The ledger's fingerprint of a projection request: `sha256:` and the hex
/// digest of its canonical text, so a replay check does not keep a copy of
/// the body.
pub(super) fn fingerprint_digest(fingerprint: &str) -> String {
    use sha2::{Digest, Sha256};
    format!("sha256:{}", super::hex_sha256(Sha256::digest(fingerprint.as_bytes()).into()))
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
