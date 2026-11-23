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
    // Built-in aliases: these whole queries rank Screen Sharing first, above any row whose title
    // starts with "Share Screen".
    let aliases = palette::ALIASES
        .iter()
        .find(|(id, _)| *id == "macScreen.open")
        .map(|(_, words)| *words)
        .expect("macScreen.open aliases");
    for word in ["screen share", "share screen", "remote desktop", "vnc"] {
        assert!(aliases.contains(&word), "macScreen.open lacks the alias {word:?}");
    }
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

/// One row ends this Mac's session: Stop Sharing This Mac, on whichever host holds it (#44179).
/// cmux Remote: End Screen Sharing Session was the same stop for cmux Remote's worker. Turn Off
/// Sharing This Mac stays: it turns the Share This Mac switch off, which is not the same thing.
#[test]
fn one_row_ends_this_macs_session() {
    assert!(find("remote.stopScreenSession").is_none(), "the worker's duplicate stop row");
    let stop = find("macScreen.stopSharing").expect("Stop Sharing This Mac");
    for word in ["end session", "session", "cmux remote"] {
        assert!(stop.keywords.contains(&word), "Stop Sharing This Mac lacks {word:?}");
    }
    assert!(find("macScreen.stopSharingThisMac").is_some(), "Turn Off Sharing This Mac stays");
}

/// Screen Sharing and Stop Sharing This Mac have default shortcuts, on keys no other action takes.
#[test]
fn screen_sharing_has_default_shortcuts() {
    use cmux_action_catalog::model::{CMD, KEYBOARD, OPT, SHIFT};
    for (id, modifiers) in
        [("macScreen.open", SHIFT | CMD), ("macScreen.stopSharing", OPT | SHIFT | CMD)]
    {
        let action = find(id).expect(id);
        let shortcut = action.default_shortcut.as_ref().expect(id);
        assert_eq!((shortcut.key, shortcut.modifiers), ("s", modifiers), "{id}");
        let others: Vec<_> = cmux_action_catalog::actions()
            .filter(|other| other.id != id)
            .filter(|other| {
                other
                    .default_shortcut
                    .as_ref()
                    .is_some_and(|s| s.key == "s" && s.modifiers == modifiers)
            })
            .map(|other| other.id)
            .collect();
        assert!(others.is_empty(), "{id}'s shortcut is also {others:?}'s");
    }
    let stop = find("macScreen.stopSharing").expect("macScreen.stopSharing");
    assert!(stop.surfaces & KEYBOARD != 0, "Stop Sharing This Mac is not on the keyboard surface");
}
