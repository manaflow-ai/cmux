//! Screen Sharing is found in the palette by the words people type, ranks with the daily
//! commands, and this Mac's sharing session sits with Share This Mac (Remote Machines).
use cmux_action_catalog::{find, palette};

#[test]
fn screen_sharing_is_found_by_the_words_people_type() {
    let open = find("macScreen.open").expect("Screen Sharing");
    for word in ["screen share", "share screen", "remote desktop", "vnc", "view"] {
        assert!(open.keywords.contains(&word), "macScreen.open lacks {word:?}");
    }
    for id in [
        "macScreen.stopViewing",
        "macScreen.stopSharing",
        "macScreen.shareThisMac",
        "macScreen.stopSharingThisMac",
    ] {
        let action = find(id).expect(id);
        assert!(action.keywords.contains(&"screen share"), "{id} lacks \"screen share\"");
        assert!(action.keywords.contains(&"vnc"), "{id} lacks \"vnc\"");
    }
    assert!(palette::DAILY.contains(&"macScreen.open"));
}

#[test]
fn this_macs_sharing_session_sits_with_share_this_mac() {
    for id in [
        "macScreen.stopSharing",
        "macScreen.revokeViewer",
        "macScreen.shareThisMac",
        "macScreen.stopSharingThisMac",
    ] {
        assert_eq!(find(id).expect(id).category, "remote", "{id}");
    }
}
