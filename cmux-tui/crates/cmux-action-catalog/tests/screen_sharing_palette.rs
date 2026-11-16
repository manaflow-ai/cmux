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

/// The viewer toolbar's controls, each a palette row on the Screen Sharing tab it acts on.
const VIEWER_CONTROLS: &[&str] = &[
    "macScreen.viewOnly",
    "macScreen.fullControl",
    "macScreen.fullScreen",
    "macScreen.sendSwitchApp",
    "macScreen.sendSpotlight",
    "macScreen.reconnect",
];

#[test]
fn the_viewers_controls_are_palette_rows_on_the_tab_they_act_on() {
    use cmux_action_catalog::model::{CONTEXT_MENU, Decision, KEYBOARD, MENU};
    for &id in VIEWER_CONTROLS.iter().chain(&["macScreen.stopAllViewing"]) {
        let action = find(id).expect(id);
        assert!(action.is_palette_visible(), "{id} is not in the palette");
        assert_eq!(action.category, "tab", "{id}");
        // No new UI: no menu or right-click row, and no default shortcut.
        assert_eq!(action.surfaces & (MENU | CONTEXT_MENU | KEYBOARD), 0, "{id}");
        assert!(action.surface_plan.context_menus.is_empty(), "{id}");
        assert!(action.default_shortcut.is_none() && action.default_chord.is_none(), "{id}");
        assert!(matches!(action.surface_plan.cli, Some(Decision::Exempt(_))), "{id}");
        for word in ["screen share", "vnc", "remote desktop"] {
            assert!(action.keywords.contains(&word), "{id} lacks {word:?}");
        }
        let expected: &[&str] = if id == "macScreen.stopAllViewing" { &[] } else { &["tab"] };
        assert_eq!(action.targets, expected, "{id}");
    }
    for (id, word) in [
        ("macScreen.viewOnly", "view only"),
        ("macScreen.fullControl", "full control"),
        ("macScreen.fullScreen", "full screen"),
        ("macScreen.sendSwitchApp", "cmd tab"),
        ("macScreen.sendSpotlight", "spotlight"),
        ("macScreen.reconnect", "reconnect"),
        ("macScreen.stopAllViewing", "all"),
    ] {
        assert!(find(id).expect(id).keywords.contains(&word), "{id} lacks {word:?}");
    }
}

#[test]
fn the_viewers_controls_have_titles_in_every_language() {
    use cmux_action_catalog::strings::{LOCALES, lookup};
    for &id in VIEWER_CONTROLS.iter().chain(&["macScreen.stopAllViewing"]) {
        let title = find(id).expect(id).title;
        assert_eq!(title.key, format!("action.{id}"), "{id}");
        for (index, locale) in LOCALES.iter().enumerate() {
            let value = lookup(title.table, title.key, index);
            assert!(value.is_some_and(|v| !v.trim().is_empty()), "{id} has no {locale} title");
        }
    }
}

/// Stop All Viewing is new beside the three stop actions, which stay as they are (gap 3).
#[test]
fn stop_all_viewing_sits_beside_the_three_stop_actions() {
    for id in ["macScreen.stopViewing", "macScreen.stopSharing", "macScreen.revokeViewer"] {
        assert!(find(id).is_some(), "{id} is gone");
    }
    assert_ne!(
        find("macScreen.stopAllViewing").expect("stop all").title.en,
        find("macScreen.stopViewing").expect("stop").title.en
    );
}
