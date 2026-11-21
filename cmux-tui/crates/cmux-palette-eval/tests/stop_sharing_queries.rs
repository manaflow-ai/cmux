//! The old stop rows' titles still find the one stop row, Stop Sharing This Mac
//! (`macScreen.stopSharing`), ranked first, through its built-in aliases.

#[path = "support/catalog.rs"]
mod catalog;

use catalog::ranked_rows;

#[test]
fn old_stop_titles_rank_stop_sharing_this_mac_first() {
    for query in [
        "cmux Remote: End Screen Sharing Session",
        "end screen sharing session",
        "End Screen Sharing",
        "stop screen sharing",
        "stop screen share",
        "stop sharing this mac",
    ] {
        for with_alias_table in [true, false] {
            let order: Vec<String> = ranked_rows(query, with_alias_table)
                .into_iter()
                .take(5)
                .map(|row| row.id)
                .collect();
            assert_eq!(
                order.first().map(String::as_str),
                Some("action:macScreen.stopSharing"),
                "{query:?} (alias table {with_alias_table}): {order:?}"
            );
        }
    }
}

#[test]
fn the_other_stop_rows_keep_their_titles() {
    for (query, want) in [
        ("turn off sharing this mac", "action:macScreen.stopSharingThisMac"),
        ("revoke this device", "action:macScreen.revokeViewer"),
        ("stop viewing shared screen", "action:macScreen.stopViewing"),
    ] {
        let order: Vec<String> =
            ranked_rows(query, true).into_iter().take(3).map(|row| row.id).collect();
        assert_eq!(order.first().map(String::as_str), Some(want), "{query:?}: {order:?}");
    }
}
