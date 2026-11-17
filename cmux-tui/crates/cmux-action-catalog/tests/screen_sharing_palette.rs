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
    // Built-in aliases: these whole queries rank Screen Sharing first, above the Chief row whose
    // title starts with "Share Screen".
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

/// `cmux tab new-mac-screen --device NAME [--scope view|full]`: an agent's or the CLI's open of the
/// person's own device starts viewing at once, View Only unless it asks for Full Control (Leo,
/// 2026-11-17: "why should it get held only be aperson's click? i dont like that").
#[test]
fn screen_sharing_takes_an_optional_view_or_full_scope() {
    let open = find("macScreen.open").expect("Screen Sharing");
    let names: Vec<_> = open.arguments.iter().map(|a| a.name).collect();
    assert_eq!(names, ["device", "scope"]);
    let scope = open.arguments.iter().find(|a| a.name == "scope").expect("scope");
    assert!(!scope.required, "a missing scope asks for View Only");
    let cmux_action_catalog::model::ArgKind::Enumeration(cases) = scope.kind else {
        panic!("scope is an enumeration, not {:?}", scope.kind);
    };
    let values: Vec<_> = cases.iter().map(|c| c.value).collect();
    assert_eq!(values, ["view", "full"]);
}
