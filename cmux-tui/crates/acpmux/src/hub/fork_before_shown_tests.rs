use super::*;

/// A fork whose referenced history was written into its log keeps that history under the
/// chat's seqs, and Edit and resend still proves its log whole after a restart, when its meta
/// names no chat any more (review of #37020: the proof refused it).
#[test]
fn history_written_into_a_fork_keeps_its_skips_allowed() {
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "fork", "name": "fork", "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    assert_eq!(shown_through(&meta), 0);
    meta.history_kept_through = Some(20);
    assert_eq!(shown_through(&meta), 20);
    // The chat's records at 2, 4, 5, ... through 20, then the fork's own at 21.
    assert!(skips_shown(4, 3, shown_through(&meta)));
    assert!(skips_shown(21, 19, shown_through(&meta)));
    assert!(!skips_shown(23, 21, shown_through(&meta)), "a skip past them is a gap");
}
